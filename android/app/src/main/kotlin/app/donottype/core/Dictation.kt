package app.donottype.core

import android.content.Context
import app.donottype.PromptAssets
import app.donottype.Settings
import app.donottype.audio.OpusEncoder
import app.donottype.audio.WavRecorder
import java.io.File
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import java.io.IOException
import java.net.SocketTimeoutException
import java.net.UnknownHostException

/**
 * One place where a recording becomes a transcript, whether it is the first attempt or the fourth.
 *
 * Shared by the keyboard and the settings screen so a retry is not a lesser path: it uses the same
 * prompt, the same model and the stored audio, and produces what the original request would have
 * produced had the network held.
 */
class DictationService(private val context: Context) {

    /** Everything a dictation does, under one category so a log filter finds all of it. */
    private val log = Log("dictate")
    private val speechActivity by lazy {
        SpeechActivity(context.assets.open("models/silero_vad.onnx"))
    }

    val history: HistoryStore by lazy {
        HistoryStore(File(context.filesDir, "history")).also {
            it.configure(Settings.retention, Settings.keepAudio)
        }
    }

    /**
     * Errors worth retrying, as opposed to ones that will fail identically forever.
     *
     * Lives in [FailureAdvice] beside the sentence shown for the same failure, so the two cannot
     * disagree — telling somebody "saved, retry from History" about a failure the retry loop has
     * already written off is worse than saying nothing. This needs a Context and so cannot be
     * reached from a unit test; that one can.
     */
    fun isTransient(error: Throwable): Boolean = FailureAdvice.isTransient(error)

    /** Shares the process-lifetime Silero session with live and file transcription. */
    internal fun measureSpeech(wav: ByteArray): SpeechActivity.Reading =
        speechActivity.measureWav(wav)

