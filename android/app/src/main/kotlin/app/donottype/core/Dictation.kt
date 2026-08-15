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
        )

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

            val outcome = FallbackTranscriber(
                primary = { transcribeAll(client, keyterms) },
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
            record.status = DictationRecord.Status.COMPLETED
            record.text = text
            record.latencyMillis = System.currentTimeMillis() - releasedAt
            history.insert(record, if (Settings.keepAudio) wav else null)
            Result.success(record)
        } catch (error: Exception) {
            // Audio is kept so this can be retried from the settings screen, or when the keyboard
            // next opens with a working connection.
            // The advice rather than the exception. A history row that reads
            // `HTTP 429: {"error":{"code":"rate_limit_exceeded"…` is a log line somebody has to
            // decode weeks later; the advice says what happened and whether it is worth retrying.
            record.status = DictationRecord.Status.FAILED
            record.errorMessage = FailureAdvice.describe(error).message
            history.insert(record, wav)
            Result.failure(error)
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
            val result = ProviderFactory.create(Settings.provider, key, Settings.model)
                .transcribe(
                    PromptAssets.systemInstruction(context, record.fidelity),
                    listOf(InputPart.Audio(wav, "audio/wav")),
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
