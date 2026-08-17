package app.donottype.core

import kotlin.math.abs
import kotlin.math.log10
import kotlin.math.max
import kotlin.math.min

/**
 * Turns captured samples into the bars the keyboard's indicator draws.
 *
 * ## Why this is not a multiplier
 *
 * The meter used to be `peak / 12000`, clamped — a linear scale, on a signal whose useful range
 * spans 50 dB, driven by the loudest sample of a quarter-second. Measured over the 20 ms frames of
 * every speech fixture in `eval/audio/` in which somebody is actually talking, the equivalent scale
 * on macOS spent 4–77% of them flat against the top of the meter, and a peak-driven one saturates
 * sooner still: speech peaks run about four times its own energy, so any recording at a sensible
 * level is above 12000 whenever a syllable lands. It could report that audio was arriving and
 * nothing else, while at the other end room tone at −58 dBFS drew a bar too small to see.
 *
 * Loudness is measured in decibels because that is how it is heard, so the scale is decibels, and
 * the span comes from the same measurements:
 *
 * | input | dBFS | bar |
 * |---|---|---|
 * | digital silence | −240 | 0.00 |
 * | room tone | −58 | 0.04 |
 * | quiet speech | −44 | 0.29 |
 * | conversational speech | −21 | 0.72 |
 * | loud speech | −14 | 0.85 |
 * | the loudest frame in any fixture | −5 | 1.00 |
 *
 * Speech lands in the top third and moves visibly within it, silence is flat, and a full bar means
 * the recording is using all the range it has. Ported from
 * `Sources/DoNotTypeCore/AudioLevelMeter.swift`, constants and all, and held to the same numbers by
 * the same fixtures.
 *
 * ## Why frames rather than a smoothed value
 *
 * The indicator draws a moving history, so each bar is a moment rather than a running average, and
 * the shape that walks across it is the envelope of the speech. Smoothing would flatten exactly the
 * detail that makes the meter read as somebody's voice rather than as an animation playing next to
 * it. Silence is a flat line that keeps scrolling: the microphone is live and hearing nothing,
 * which is a different report from a frozen meter and the one somebody who is not being heard
 * needs to see.
 */
class AudioLevelMeter(sampleRate: Int = 16_000) {

    /**
     * One bar of the meter.
     *
     * @param level 0–1, ready to scale a bar height by.
     * @param isClipping samples in here were clamped at the rail, so the recording is distorted
     *   before any backend sees it — usually input gain set too high, which nothing else in the app
     *   would ever tell the user. Counted rather than inferred from the level: speech peaks run
     *   about 12 dB above its own energy, so by the time a frame's energy is near full scale its
     *   peaks have been flattened for a long while.
     */
    data class Bar(val level: Double, val isClipping: Boolean) {
        companion object {
            val SILENT = Bar(0.0, false)
        }
    }

    companion object {
        /** An empty bar. Below room tone, so a quiet room reads as flat. */
        const val FLOOR_DECIBELS = -60.0

        /**
         * A full bar. Just under the loudest frame measured in any fixture, so a voice recorded at
         * a sensible level uses the top of the meter without living there.
         */
        const val CEILING_DECIBELS = -6.0

        /** A sample this loud is at the rail: 0.21 dB below full scale. */
        const val RAIL_AMPLITUDE = 32_000

        /**
         * How many samples at the rail make a frame a clipped one — half a millisecond of staying
         * there rather than passing through. Measured over the speech fixtures, the share of bars
         * marked at ×1 / ×1.5 / ×2 playback gain: `real-brand` 0.6% / 10.5% / 24.0%, `real-acronym`
         * 0.6% / 5.4% / 12.3%, everything else silent at its own gain. See the Swift original for
         * the whole table and the argument for eight rather than three.
         */
        const val RAIL_SAMPLES_PER_FRAME = 8

        /** Twenty milliseconds resolves syllables without making the meter twitch. */
        const val FRAME_MILLISECONDS = 20

        /**
         * 60 ms a bar. Long enough that a full meter is a second and a half of speech rather than
         * half a second of it, short enough to resolve individual syllables.
         */
        const val FRAMES_PER_BAR = 3

        /** The 0–1 height for one frame's level. Pure, so the table above can be asserted. */
        fun level(decibels: Double): Double =
            min(1.0, max(0.0, (decibels - FLOOR_DECIBELS) / (CEILING_DECIBELS - FLOOR_DECIBELS)))
    }

    private val frameLength = max(1, sampleRate * FRAME_MILLISECONDS / 1_000)

    private var frameEnergy = 0.0
    private var frameSamples = 0
    private var frameRailSamples = 0

    /**
     * Bars peak-hold their frames: a transient that only exists for 20 ms is exactly the thing a
     * meter must not average away, since it is what clips.
     */
    private var barPeak = Double.NEGATIVE_INFINITY
    private var barClipped = false
    private var barFrames = 0

    /** Half a sample left over from the previous call. See [append]. */
    private var carry = -1

    /**
     * Feeds captured audio in and returns whatever bars it completed.
     *
     * Partial frames — and a partial sample, since a read is free to end between the two bytes of
     * one — are carried across calls, because the caller hands over whatever `AudioRecord` gave it
     * and that is never a whole number of frames.
     *
     * @param pcm 16 kHz mono 16-bit little-endian samples, without a WAV header.
     * @param length how much of [pcm] was filled, which is what `AudioRecord.read` returned.
     */
    fun append(pcm: ByteArray, length: Int = pcm.size): List<Bar> {
        val bars = ArrayList<Bar>()
        var index = 0

        while (index < length) {
            val sample: Int
            if (carry >= 0) {
                sample = ((pcm[index].toInt() shl 8) or carry).toShort().toInt()
                carry = -1
                index += 1
            } else if (index + 1 < length) {
                val low = pcm[index].toInt() and 0xFF
                sample = ((pcm[index + 1].toInt() shl 8) or low).toShort().toInt()
                index += 2
            } else {
                carry = pcm[index].toInt() and 0xFF
                break
            }

            val value = sample / 32_768.0
            frameEnergy += value * value
            if (abs(sample) >= RAIL_AMPLITUDE) frameRailSamples += 1
            frameSamples += 1
            if (frameSamples < frameLength) continue

            // The epsilon makes digital silence a number rather than negative infinity: −120 dBFS.
            val decibels = 10 * log10(frameEnergy / frameLength + 1e-12)
            val clipped = frameRailSamples >= RAIL_SAMPLES_PER_FRAME
            frameEnergy = 0.0
            frameSamples = 0
            frameRailSamples = 0

            barPeak = max(barPeak, decibels)
            barClipped = barClipped || clipped
            barFrames += 1
            if (barFrames < FRAMES_PER_BAR) continue

            bars += Bar(level(barPeak), barClipped)
            barPeak = Double.NEGATIVE_INFINITY
            barClipped = false
            barFrames = 0
        }

        return bars
    }
}
