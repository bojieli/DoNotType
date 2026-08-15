package app.donottype.core

import kotlin.math.log10

/**
 * Whether a recording contains anything worth sending.
 *
 * A speech model handed silence does not reliably return silence. Asked to transcribe three seconds
 * of room tone it will often produce a plausible sentence — the well-documented case is a stock
 * phrase like "Thank you." or a subtitle credit — and a dictation tool that types that into
 * somebody's document has invented words they never said. That is the single failure this project
 * exists to prevent, so a rule in PROMPT.md is not enough on its own:
 *
 * - **Rule 7 only reaches model providers.** Deepgram, xAI and Mistral Voxtral are speech
 *   recognition endpoints with no system instruction, so the rule that says "silent or
 *   unintelligible audio returns an empty transcript" is never sent to them. Whisper-family
 *   recognisers are exactly the ones most documented for this behaviour.
 * - **An instruction is a request, not a guarantee**, even where it is delivered.
 *
 * A backend cannot hallucinate audio it never received. So the audio is checked here, before the
 * request, and that check is the only defence that holds for every backend.
 *
 * It decides on *modulation* rather than loudness: speech has syllables, pauses and plosives, so
 * its frame energies vary; a fan, a hum or a mains buzz does not. Gating on volume would discard
 * somebody dictating in a noisy street, a much worse failure than the one being prevented. Ported
 * from `Sources/DoNotTypeCore/SpeechActivity.swift`, thresholds and all — see
 * `eval/audio/silence/README.md` for the measurements they came from.
 */
object SpeechActivity {

    /**
     * @param speechMilliseconds how much audio sat clearly above the recording's own noise floor.
     * @param noiseFloorDecibels the recording's own floor, in dBFS. Roughly the room.
     * @param peakDecibels the loudest 20 ms in the recording, in dBFS.
     */
    data class Reading(
        val speechMilliseconds: Int,
        val noiseFloorDecibels: Double,
        val peakDecibels: Double,
        val durationSeconds: Double,
    ) {
        val hasSpeech: Boolean get() = speechMilliseconds >= MINIMUM_SPEECH_MILLISECONDS

        /** For the log, where a user who disagrees with the decision has to be able to see why. */
        val summary: String
            get() = "speech=${speechMilliseconds}ms " +
                "floor=${"%.1f".format(noiseFloorDecibels)}dB " +
                "peak=${"%.1f".format(peakDecibels)}dB " +
                "of ${"%.2f".format(durationSeconds)}s"
    }

    /** Below this, nothing is sent. See the measurements in the README. */
    const val MINIMUM_SPEECH_MILLISECONDS = 200

    /**
     * How far above the recording's own floor a frame has to sit to count as speech. Roughly the
     * difference between a room and somebody talking in it; steady noise never reaches it, whatever
     * its absolute level.
     */
    private const val MARGIN_DECIBELS = 8.0

    /**
     * A floor below which nothing counts, however far above the noise it is. Guards the degenerate
     * case where a single dithered sample in digital silence is infinitely above the floor, and is
     * set low enough that real speech never reaches it.
     */
    private const val ABSOLUTE_FLOOR_DECIBELS = -65.0

    private const val FRAME_MILLISECONDS = 20

    /** @param pcm 16 kHz mono 16-bit little-endian samples, without a WAV header. */
    fun measure(pcm: ByteArray, sampleRate: Int = 16_000): Reading {
        val frameSamples = sampleRate * FRAME_MILLISECONDS / 1_000
        val sampleCount = pcm.size / 2
        val duration = sampleCount.toDouble() / sampleRate

        if (sampleCount < frameSamples) return Reading(0, -120.0, -120.0, duration)

        val levels = ArrayList<Double>(sampleCount / frameSamples)
        var start = 0
        while (start + frameSamples <= sampleCount) {
            var energy = 0.0
            for (index in start until start + frameSamples) {
                val low = pcm[index * 2].toInt() and 0xFF
                val high = pcm[index * 2 + 1].toInt()
                val value = ((high shl 8) or low).toShort().toDouble()
                energy += value * value
            }
            val mean = energy / frameSamples
            // dBFS, with a floor so digital silence is a number rather than negative infinity.
            levels += 10 * log10(mean / (32_768.0 * 32_768.0) + 1e-12)
            start += frameSamples
        }

        if (levels.isEmpty()) return Reading(0, -120.0, -120.0, duration)

        // The tenth percentile rather than the minimum: one anomalously quiet frame should not
        // define the room, and speech contains real pauses that sit at the floor.
        val sorted = levels.sorted()
        val floor = sorted[minOf(sorted.size - 1, sorted.size / 10)]
        val peak = sorted.last()

        val speaking = levels.count { it > floor + MARGIN_DECIBELS && it > ABSOLUTE_FLOOR_DECIBELS }
        return Reading(speaking * FRAME_MILLISECONDS, floor, peak, duration)
    }

    /** @param wav a 16 kHz mono 16-bit WAV, header and all. */
    fun measureWav(wav: ByteArray): Reading {
        val body = AudioChunker.pcmBody(wav) ?: return Reading(0, -120.0, -120.0, 0.0)
        return measure(body)
    }
}
