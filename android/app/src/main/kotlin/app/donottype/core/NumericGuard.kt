package app.donottype.core

/**
 * Takes digit sequences from an audio-only transcript and puts them into a grounded one.
 *
 * The evaluation suite has been consistent about where grounding goes wrong. Word-level near-misses
 * pass — names, acronym chains, jargon, brands, code-switched Mandarin — while *every* measured
 * regression has been a number: 1.5 to 2.5, 4240 to 1024, 4240 to 3240. A value on screen is a
 * strong prior, and unlike a misspelled name a wrong number is not recoverable by reading it;
 * nothing in the sentence marks it as wrong.
 *
 * So this is deliberately not a general "trust the audio more" mechanism. It is scoped to the one
 * span type that measurably regresses, and it takes those spans from a run that could not have seen
 * the screen at all. The two requests are independent, so the cost is tokens rather than latency
 * when they are issued concurrently.
 *
 * Ported from `Sources/DoNotTypeCore/NumericGuard.swift` and kept identical to it: the same
 * utterance dictated on a phone and a laptop has to produce the same numbers, and the measurements
 * in the changelog describe one behaviour, not two.
 */
object NumericGuard {

    /**
     * A digit run, with any separators that sit *between* digits — so 3.5, 1,024 and 16:9 survive
     * as one token while a trailing full stop does not become part of the number.
     */
    private val PATTERN = Regex("""[0-9]+(?:[.,:\-][0-9]+)*""")

    /**
     * @param text the grounded transcript with the spoken numbers put back into it.
     * @param corrections numbers taken from the audio-only run, as (was, became).
     * @param skippedForMismatch the two transcripts disagreed on how many numbers there were.
     */
    data class Reconciliation(
        val text: String,
        val corrections: List<Pair<String, String>>,
        val skippedForMismatch: Boolean,
    )

    /**
     * Replaces each number in [grounded] with the number in the same position from [audioOnly].
     *
     * Positional alignment is only safe when both transcripts found the same *count* of numbers.
     * When they disagree, one of them heard an extra figure or dropped one, and matching them up by
     * index would move a value to somewhere it was never spoken — a worse failure than the one
     * being fixed. In that case the grounded transcript is returned untouched and the caller can
     * see why.
     */
    fun reconcile(grounded: String, audioOnly: String): Reconciliation {
        val groundedMatches = PATTERN.findAll(grounded).toList()
        val audioNumbers = numbers(audioOnly)

        if (groundedMatches.isEmpty()) {
            return Reconciliation(grounded, emptyList(), skippedForMismatch = false)
        }
        if (groundedMatches.size != audioNumbers.size) {
            return Reconciliation(grounded, emptyList(), skippedForMismatch = true)
        }

        val corrections = mutableListOf<Pair<String, String>>()
        val result = StringBuilder()
        var cursor = 0

        groundedMatches.forEachIndexed { index, match ->
            val spoken = audioNumbers[index]
            result.append(grounded, cursor, match.range.first)
            result.append(spoken)
            cursor = match.range.last + 1
            if (match.value != spoken) corrections += match.value to spoken
        }
        result.append(grounded, cursor, grounded.length)

        return Reconciliation(result.toString(), corrections, skippedForMismatch = false)
    }

    internal fun numbers(text: String): List<String> =
        PATTERN.findAll(text).map { it.value }.toList()

    /**
     * Whether a dictation is in the regime where a screen number is likely to overwrite a spoken
     * one.
     *
     * Measured, and the two channels are not close. The same contradicting value substitutes for
     * what the speaker said 3/10 of the time from the visible-text section and 7/10 from the caret
     * window — the text the user has already typed into the field they are dictating into:
     *
     * | decoy in | without guard | with guard |
     * |---|---|---|
     * | visible text | 30% | 8% |
     * | caret window | 75% | 20% |
     *
     * So the trigger is digits near the caret, not digits anywhere on screen. The visible text is
     * ten times the budget and routinely contains numbers that have nothing to do with the
     * utterance — a sidebar, a timestamp, a row count — and spending a second request on those
     * would make the cost constant while the benefit stayed occasional.
     */
    fun isHighRisk(context: ScreenContext?): Boolean {
        if (context == null) return false
        return listOf(context.textBeforeCaret, context.textAfterCaret, context.selectedText)
            .any { text -> text?.any { it.isDigit() } == true }
    }
}

/** When to spend a second, screen-blind request to check the numbers. */
enum class NumberCheckPolicy(val id: String, val label: String) {
    NEVER("never", "Never"),

    /** Only when the text around the caret contains digits — where substitution is worst. */
    WHEN_CARET_HAS_NUMBERS(
        "whenCaretHasNumbers",
        "When the text you're editing contains numbers",
    ),

    ALWAYS("always", "Always"),
    ;

    /** Whether this policy fires for a given screen context. */
    fun applies(context: ScreenContext?): Boolean = when (this) {
        NEVER -> false
        ALWAYS -> true
        WHEN_CARET_HAS_NUMBERS -> NumericGuard.isHighRisk(context)
    }

    companion object {
        val DEFAULT = WHEN_CARET_HAS_NUMBERS

        fun from(id: String?): NumberCheckPolicy =
            entries.firstOrNull { it.id == id } ?: DEFAULT
    }
}
