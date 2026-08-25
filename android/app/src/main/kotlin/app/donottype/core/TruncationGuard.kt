package app.donottype.core

import kotlin.math.max

/**
 * The gate for a transcript that is *too short* for the audio.
 *
 * [HallucinationGuard] catches a model that invented words. This catches the opposite, and until it
 * existed nothing did: a model that stopped early and returned fluent, plausible text with the
 * middle of the dictation missing. The two are not symmetric. Fabrication is loud once you look for
 * it. Truncation is silent, because what comes back reads perfectly; it is only wrong in what it
 * does not say.
 *
 * Measured 2026-08-25 on a 90-second Mandarin recording: `gemini-3.5-flash` at `minimal` returned
 * roughly 100 characters of a 310-character transcript, stopping mid-sentence at the identical
 * point every time it failed, on 6 runs in 10. `gemini-3.6-flash` did it 0 times in 20. It is not
 * the output-token cap.
 *
 * The denominator is Silero-confirmed speech, not recording length. Across 350 real dictations the
 * legitimate minimum is 1.55 characters a second of audio and the truncated transcript ran 1.09 — a
 * 1.4x margin, which is a coin toss rather than a threshold, because speech is only 14% to 61% of a
 * recording. Against speech they separate: the truncated runs are 2.00 and 2.27, complete runs of
 * the same recording 6.31 and 7.78, and the minimum across 350 dictations 4.92.
 *
 * The costs are asymmetric. A false positive spends one request nobody sees; a false negative hands
 * somebody a plausible transcript with their words deleted. So the floor sits nearer the legitimate
 * minimum than the observed failure.
 */
object TruncationGuard {
    /** Characters per second of Silero-confirmed speech below which a transcript is suspect. */
    const val MINIMUM_CHARACTERS_PER_SECOND = 3.5

    /**
     * Below this much speech the ratio is not evidence.
     *
     * Short clips make the rate wild in both directions, and truncation is a long-audio failure:
     * 0 occurrences in 30 whole-file runs across six recordings that did not reproduce it. The same
     * reasoning as [HallucinationGuard.MINIMUM_SUSPICIOUS_CHARACTERS], from the other end.
     */
    const val MINIMUM_SPEECH_SECONDS = 20.0

    /**
     * Cheap pre-filter, so the expensive check runs only on plausible candidates.
     *
     * Characters per second of recording cannot decide anything, but it bounds the question from a
     * WAV header rather than a model. The fifth percentile of real dictations is 3.16 and the
     * median 7.57, so this admits roughly the bottom tenth for a second look.
     */
    const val SCREENING_CHARACTERS_PER_SECOND = 4.0

    sealed class Verdict {
        object Kept : Verdict()

        /** Carries the measurement, because a log reader needs the working and not a verdict. */
        data class SuspectedTruncation(val characters: Int, val speechSeconds: Double) : Verdict()

        val isSuspect: Boolean get() = this is SuspectedTruncation

        val summary: String
            get() = when (this) {
                is Kept -> "kept"
                is SuspectedTruncation -> String.format(
                    "%d chars in %.1fs of speech = %.2f chars/s, floor %.2f",
                    characters, speechSeconds,
                    characters / max(speechSeconds, 0.001), MINIMUM_CHARACTERS_PER_SECOND,
                )
            }
    }

    /** Whether this transcript is worth measuring properly. Costs a subtraction. */
    fun warrantsInspection(text: String, audioSeconds: Double?): Boolean {
        if (audioSeconds == null || audioSeconds <= 0) return false
        return text.trim().length / audioSeconds < SCREENING_CHARACTERS_PER_SECOND
    }

    /**
     * The verdict, given how much speech the recording actually contains.
     *
     * Unknown speech length yields [Verdict.Kept]: no measurement, no accusation.
     */
    fun inspect(text: String, speechSeconds: Double?): Verdict {
        if (speechSeconds == null || speechSeconds < MINIMUM_SPEECH_SECONDS) return Verdict.Kept
        val characters = text.trim().length
        if (characters == 0) return Verdict.Kept
        if (characters / speechSeconds >= MINIMUM_CHARACTERS_PER_SECOND) return Verdict.Kept
        return Verdict.SuspectedTruncation(characters, speechSeconds)
    }
}