    /** Transcribes, storing the outcome either way so a failure stays retryable. */
    suspend fun transcribe(
        wav: ByteArray,
        screenContext: ScreenContext?,
        appName: String?,
        style: RewriteStyle = RewriteStyle.VERBATIM,
        liveSession: LiveTranscriptionSession? = null,
    ): Result<DictationRecord> {
        val key = Settings.apiKey
        if (key.isNullOrBlank()) {
            return Result.failure(ProviderException("No API key. Open DoNotType to add one."))
        }

        history.configure(Settings.retention, Settings.keepAudio)
        // From here, not from the request: reading the screen and any retry are time the user
        // spends waiting, and a figure that skipped them would flatter the app.
        val releasedAt = System.currentTimeMillis()
        val record = DictationRecord(
            model = Settings.model,
            fidelity = Settings.fidelity,
            appName = appName,
            durationSeconds = WavRecorder.durationSeconds(wav),
            context = screenContext,
        )

        // Nothing without speech in it is ever sent. A model handed room tone does not reliably
        // return silence — it returns a plausible sentence, and a keyboard that commits words
        // nobody said has done the one thing this project exists to prevent. prompt/system.md rule 7 asks
        // for an empty transcript, but it only reaches model providers: a speech recogniser has no
        // system instruction, so for Deepgram, xAI and Voxtral the rule is never sent at all. Not
        // transmitting the audio is the only defence that holds for every backend.
        val activity = try {
            measureSpeech(wav)
        } catch (error: Exception) {
            liveSession?.cancel()
            log.error(mapOf("detail" to FailureAdvice.detail(error))) {
                "speech detector failed"
            }
            return Result.failure(
                ProviderException("Speech detector failed: ${error.localizedMessage}"),
            )
        }
        // Live chunks have each passed this same Silero gate already. Do not throw away a result
        // that may already be in flight because a second, whole-recording pass disagreed.
        if (liveSession == null && !activity.hasSpeech) {
            log.info(
                mapOf("audio" to activity.summary),
            ) { "nothing was said, so nothing was sent" }
            return Result.failure(NoSpeechException())
        }

        // One id for the whole dictation, on every line and on the history row. Without it a log
        // with three dictations in it is three interleaved stories, and the question being asked
        // is always about one of them.
        val id = record.id.take(8)
        log.info(
            mapOf(
                "dictation" to id,
                "provider" to Settings.provider.id,
                "model" to Settings.model,
                "fidelity" to Settings.fidelity.id,
                "seconds" to "%.2f".format(record.durationSeconds ?: 0.0),
                "bytes" to wav.size.toString(),
                "grounded" to if (screenContext == null) "no" else "yes",
                "audio" to activity.summary,
                "app" to (appName ?: "?"),
            ),
        ) { "transcribing" }

        return try {
            val requestStart = System.currentTimeMillis()
            // Live segmentation is deliberately verbatim: a style belongs to the whole
            // utterance, not to each pause-finalised chunk. The ordinary path can ask the model
            // for both fields in the same request.
            val styleClause = style.takeIf { it.isRewrite && liveSession == null }
                ?.let { PromptAssets.styleClause(context, it) }
            val outcome = liveSession?.finish(screenContext)
                ?: transcribeFinished(wav, screenContext, id, styleClause)

            record.requestMillis = System.currentTimeMillis() - requestStart
            record.audioTokens = outcome.result.usage.audioTokens
            // Recorded as the backend that answered, not the one that was asked.
            record.model = outcome.attribution.model

            // The second gate, after the fallback has chosen a winner so it covers whichever
            // backend answered. SpeechActivity above refuses to send silence; this refuses to
            // commit words the audio cannot contain, for the recordings that get past it.
            val (guarded, verdict) = HallucinationGuard.inspect(
                outcome.result.transcript,
                record.durationSeconds,
            )
            if (verdict != HallucinationGuard.Verdict.Kept) {
                // Warning, not info: text the user never said was about to be committed to whatever
                // they had focused, and the whole measurement goes in the line so the threshold can
                // be argued with from the log alone.
                log.warn(
                    mapOf(
                        "dictation" to id,
                        "model" to outcome.attribution.model,
                        "reason" to verdict.summary,
                    ),
                ) { "transcript discarded — the audio cannot contain it" }
                log.content("discarded transcript", LogLevel.TRACE) {
                    outcome.result.transcript.transcript
                }
            }

            val text = guarded.transcript
            log.info(
                mapOf(
                    "dictation" to id,
                    "chars" to text.length.toString(),
                    "language" to outcome.result.transcript.language,
                    "audioTokens" to (outcome.result.usage.audioTokens?.toString() ?: "unreported"),
                    "model" to outcome.attribution.model,
                    "hedged" to if (outcome.attribution.model == Settings.model) "no" else "yes",
                    "ms" to (record.requestMillis ?: 0).toString(),
                ),
            ) { "transcript received" }
            log.content("transcript", LogLevel.TRACE) { text }

            if (text.isBlank()) {
                // Do not store a completed empty row, and do not make the IME infer this from a
                // successful result. A typed exception lets it keep the outcome visible without
                // presenting silence as a provider failure worth retrying.
                log.info(mapOf("dictation" to id)) { "nothing was said" }
                return Result.failure(NoSpeechException())
            }

            record.status = DictationRecord.Status.COMPLETED
            record.text = text

            // A model response may carry the rewrite beside the verbatim transcript. Recognition
            // backends and older responses fall through to the existing text-only stage.
            var delivered = text
            val styledInResponse = outcome.result.transcript.styled?.trim()
            if (style.isRewrite && !styledInResponse.isNullOrBlank()) {
                val mode = TranscriptMode.Rewrite(style)
                record.styledText = styledInResponse
                record.mode = mode.id
                delivered = styledInResponse
                log.info(
                    mapOf(
                        "dictation" to id,
                        "style" to style.id,
                        "chars" to styledInResponse.length.toString(),
                        "from" to text.length.toString(),
                    ),
                ) { "styled in one request" }
            } else if (style.isRewrite && text.isNotBlank()) {
                val rewriteStart = System.currentTimeMillis()
                val mode = TranscriptMode.Rewrite(style)
                val instruction = PromptAssets.secondStageInstruction(context, mode)
                val kind = secondStageBackendFor(key)
                log.info(
                    mapOf("dictation" to id, "style" to style.id, "chars" to text.length.toString()),
                ) { "second stage" }

                if (instruction == null || kind == null) {
                    // A recognition backend has no text endpoint at all, so this is not a request
                    // that went wrong — it is one that was never possible. Said out loud rather
                    // than left to be inferred from getting your own words back.
                    record.rewriteFailed = true
                    log.warn(
                        mapOf("dictation" to id, "style" to style.id),
                    ) { "no backend can rewrite text, delivering the verbatim transcript" }
                } else {
                    try {
                        val rewriter = ProviderFactory.create(
                            kind, Settings.keyFor(kind).orEmpty(), Settings.modelFor(kind),
                        )
                        val styled = rewriter.transcribe(
                            instruction, listOf(InputPart.Text(text)), Settings.fidelity,
                        ).transcript.transcript.trim()
                        if (styled.isNotEmpty()) {
                            record.styledText = styled
                            record.mode = mode.id
                            delivered = styled
                        }
                        log.info(
                            mapOf(
                                "dictation" to id,
                                "chars" to styled.length.toString(),
                                "from" to text.length.toString(),
                                "ms" to (System.currentTimeMillis() - rewriteStart).toString(),
                            ),
                        ) { "second stage finished" }
                    } catch (error: Exception) {
                        // The words survive either way, so this is a warning rather than a failure
                        // — but it is said out loud, because a rewrite that fails every time
                        // should not be indistinguishable from one never asked for.
                        record.rewriteFailed = true
                        log.warn(
                            mapOf(
                                "dictation" to id,
                                "style" to style.id,
                                "detail" to FailureAdvice.detail(error),
                            ),
                        ) { "second stage failed, delivering the verbatim transcript" }
                    }
                }
            }

            record.latencyMillis = System.currentTimeMillis() - releasedAt
            history.insert(record, if (Settings.keepAudio) wav else null)
            log.info(
                mapOf(
                    "dictation" to id,
                    "chars" to text.length.toString(),
                    "totalMs" to (record.latencyMillis ?: 0).toString(),
                ),
            ) { "dictation complete" }
            Result.success(record)
        } catch (error: Exception) {
            // Audio is kept so this can be retried from the settings screen, or when the keyboard
            // next opens with a working connection.
            // The advice rather than the exception. A history row that reads
            // `HTTP 429: {"error":{"code":"rate_limit_exceeded"…` is a log line somebody has to
            // decode weeks later; the advice says what happened and whether it is worth retrying.
            val advice = FailureAdvice.describe(error)
            val detail = FailureAdvice.detail(error)

            // The whole thing, in the log, on one record. Whatever the keyboard shows — and it has
            // one line — this is what somebody diagnosing it has to be able to read.
            log.error(
                mapOf(
                    "advice" to advice.message,
                    "queued" to if (advice.isQueued) "yes" else "no",
                    "retryable" to if (advice.isRetryable) "yes" else "no",
                    "provider" to Settings.provider.id,
                    "model" to Settings.model,
                    "dictation" to id,
                    "detail" to detail,
                ),
            ) { "transcription failed" }

            record.status = DictationRecord.Status.FAILED
            record.errorMessage = advice.message
            record.errorDetail = detail
            history.insert(record, wav)
            Result.failure(error)
        }
    }

