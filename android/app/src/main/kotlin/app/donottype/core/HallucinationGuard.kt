package app.donottype.core

/**
 * The gate on the way back, for audio that got past the gate on the way out.
 *
 * [SpeechActivity] refuses to send silence, and it is the better defence because it costs nothing
 * and works for every backend. It is not sufficient. Measured on real dictations: a 0.68-second
 * recording of room tone — a stray tap in a quiet room, 380 ms of transient 25 dB above a −63 dB
 * floor — passed the activity gate, and the model answered it with 876 characters of fluent,
 * topically-plausible prose the user had never said. It was not copied off the screen either: the
 * longest verbatim run shared with the screen context was nine words.
 *
 * PROMPT.md rule 7 asks for an empty transcript, which is an *omission* — a model already inventing
 * cannot notice it is failing to omit something. So the prompt asks for a token it must positively
 * write, and this checks for it. The rate ceiling is the backstop for models that ignore both; it
 * is a physical claim rather than a stylistic one, since speech has a maximum rate and text far
 * above it did not come from the audio.
 *
 * Ported by hand from Sources/DoNotTypeCore/HallucinationGuard.swift. The constants and the
 * decisions must stay identical across the two.
 */
object HallucinationGuard {

    /**
     * What the model writes when it heard nothing. A positive answer, so its absence is detectable
     * — unlike an empty string, which is indistinguishable from a model that never addressed the
     * question.
     */
    const val MARKER = "[NO_SPEECH]"

    /**
     * Characters per second of audio above which the transcript did not come from the speech.
     *
     * Fast English narration is ~200 wpm, about 17 characters a second. Real dictations measured
     * through this app run 7–15. The fabrications that prompted this guard ran 822 and 1288.
     */
    const val MAXIMUM_CHARACTERS_PER_SECOND = 25.0

    /**
     * Below this the ratio is not evidence, however extreme it looks. A two-second recording
     * answered with one ordinary sentence is already 35 characters a second and perfectly real.
     * The measured fabrications ran 625, 646 and 876 characters, so this sits well under them and
     * well over anything a person says quickly.
     */
    const val MINIMUM_SUSPICIOUS_CHARACTERS = 200

    /** Why a transcript was suppressed, with the measurement that produced the decision. */
    sealed class Verdict {
        object Kept : Verdict()

        object NoSpeechMarker : Verdict()

        data class ImpossibleRate(val characters: Int, val seconds: Double) : Verdict()

        val summary: String
            get() = when (this) {
                is Kept -> "kept"
                is NoSpeechMarker -> "model reported no speech"
                is ImpossibleRate ->
                    "%d chars in %.2fs = %.0f chars/s, ceiling %.0f".format(
                        characters,
                        seconds,
                        characters / maxOf(seconds, 0.001),
                        MAXIMUM_CHARACTERS_PER_SECOND,
                    )
            }
    }

    private val NOISE = charArrayOf(' ', '\t', '\n', '\r', '"', '\'', '`', '.', '。')

    /**
     * Exactly the token the prompt asks for, allowing only surrounding quotes, a full stop and
     * whitespace. Deliberately strict: a looser match on the words would silently delete a
     * dictation of somebody saying them.
     */
    fun isNoSpeechMarker(text: String): Boolean {
        val stripped = text.trim(*NOISE)
        return stripped.equals(MARKER, ignoreCase = true) ||
            stripped.equals("NO_SPEECH", ignoreCase = true)
    }

    /**
     * More text than the audio could physically contain. A duration of null or zero means unknown,
     * and unknown is not suspicious: no measurement, no verdict.
     */
    fun exceedsPlausibleRate(text: String, audioSeconds: Double?): Boolean {
        if (audioSeconds == null || audioSeconds <= 0) return false
        val characters = text.trim().length
        return characters >= MINIMUM_SUSPICIOUS_CHARACTERS &&
            characters / audioSeconds > MAXIMUM_CHARACTERS_PER_SECOND
    }

    /** The whole decision. Returns the transcript to use and why it changed, if it did. */
    fun inspect(transcript: Transcript, audioSeconds: Double?): Pair<Transcript, Verdict> = when {
        isNoSpeechMarker(transcript.transcript) ->
            transcript.copy(transcript = "") to Verdict.NoSpeechMarker

        exceedsPlausibleRate(transcript.transcript, audioSeconds) ->
            transcript.copy(transcript = "") to
                Verdict.ImpossibleRate(transcript.transcript.trim().length, audioSeconds ?: 0.0)

        else -> transcript to Verdict.Kept
    }
}
