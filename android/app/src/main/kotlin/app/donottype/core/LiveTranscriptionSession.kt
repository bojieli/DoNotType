package app.donottype.core

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.joinAll
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit

/** Segments PCM and transcribes complete VAD parts while capture continues. */
class LiveTranscriptionSession(
    private val primaryName: String,
    private val primaryModel: String,
    context: ScreenContext?,
    private val transcribe: suspend (ByteArray, ScreenContext?) -> FallbackTranscriber.Outcome,
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val audio = Channel<ByteArray>(Channel.UNLIMITED)
    private val segmenter = AudioChunker.StreamingSegmenter()
    private val permits = Semaphore(3)
    private val tasks = sortedMapOf<Int, kotlinx.coroutines.Deferred<FallbackTranscriber.Outcome?>>()
    @Volatile private var currentContext = context
    @Volatile private var finished = false

    private val worker = scope.launch {
        for (pcm in audio) {
            segmenter.append(pcm).forEach(::submit)
        }
    }

    /** Called from AudioRecord's capture thread; the unbounded channel preserves every sample. */
    fun append(pcm: ByteArray) {
        if (!finished) audio.trySend(pcm)
    }

    fun setContext(context: ScreenContext?) {
        currentContext = context
    }

    suspend fun finish(context: ScreenContext?): FallbackTranscriber.Outcome {
        setContext(context)
        if (!finished) {
            finished = true
            audio.close()
        }
        worker.join()
        segmenter.finish()?.let(::submit)
        tasks.values.toList().joinAll()
        val outcomes = tasks.values.mapNotNull { it.await() }
        val results = outcomes.map { it.result }
        val result = TranscriptionResult(
            Transcript(
                AudioChunker.stitch(results.map { it.transcript.transcript }),
                results.firstOrNull()?.transcript?.language.orEmpty(),
            ),
            results.fold(TokenUsage()) { total, piece -> TokenUsage.add(total, piece.usage) },
            results.joinToString("\n") { it.rawOutput },
        )
        val outcome = FallbackTranscriber.Outcome(result, attribution(outcomes))
        scope.cancel()
        return outcome
    }

    fun cancel() {
        if (!finished) {
            finished = true
            audio.close()
        }
        scope.cancel()
    }

    private fun submit(chunk: AudioChunker.Chunk) {
        val context = currentContext
        tasks[chunk.index] = scope.async {
            if (!SpeechActivity.measureWav(chunk.data).hasSpeech) return@async null
            permits.withPermit { transcribe(chunk.data, context) }
        }
    }

    private fun attribution(
        outcomes: List<FallbackTranscriber.Outcome>,
    ): FallbackTranscriber.Attribution {
        if (outcomes.isEmpty()) {
            return FallbackTranscriber.Attribution(primaryName, primaryModel, false)
        }
        return FallbackTranscriber.Attribution(
            outcomes.map { it.attribution.provider }.distinct().joinToString(" + "),
            outcomes.map { it.attribution.model }.distinct().joinToString(" + "),
            outcomes.any { it.attribution.wasFallback },
        )
    }
}