    /** Constructs the live pipeline before AudioRecord starts, so its first sample is included. */
    fun createLiveSession(screenContext: ScreenContext?): LiveTranscriptionSession? {
        val key = Settings.apiKey?.takeIf { it.isNotBlank() } ?: return null
        return runCatching {
            val primary = ProviderFactory.create(Settings.provider, key, Settings.model)
            LiveTranscriptionSession(
                primary.name, primary.model, screenContext, speechActivity,
            ) { wav, context ->
                transcribePart(wav, context, "live")
            }
        }.getOrNull()
    }

    private suspend fun transcribeFinished(
        wav: ByteArray,
        screenContext: ScreenContext?,
        id: String,
        styleClause: String? = null,
    ): FallbackTranscriber.Outcome = coroutineScope {
        val chunks = AudioChunker.split(wav)
        // Split recordings are stitched verbatim and styled once by the caller.
        val chunkStyle = styleClause.takeIf { chunks.size == 1 }
        val gate = Semaphore(3)
        val outcomes = chunks.map { chunk ->
            async {
                gate.withPermit { transcribePart(chunk.data, screenContext, id, chunkStyle) }
            }
        }.awaitAll()
        combine(outcomes)
    }

    private suspend fun transcribePart(
        wav: ByteArray,
        screenContext: ScreenContext?,
        id: String,
        styleClause: String? = null,
    ): FallbackTranscriber.Outcome {
        val key = Settings.apiKey?.takeIf { it.isNotBlank() }
            ?: throw ProviderException("No API key. Open DoNotType to add one.")
        val instruction = PromptAssets.systemInstruction(context, Settings.fidelity)
        val client = ProviderFactory.create(Settings.provider, key, Settings.model)

        fun requestInputs(backend: TranscriptionProvider): Pair<List<InputPart>, List<String>> {
            val dictionary = Settings.personalDictionaryTerms()
            return when (val grounding = backend.grounding()) {
                is GroundingSupport.Multimodal -> buildList {
                    PersonalDictionary.referenceBlock(dictionary)?.let { add(InputPart.Text(it)) }
                    if (screenContext != null && !screenContext.isEmpty) {
                        addAll(ContextEncoder().encode(screenContext))
                    }
                } to emptyList()
                is GroundingSupport.Keyterms -> {
                    val derived = if (Settings.keytermBiasing
                        && screenContext != null && !screenContext.isEmpty
                    ) {
                        Keyterms.derive(
                            screenContext,
                            grounding.maxTerms,
                            grounding.maxCharsPerTerm,
                        )
                    } else emptyList()
                    emptyList<InputPart>() to PersonalDictionary.mergeKeyterms(
                        dictionary, derived, grounding.maxTerms, grounding.maxCharsPerTerm,
                    )
                }
                is GroundingSupport.None -> emptyList<InputPart>() to emptyList()
            }
        }

        fun audioPart(): InputPart {
            val ogg = OpusEncoder.encode(wav)
            return if (ogg != null) InputPart.Audio(ogg, "audio/ogg")
            else InputPart.Audio(wav, "audio/wav")
        }

        suspend fun run(backend: TranscriptionProvider): TranscriptionResult {
            val (parts, hints) = requestInputs(backend)
            val payload = parts + audioPart()
            val foldsInStyle = styleClause != null
                && backend.grounding() is GroundingSupport.Multimodal
            val requestInstruction = if (foldsInStyle) {
                instruction + styledInstructionSuffix(styleClause!!)
            } else instruction
            val deadline = StallHedge.deadlineMillis(WavRecorder.durationSeconds(wav))
            return StallHedge.race(
                deadlineMillis = deadline,
                onHedge = {
                    log.info(
                        mapOf("dictation" to id, "provider" to backend.name),
                    ) { "request stalled; sending a second one" }
                },
            ) {
                backend.transcribe(
                    requestInstruction, payload, Settings.fidelity, hints,
                    wantsStyledOutput = foldsInStyle,
                )
            }
        }

        val fallbackClient = Settings.fallbackProvider
            ?.let { kind -> Settings.keyFor(kind)?.takeIf(String::isNotEmpty)?.let { kind to it } }
            ?.let { (kind, fallbackKey) ->
                ProviderFactory.create(kind, fallbackKey, Settings.modelFor(kind))
            }
        return FallbackTranscriber(
            primary = { run(client) },
            secondary = fallbackClient?.let { backend ->
                FallbackTranscriber.Transcriber { run(backend) }
            },
            hedgeAfterMillis = Settings.fallbackAfterSeconds * 1_000L,
        ).transcribe(
            client.name, client.model,
            fallbackClient?.name.orEmpty(), fallbackClient?.model.orEmpty(),
        )
    }

