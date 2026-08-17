package app.donottype.core

import android.content.Context
import android.net.Uri
import app.donottype.PromptAssets
import app.donottype.Settings
import app.donottype.audio.AudioDecoder
import app.donottype.audio.OpusEncoder
import app.donottype.audio.WavRecorder
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit

/**
 * Transcribes a recording that already exists, rather than one being spoken right now.
 *
 * Live dictation is a latency problem: the user is waiting, the audio is already in the right
 * format, and every decision exists to shorten the wait. A file is a *throughput* problem — it may
 * be forty minutes long, in a format nothing downstream understands, and nobody is waiting on the
 * first word.
 *
 * The invariant is the one the whole project rests on: the verbatim transcript is produced first
 * and returned alongside whatever was derived from it, always, including for summaries where the
 * derived text is by definition missing most of what was said.
 */
class FileTranscriber(
    private val context: Context,
    private val service: DictationService,
) {
    private val log = Log("file")

    /** What the caller can show while this runs. A forty-minute file is not a spinner. */
    sealed class Progress {
        object Decoding : Progress()
        data class Transcribing(val done: Int, val of: Int) : Progress()
        data class Deriving(val mode: TranscriptMode) : Progress()
    }

    data class Outcome(
        val fileName: String,
        /** Word for word, at the requested fidelity. Always present. */
        val verbatim: String,
        /** What the mode produced. Identical to [verbatim] for verbatim. */
        val delivered: String,
        val mode: TranscriptMode,
        val language: String,
        val audioTokens: Int?,
        val chunkCount: Int,
        val durationSeconds: Double,
        val decodeMillis: Long,
        val transcriptionMillis: Long,
        val secondStageMillis: Long?,
        val provider: String,
        val model: String,
        /** The backend that ran the second stage, when it was not the transcription one. */
        val secondStageProvider: String?,
    ) {
        val totalMillis: Long get() = decodeMillis + transcriptionMillis + (secondStageMillis ?: 0)
    }

    /**
     * The backend that can run a second stage, or null when nothing configured can.
     *
     * A recogniser has no text channel, so this is a capability question rather than a preference.
     */
    fun secondStageBackend(): ProviderKind? {
        if (!Settings.provider.isSpeechRecognition) return Settings.provider
        return ProviderKind.entries.firstOrNull { kind ->
            !kind.isSpeechRecognition && !Settings.keyFor(kind).isNullOrBlank()
        }
    }

    /**
     * Whether this configuration can run the mode at all, asked before any audio is uploaded.
     *
     * Discovering that a summary is impossible *after* billing forty minutes of audio would be an
     * expensive way to learn it.
     */
    fun supports(mode: TranscriptMode): Boolean =
        !mode.needsSecondPass || secondStageBackend() != null

    suspend fun transcribe(
        uri: Uri,
        fileName: String,
        mode: TranscriptMode,
        onProgress: (Progress) -> Unit = {},
    ): Result<Outcome> {
        val key = Settings.apiKey
        if (key.isNullOrBlank()) {
            return Result.failure(ProviderException("No API key. Add one in Settings."))
        }
        if (!supports(mode)) {
            return Result.failure(
                ProviderException(
                    "${Settings.provider.id} is a speech recognition service: it transcribes audio " +
                        "and cannot do anything with text, so it cannot produce a ${mode.id}. " +
                        "Choose Verbatim, or add a key for Gemini or OpenRouter.",
                ),
            )
        }

        log.info(
            mapOf(
                "file" to fileName,
                "mode" to mode.id,
                "provider" to Settings.provider.id,
                "model" to Settings.model,
            ),
        ) { "transcribing file" }

        return try {
            onProgress(Progress.Decoding)
            val decodeStart = System.currentTimeMillis()
            val wav = AudioDecoder.decodeToWav(context, uri)
            val decodeMillis = System.currentTimeMillis() - decodeStart

            // A selected file deserves an explicit answer rather than the keyboard's silent no-op,
            // but it gets the same local Silero gate before any bytes leave the device.
            val activity = service.measureSpeech(wav)
            if (!activity.hasSpeech) {
                log.info(
                    mapOf("file" to fileName, "audio" to activity.summary),
                ) { "no speech in the recording" }
                throw NoSpeechException()
            }

            val instruction = PromptAssets.systemInstruction(context, Settings.fidelity)
            val client = ProviderFactory.create(Settings.provider, key, Settings.model)

            val transcribeStart = System.currentTimeMillis()
            val (result, chunkCount) = transcribeChunks(client, instruction, wav, onProgress)
            val transcriptionMillis = System.currentTimeMillis() - transcribeStart
            val verbatim = result.transcript.transcript.trim()

            log.info(
                mapOf(
                    "file" to fileName,
                    "chars" to verbatim.length.toString(),
                    "ms" to transcriptionMillis.toString(),
                ),
            ) { "transcribed file" }
            log.content("transcript", LogLevel.TRACE) { verbatim }

            var delivered = verbatim
            var secondStageMillis: Long? = null
            var secondStageProvider: String? = null

            // An empty transcript means silence, and there is nothing to rewrite or summarise.
            // Running the second stage anyway would ask a model to write prose from nothing, which
            // is the one way this pipeline could invent words outright.
            if (mode.needsSecondPass && verbatim.isNotEmpty()) {
                val kind = secondStageBackend()
                val stageKey = kind?.let { Settings.keyFor(it) }
                val stageInstruction = PromptAssets.secondStageInstruction(context, mode)
                if (kind != null && !stageKey.isNullOrBlank() && stageInstruction != null) {
                    onProgress(Progress.Deriving(mode))
                    val start = System.currentTimeMillis()
                    val backend = ProviderFactory.create(kind, stageKey, Settings.modelFor(kind))
                    val derived = backend.transcribe(
                        stageInstruction,
                        listOf(InputPart.Text(verbatim)),
                        Settings.fidelity,
                    ).transcript.transcript.trim()
                    secondStageMillis = System.currentTimeMillis() - start
                    // A second stage that comes back empty is a failure of the second stage, not
                    // of the transcription: the words survive either way.
                    if (derived.isNotEmpty()) delivered = derived
                    if (kind != Settings.provider) secondStageProvider = kind.id
                    log.info(
                        mapOf(
                            "mode" to mode.id,
                            "chars" to delivered.length.toString(),
                            "from" to verbatim.length.toString(),
                            "provider" to kind.id,
                        ),
                    ) { "second stage finished" }
                }
            }

            val outcome = Outcome(
                fileName = fileName,
                verbatim = verbatim,
                delivered = delivered,
                mode = mode,
                language = result.transcript.language,
                audioTokens = result.usage.audioTokens,
                chunkCount = chunkCount,
                durationSeconds = WavRecorder.durationSeconds(wav),
                decodeMillis = decodeMillis,
                transcriptionMillis = transcriptionMillis,
                secondStageMillis = secondStageMillis,
                provider = client.name,
                model = client.model,
                secondStageProvider = secondStageProvider,
            )
            store(outcome)
            Result.success(outcome)
        } catch (error: Exception) {
            log.error(
                mapOf("file" to fileName, "error" to (error.message ?: error::class.simpleName.orEmpty())),
            ) { "file transcription failed" }
            Result.failure(error)
        }
    }

    /** Splits on silence and transcribes concurrently, exactly as a long dictation is handled. */
    private suspend fun transcribeChunks(
        client: TranscriptionProvider,
        instruction: String,
        wav: ByteArray,
        onProgress: (Progress) -> Unit,
    ): Transcribed {
        val chunks = AudioChunker.split(wav)
        onProgress(Progress.Transcribing(0, chunks.size))

        val dictionary = Settings.personalDictionaryTerms()
        val (referenceParts, keyterms) = when (val grounding = client.grounding()) {
            is GroundingSupport.Multimodal -> buildList {
                PersonalDictionary.referenceBlock(dictionary)?.let { add(InputPart.Text(it)) }
            } to emptyList()
            is GroundingSupport.Keyterms -> emptyList<InputPart>() to PersonalDictionary.keyterms(
                dictionary, grounding.maxTerms, grounding.maxCharsPerTerm,
            )
            is GroundingSupport.None -> emptyList<InputPart>() to emptyList()
        }

        fun audioPart(pcm: ByteArray): InputPart {
            val ogg = OpusEncoder.encode(pcm)
            return if (ogg != null) InputPart.Audio(ogg, "audio/ogg") else InputPart.Audio(pcm, "audio/wav")
        }

        if (chunks.size == 1) {
            val single = client.transcribe(
                instruction, referenceParts + audioPart(wav), Settings.fidelity, keyterms,
            )
            onProgress(Progress.Transcribing(1, 1))
            return Transcribed(single, 1)
        }

        log.info(mapOf("chunks" to chunks.size.toString())) { "split recording" }
        var finished = 0
        val pieces = coroutineScope {
            // Bounded, because a forty-minute file fired all at once is the fastest way to hit a
            // rate limit and turn a slow transcription into a failed one.
            val gate = Semaphore(3)
            chunks.map { chunk ->
                async {
                    gate.withPermit {
                        client.transcribe(
                            instruction, referenceParts + audioPart(chunk.data),
                            Settings.fidelity, keyterms,
                        ).also {
                            synchronized(this@FileTranscriber) {
                                finished += 1
                                onProgress(Progress.Transcribing(finished, chunks.size))
                            }
                        }
                    }
                }
            }.awaitAll()
        }

        return Transcribed(
            TranscriptionResult(
                Transcript(
                    AudioChunker.stitch(pieces.map { it.transcript.transcript }),
                    pieces.firstOrNull()?.transcript?.language.orEmpty(),
                ),
                TokenUsage(audioTokens = pieces.sumOf { it.usage.audioTokens ?: 0 }.takeIf { it > 0 }),
                pieces.joinToString("\n") { it.rawOutput },
            ),
            chunks.size,
        )
    }

    /**
     * What came back, and how many requests it took.
     *
     * The count is carried out rather than recomputed: asking the chunker again would re-run the
     * silence scan and materialise a second copy of a recording that may be forty minutes long, to
     * learn a number this function already had.
     */
    private data class Transcribed(val result: TranscriptionResult, val chunkCount: Int)

    /**
     * Files land in the same history as dictations, so searching does not depend on remembering how
     * something was captured. The recording stays where the user put it rather than being copied.
     */
    private fun store(outcome: Outcome) {
        service.history.insert(
            DictationRecord(
                status = DictationRecord.Status.COMPLETED,
                text = outcome.verbatim,
                styledText = if (outcome.mode is TranscriptMode.Verbatim) null else outcome.delivered,
                mode = outcome.mode.id,
                sourceFileName = outcome.fileName,
                model = outcome.model,
                fidelity = Settings.fidelity,
                durationSeconds = outcome.durationSeconds,
                latencyMillis = outcome.totalMillis,
                requestMillis = outcome.transcriptionMillis,
                audioTokens = outcome.audioTokens,
            ),
            null,
        )
    }
}
