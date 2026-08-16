package app.donottype.core

import kotlin.math.PI
import kotlin.math.exp
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
        /**
         * Share of the speaking frames' energy at and below [VOICE_BAND_HERTZ], 0 when nothing was
         * loud enough to measure. A voice sits high here; a click sits low.
         */
        val voiceBandRatio: Double,
    ) {
        val hasSpeech: Boolean
            get() {
                if (speechMilliseconds < MINIMUM_SPEECH_MILLISECONDS) return false
                // Enough speech to be sure on duration alone. The spectral test is for the
                // ambiguous short clip and must never get the chance to veto a real dictation.
                if (speechMilliseconds >= STRONG_SPEECH_MILLISECONDS) return true
                return voiceBandRatio >= MINIMUM_VOICE_BAND_RATIO
            }

        /** For the log, where a user who disagrees with the decision has to be able to see why. */
        val summary: String
            get() = "speech=${speechMilliseconds}ms " +
                "floor=${"%.1f".format(noiseFloorDecibels)}dB " +
                "peak=${"%.1f".format(peakDecibels)}dB " +
                "voice=${"%.0f".format(voiceBandRatio * 100)}% " +
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

    /**
     * Above this, duration alone settles it and the spectral test is not consulted.
     *
     * Set above every ambiguous case measured and below every real dictation: the longest click
     * produced 380 ms, the shortest genuine dictation 1320 ms.
     */
    const val STRONG_SPEECH_MILLISECONDS = 700

    /**
     * The share of energy a voice puts at or below [VOICE_BAND_HERTZ]. Midway between the two
     * populations measured: clicks at 23-24%, the quietest-scoring real speech at 39%.
     */
    const val MINIMUM_VOICE_BAND_RATIO = 0.32

    /**
     * Cutoff for the voice-band measurement. 250 Hz separated the two populations most widely of
     * the cutoffs measured (100-500 Hz).
     */
    private const val VOICE_BAND_HERTZ = 250.0

    /** @param pcm 16 kHz mono 16-bit little-endian samples, without a WAV header. */
    fun measure(pcm: ByteArray, sampleRate: Int = 16_000): Reading {
        val frameSamples = sampleRate * FRAME_MILLISECONDS / 1_000
        val sampleCount = pcm.size / 2
        val duration = sampleCount.toDouble() / sampleRate

        if (sampleCount < frameSamples) return Reading(0, -120.0, -120.0, duration, 0.0)

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

        if (levels.isEmpty()) return Reading(0, -120.0, -120.0, duration, 0.0)

        // The tenth percentile rather than the minimum: one anomalously quiet frame should not
        // define the room, and speech contains real pauses that sit at the floor.
        val sorted = levels.sorted()
        val floor = sorted[minOf(sorted.size - 1, sorted.size / 10)]
        val peak = sorted.last()

        val isSpeaking = levels.map { it > floor + MARGIN_DECIBELS && it > ABSOLUTE_FLOOR_DECIBELS }
        val speaking = isSpeaking.count { it }
        return Reading(
            speaking * FRAME_MILLISECONDS,
            floor,
            peak,
            duration,
            voiceBandRatio(pcm, sampleRate, frameSamples, isSpeaking),
        )
    }

    /**
     * Median share of frame energy surviving a low-pass at [VOICE_BAND_HERTZ], over the frames that
     * counted as speech.
     *
     * A one-pole filter rather than a transform: this separates two populations 11 points apart,
     * which a 6 dB/octave roll-off does perfectly well, and it has to stay identical to three
     * hand-written ports without an FFT going subtly different in any of them.
     *
     * The filter runs across the whole recording, including the frames that are not speech, so its
     * state is continuous — restarting it per frame would ring at every boundary. The median rather
     * than the mean, because one frame of a door closing should not decide what a sentence was.
     */
    private fun voiceBandRatio(
        pcm: ByteArray,
        sampleRate: Int,
        frameSamples: Int,
        isSpeaking: List<Boolean>,
    ): Double {
        val alpha = 1 - exp(-2 * PI * VOICE_BAND_HERTZ / sampleRate)
        val ratios = ArrayList<Double>(isSpeaking.size)
        var filtered = 0.0

        for (frame in isSpeaking.indices) {
            val start = frame * frameSamples
            var total = 0.0
            var low = 0.0
            for (index in start until start + frameSamples) {
                val lowByte = pcm[index * 2].toInt() and 0xFF
                val highByte = pcm[index * 2 + 1].toInt()
                val value = ((highByte shl 8) or lowByte).toShort().toDouble()
                filtered += alpha * (value - filtered)
                if (!isSpeaking[frame]) continue
                total += value * value
                low += filtered * filtered
            }
            if (isSpeaking[frame] && total > 0) ratios += low / total
        }

        if (ratios.isEmpty()) return 0.0
        val sorted = ratios.sorted()
        return sorted[sorted.size / 2]
    }

    /** @param wav a 16 kHz mono 16-bit WAV, header and all. */
    fun measureWav(wav: ByteArray): Reading {
        val body = AudioChunker.pcmBody(wav) ?: return Reading(0, -120.0, -120.0, 0.0, 0.0)
        return measure(body)
    }
}
