package app.donottype.core

import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import java.io.InputStream
import java.nio.FloatBuffer
import java.nio.LongBuffer
import kotlin.math.roundToInt

/**
 * Whether a recording contains speech worth sending to a recogniser.
 *
 * This runs the official Silero VAD v6.2.1 ONNX model. Its recurrent state and 64-sample context
 * are carried across the upstream 512-sample windows, then the upstream 0.5/0.35 hysteresis,
 * 100 ms end silence and 250 ms minimum speech duration finalise segments. It replaces the local
 * recording-relative noise floor, which rejected continuous speech whenever there was no quiet
 * section from which to infer a floor.
 */
class SpeechActivity(model: ByteArray) : AutoCloseable {
    constructor(model: InputStream) : this(model.use { it.readBytes() })

    data class Reading(
        val speechMilliseconds: Int,
        val maximumProbability: Double,
        val meanProbability: Double,
        val durationSeconds: Double,
    ) {
        val hasSpeech: Boolean get() = speechMilliseconds > 0

        val summary: String
            get() = "silero speech=${speechMilliseconds}ms " +
                "max=${"%.3f".format(maximumProbability)} " +
                "mean=${"%.3f".format(meanProbability)} " +
                "of ${"%.2f".format(durationSeconds)}s"
    }

    private val environment = OrtEnvironment.getEnvironment()
    private val session: OrtSession

    init {
        val options = OrtSession.SessionOptions().apply {
            setInterOpNumThreads(1)
            setIntraOpNumThreads(1)
            addCPU(true)
        }
        session = options.use { environment.createSession(model, it) }
    }

    /** @param pcm 16 kHz mono 16-bit little-endian samples, without a WAV header. */
    fun measure(pcm: ByteArray, sampleRate: Int = SAMPLE_RATE): Reading {
        require(sampleRate == SAMPLE_RATE) {
            "Silero VAD expected $SAMPLE_RATE Hz audio, not $sampleRate Hz."
        }

        val sampleCount = pcm.size / 2
        val duration = sampleCount.toDouble() / sampleRate
        if (sampleCount == 0) return Reading(0, 0.0, 0.0, duration)

        val probabilities = probabilities(pcm, sampleCount)
        val speechSamples = finalisedSpeechSamples(probabilities, sampleCount)
        return Reading(
            (speechSamples * 1_000.0 / sampleRate).roundToInt(),
            probabilities.maxOrNull()?.toDouble() ?: 0.0,
            probabilities.map(Float::toDouble).average().takeUnless(Double::isNaN) ?: 0.0,
            duration,
        )
    }

    /** @param wav a 16 kHz mono 16-bit PCM WAV, header and all. */
    fun measureWav(wav: ByteArray): Reading {
        val body = AudioChunker.pcmBody(wav)
            ?: throw IllegalArgumentException("The recording is not a 16 kHz mono PCM WAV.")
        return measure(body)
    }

    override fun close() {
        session.close()
    }

    private fun probabilities(pcm: ByteArray, sampleCount: Int): List<Float> {
        var state = FloatArray(2 * 128)
        val context = FloatArray(64)
        val probabilities = ArrayList<Float>(
            (sampleCount + WINDOW_SAMPLES - 1) / WINDOW_SAMPLES,
        )

        var offset = 0
        while (offset < sampleCount) {
            val input = FloatArray(64 + WINDOW_SAMPLES)
            context.copyInto(input)
            val count = minOf(WINDOW_SAMPLES, sampleCount - offset)
            repeat(count) { index ->
                val byteOffset = (offset + index) * 2
                val low = pcm[byteOffset].toInt() and 0xFF
                val high = pcm[byteOffset + 1].toInt()
                input[64 + index] = ((high shl 8) or low).toShort() / 32_768f
            }

            OnnxTensor.createTensor(
                environment, FloatBuffer.wrap(input), longArrayOf(1, 576),
            ).use { inputTensor ->
                OnnxTensor.createTensor(
                    environment, FloatBuffer.wrap(state), longArrayOf(2, 1, 128),
                ).use { stateTensor ->
                    OnnxTensor.createTensor(
                        environment, LongBuffer.wrap(longArrayOf(SAMPLE_RATE.toLong())), longArrayOf(),
                    ).use { rateTensor ->
                        session.run(
                            mapOf(
                                "input" to inputTensor,
                                "state" to stateTensor,
                                "sr" to rateTensor,
                            ),
                        ).use { outputs ->
                            @Suppress("UNCHECKED_CAST")
                            val output = outputs.get("output").orElseThrow().value
                                as Array<FloatArray>
                            @Suppress("UNCHECKED_CAST")
                            val nextState = outputs.get("stateN").orElseThrow().value
                                as Array<Array<FloatArray>>
                            probabilities += output[0][0]
                            state = nextState.flatMap { batch -> batch.flatMap(FloatArray::asIterable) }
                                .toFloatArray()
                        }
                    }
                }
            }

            input.copyInto(
                context, startIndex = input.size - context.size, endIndex = input.size,
            )
            offset += WINDOW_SAMPLES
        }
        return probabilities
    }

    /** The yes/no portion of upstream get_speech_timestamps. */
    private fun finalisedSpeechSamples(
        probabilities: List<Float>,
        audioLengthSamples: Int,
    ): Int {
        val minimumSpeechSamples = SAMPLE_RATE * MINIMUM_SPEECH_MILLISECONDS / 1_000
        val minimumSilenceSamples = SAMPLE_RATE * MINIMUM_SILENCE_MILLISECONDS / 1_000
        var speechStart: Int? = null
        var possibleEnd: Int? = null
        var total = 0

        probabilities.forEachIndexed { index, probability ->
            val current = WINDOW_SAMPLES * index
            if (probability >= THRESHOLD) {
                possibleEnd = null
                if (speechStart == null) speechStart = current
                return@forEachIndexed
            }

            val start = speechStart
            if (probability >= NEGATIVE_THRESHOLD || start == null) return@forEachIndexed
            if (possibleEnd == null) possibleEnd = current
            val end = possibleEnd ?: return@forEachIndexed
            if (current - end < minimumSilenceSamples) return@forEachIndexed

            if (end - start > minimumSpeechSamples) total += end - start
            speechStart = null
            possibleEnd = null
        }

        speechStart?.let { start ->
            if (audioLengthSamples - start > minimumSpeechSamples) {
                total += audioLengthSamples - start
            }
        }
        return total
    }

    companion object {
        const val SAMPLE_RATE = 16_000
        const val WINDOW_SAMPLES = 512
        const val THRESHOLD = 0.5f
        const val NEGATIVE_THRESHOLD = 0.35f
        const val MINIMUM_SPEECH_MILLISECONDS = 250
        const val MINIMUM_SILENCE_MILLISECONDS = 100
    }
}