    private fun styledInstructionSuffix(styleClause: String): String = """


        Return `transcript` as the exact verbatim transcription, unchanged, and `styled` as that
        same transcript rewritten in the style below. The rewrite may not alter any number, name,
        identifier or fact that appears in `transcript`.

        $styleClause
    """

    private fun combine(
        outcomes: List<FallbackTranscriber.Outcome>,
    ): FallbackTranscriber.Outcome {
        val results = outcomes.map { it.result }
        return FallbackTranscriber.Outcome(
            TranscriptionResult(
                Transcript(
                    AudioChunker.stitch(results.map { it.transcript.transcript }),
                    results.firstOrNull()?.transcript?.language.orEmpty(),
                ),
                results.fold(TokenUsage()) { total, piece -> TokenUsage.add(total, piece.usage) },
                results.joinToString("\n") { it.rawOutput },
            ),
            FallbackTranscriber.Attribution(
                outcomes.map { it.attribution.provider }.distinct().joinToString(" + "),
                outcomes.map { it.attribution.model }.distinct().joinToString(" + "),
                outcomes.any { it.attribution.wasFallback },
            ),
        )
    }

    /**
     * Which backend can rewrite text, given the key already resolved for the primary.
     *
     * The same rule as the file transcriber: a recognition backend cannot take text at all, so a
     * rewrite has to go to a model provider that has a key — the recording still goes to the fast
     * recogniser.
     */
    private fun secondStageBackendFor(primaryKey: String): ProviderKind? {
        if (!Settings.provider.isSpeechRecognition) return Settings.provider
        return ProviderKind.entries.firstOrNull { kind ->
            !kind.isSpeechRecognition && !Settings.keyFor(kind).isNullOrBlank()
        }
    }

