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

    /** Transcribes, storing the outcome either way so a failure stays retryable. */
    suspend fun transcribe(
        wav: ByteArray,
        screenContext: ScreenContext?,
        appName: String?,
        style: RewriteStyle = RewriteStyle.VERBATIM,
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
                "app" to (appName ?: "?"),
            ),
        ) { "transcribing" }

        return try {
            val instruction = PromptAssets.systemInstruction(context, Settings.fidelity)
            val client = ProviderFactory.create(Settings.provider, key, Settings.model)

            // Each backend is sent only what it can use. Encoding ten thousand characters of
            // screen text for an endpoint whose request body is raw audio would not merely be
            // wasted — it would put a "grounded" request in the history for a transcript that was
            // produced without grounding.
            var keyterms = emptyList<String>()
            val contextParts = buildList {
                val grounding = client.grounding()
                if (screenContext == null || screenContext.isEmpty) return@buildList
                when (grounding) {
                    is GroundingSupport.Multimodal -> addAll(ContextEncoder().encode(screenContext))
                    is GroundingSupport.Keyterms ->
                        if (Settings.keytermBiasing) {
                            keyterms = Keyterms.derive(
                                screenContext,
                                grounding.maxTerms,
                                grounding.maxCharsPerTerm,
                            )
                        }
                    is GroundingSupport.None -> Unit
                }
            }

            // Long recordings are split on silence and transcribed concurrently; anything under
            // the threshold comes back as one chunk and takes the ordinary path unchanged. Every
            // chunk carries identical context, which is what keeps a name spelled the same on both
            // sides of a seam.
            val chunks = AudioChunker.split(wav)
            val requestStart = System.currentTimeMillis()

            // Compressed for upload only. History keeps the WAV: a retry re-runs the whole
            // pipeline and the chunker needs PCM to find silence in, so re-deriving that from a
            // lossy copy would make a retried dictation worse than the first attempt.
            fun audioPart(pcmWav: ByteArray): InputPart {
                val ogg = OpusEncoder.encode(pcmWav)
                return if (ogg != null) {
                    InputPart.Audio(ogg, "audio/ogg")
                } else {
                    InputPart.Audio(pcmWav, "audio/wav")
                }
            }

            // One backend transcribing the whole recording, chunks and all, as a single unit —
            // so the fallback can race the finished job rather than individual chunks.
            suspend fun transcribeAll(
                backend: TranscriptionProvider,
                hints: List<String>,
            ): TranscriptionResult {
                val pieces = if (chunks.size == 1) {
                    listOf(
                        backend.transcribe(
                            instruction, contextParts + audioPart(wav), Settings.fidelity, hints,
                        ),
                    )
                } else {
                    coroutineScope {
                        // Bounded, because a ten-minute dictation fired all at once is the fastest
                        // way to hit a rate limit and turn a slow dictation into a failed one.
                        val gate = Semaphore(3)
                        chunks.map { chunk ->
                            async {
                                gate.withPermit {
                                    backend.transcribe(
                                        instruction,
                                        contextParts + audioPart(chunk.data),
                                        Settings.fidelity,
                                        hints,
                                    )
                                }
                            }
                        }.awaitAll()
                    }
                }
                return TranscriptionResult(
                    Transcript(
                        AudioChunker.stitch(pieces.map { it.transcript.transcript }),
                        pieces.firstOrNull()?.transcript?.language.orEmpty(),
                    ),
                    TokenUsage(
                        audioTokens = pieces.sumOf { it.usage.audioTokens ?: 0 }.takeIf { it > 0 },
                    ),
                    pieces.joinToString("\n") { it.rawOutput },
                )
            }

            // Hedged when a fallback is configured: the primary gets the whole delay to itself and
            // only a stalled one is ever raced. See FallbackTranscriber.
            val fallbackKind = Settings.fallbackProvider
            val fallbackClient = fallbackKind
                ?.let { kind -> Settings.keyFor(kind)?.takeIf { it.isNotEmpty() }?.let { kind to it } }
                ?.let { (kind, fallbackKey) ->
                    ProviderFactory.create(kind, fallbackKey, Settings.modelFor(kind))
                }

            // The number check rides on the primary, not on the hedge. A fallback exists to bound
            // latency when the primary stalls, and pairing a stalled request with a second one
            // would make the thing it is meant to rescue worse.
            //
            // Only meaningful when the first run was grounded: a recogniser never sees the screen
            // and keyterms cannot emit a digit, so there is no screen-derived number to catch —
            // it would bill the audio twice and compare a run against itself.
            val verifiesNumbers = Settings.numberCheck.applies(screenContext) &&
                client.grounding() is GroundingSupport.Multimodal &&
                screenContext != null && !screenContext.isEmpty

            suspend fun transcribeChecked(
                backend: TranscriptionProvider,
                hints: List<String>,
            ): TranscriptionResult = coroutineScope {
                if (!verifiesNumbers) return@coroutineScope transcribeAll(backend, hints)

                val grounded = async { transcribeAll(backend, hints) }
                val audioOnly = async {
                    // Deliberately without the context parts: this run has to be screen-blind, or
                    // it would agree with the grounded one about exactly the numbers in question.
                    runCatching {
                        backend.transcribe(
                            instruction, listOf(audioPart(wav)), Settings.fidelity, emptyList(),
                        )
                    }.getOrNull()
                }

                val result = grounded.await()
                // A failed verification pass must never cost the user their transcript: the
                // grounded run already succeeded, and unverified numbers beat no text at all.
                val checked = audioOnly.await() ?: return@coroutineScope result

                val reconciled = NumericGuard.reconcile(
                    result.transcript.transcript, checked.transcript.transcript,
                )
                log.info(
                    mapOf(
                        "dictation" to id,
                        "corrections" to reconciled.corrections.size.toString(),
                        "skipped" to if (reconciled.skippedForMismatch) "count mismatch" else "no",
                    ),
                ) { "number check" }

                result.copy(
                    transcript = result.transcript.copy(transcript = reconciled.text),
                    usage = TokenUsage.add(result.usage, checked.usage),
                )
            }

            val outcome = FallbackTranscriber(
                primary = { transcribeChecked(client, keyterms) },
                secondary = fallbackClient?.let { backend ->
                    // A fallback with no keyterm channel simply ignores the hints.
                    FallbackTranscriber.Transcriber { transcribeAll(backend, keyterms) }
                },
                hedgeAfterMillis = Settings.fallbackAfterSeconds * 1000L,
            ).transcribe(
                primaryName = client.name,
                primaryModel = client.model,
                secondaryName = fallbackClient?.name.orEmpty(),
                secondaryModel = fallbackClient?.model.orEmpty(),
            )

            record.requestMillis = System.currentTimeMillis() - requestStart
            record.audioTokens = outcome.result.usage.audioTokens
            // Recorded as the backend that answered, not the one that was asked.
            record.model = outcome.attribution.model

            val text = outcome.result.transcript.transcript
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
                // Not an error, and the one outcome people report as one: the key worked, the
                // request worked, and nothing was said.
                log.info(mapOf("dictation" to id)) { "nothing was said" }
            }

            record.status = DictationRecord.Status.COMPLETED
            record.text = text

            // A rewrite is a second pass over a transcript that already exists, so the verbatim
            // version is stored either way and "what did I actually say" stays answerable.
            var delivered = text
            if (style.isRewrite && text.isNotBlank()) {
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
            val contextParts = record.context
                ?.takeIf { !it.isEmpty && client.grounding() is GroundingSupport.Multimodal }
                ?.let { ContextEncoder().encode(it) }
                .orEmpty()

            val result = client.transcribe(
                PromptAssets.systemInstruction(context, record.fidelity),
                contextParts + InputPart.Audio(wav, "audio/wav"),
                record.fidelity,
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