    /** Reissues a stored dictation. */
    suspend fun retry(record: DictationRecord): Result<DictationRecord> {
        val key = Settings.apiKey
        if (key.isNullOrBlank()) {
            return Result.failure(ProviderException("No API key."))
        }
        val wav = history.audioFor(record)
            ?: return Result.failure(ProviderException("The recording is no longer on disk."))

        record.retryCount += 1
        return try {
            // Retried through whichever provider is selected *now*, not the one that failed. A
            // dictation that failed because the backend was wrong for it is exactly the one
            // someone switches provider and retries.
            // The context the original request carried, not none. A retry that drops it is a
            // different request from the one that failed — ungrounded, on a row that still names
            // the same provider and model — so a transcript that comes back worse looks like the
            // backend having a bad day rather than like the retry having asked a different
            // question. Null for rows written before contexts were stored, and for dictations that
            // were never grounded, which is the same thing as far as the request is concerned.
            val client = ProviderFactory.create(Settings.provider, key, Settings.model)
            val dictionary = Settings.personalDictionaryTerms()
            val (contextParts, keyterms) = when (val grounding = client.grounding()) {
                is GroundingSupport.Multimodal -> buildList {
                    PersonalDictionary.referenceBlock(dictionary)?.let { add(InputPart.Text(it)) }
                    record.context?.takeIf { !it.isEmpty }?.let { addAll(ContextEncoder().encode(it)) }
                } to emptyList()
                is GroundingSupport.Keyterms -> {
                    val derived = if (Settings.keytermBiasing) {
                        record.context?.takeIf { !it.isEmpty }?.let {
                            Keyterms.derive(it, grounding.maxTerms, grounding.maxCharsPerTerm)
                        }.orEmpty()
                    } else emptyList()
                    emptyList<InputPart>() to PersonalDictionary.mergeKeyterms(
                        dictionary, derived, grounding.maxTerms, grounding.maxCharsPerTerm,
                    )
                }
                is GroundingSupport.None -> emptyList<InputPart>() to emptyList()
            }

            val result = client.transcribe(
                PromptAssets.systemInstruction(context, record.fidelity),
                contextParts + InputPart.Audio(wav, "audio/wav"),
                record.fidelity,
                keyterms,
            )
            record.status = DictationRecord.Status.COMPLETED
            record.text = result.transcript.transcript.trim()
            record.errorMessage = null
            history.update(record)
            Result.success(record)
        } catch (error: Exception) {
            record.status = DictationRecord.Status.FAILED
            record.errorMessage = error.message ?: error::class.simpleName
            history.update(record)
            Result.failure(error)
        }
    }

    /**
     * Drains everything that failed while offline.
     *
     * Sequential on purpose: a user coming back online may have a dozen pending dictations, and
     * firing them at once is the fastest way to turn a recoverable backlog into a rate-limited one.
     */
    suspend fun retryAll(): Pair<Int, Int> {
        var succeeded = 0
        var failed = 0
        for (record in history.retryable()) {
            if (retry(record).isSuccess) succeeded++ else failed++
        }
        return succeeded to failed
    }
}
