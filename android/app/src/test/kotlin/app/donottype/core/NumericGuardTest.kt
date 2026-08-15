package app.donottype.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The numeric guard, case for case with `Tests/DoNotTypeCoreTests/NumericGuardTests.swift` and
 * `windows/DoNotType.Core.Tests/NumericGuardTests.cs`.
 *
 * Duplicated rather than shared on purpose, like the mode grammar: these are the cases the
 * evaluation suite actually produced, and the same utterance dictated on a phone and a laptop has
 * to come out with the same numbers in it.
 */
class NumericGuardTest {

    /** The exact failure the suite keeps producing: the screen's version number wins. */
    @Test
    fun `the grounded version number is replaced by the spoken one`() {
        val result = NumericGuard.reconcile(
            "We should use Gemini 2.5 Flash for this.",
            "We should use Gemini 1.5 Flash for this.",
        )

        assertEquals("We should use Gemini 1.5 Flash for this.", result.text)
        assertEquals(listOf("2.5" to "1.5"), result.corrections)
    }

    /** The measured code-switch regression, verbatim from the suite output. */
    @Test
    fun `the code-switch regression is repaired`() {
        val result = NumericGuard.reconcile("比如說這個是1024吧我印象里", "比如說這個是4240我印象裡")
        assertEquals("比如說這個是4240吧我印象里", result.text)
    }

    /**
     * Everything that is not a number must survive untouched — the grounded run is kept precisely
     * because it spells names and jargon better.
     */
    @Test
    fun `words are never taken from the audio-only run`() {
        val result = NumericGuard.reconcile(
            "Deploy SwiftUI to Kubernetes on port 8080.",
            "Deploy swift UI to kubernetes on port 8080.",
        )
        assertEquals("Deploy SwiftUI to Kubernetes on port 8080.", result.text)
        assertTrue(result.corrections.isEmpty())
    }

    @Test
    fun `transcripts without numbers are returned unchanged`() {
        val result = NumericGuard.reconcile("Ship the pricing page", "ship the pricing page")
        assertEquals("Ship the pricing page", result.text)
        assertFalse(result.skippedForMismatch)
    }

    /**
     * The safety rule. If the two runs disagree about how many numbers there are, one of them
     * dropped or invented a figure, and aligning by index would move a value somewhere it was never
     * spoken — a worse failure than the one being fixed.
     */
    @Test
    fun `mismatched counts leave the transcript alone`() {
        val result = NumericGuard.reconcile("Ports 80 and 443 are open.", "Port 443 is open.")

        assertEquals("Ports 80 and 443 are open.", result.text)
        assertTrue(result.skippedForMismatch)
        assertTrue(result.corrections.isEmpty())
    }

    @Test
    fun `multiple numbers are replaced positionally`() {
        val result = NumericGuard.reconcile(
            "Scale from 2 to 16 replicas by 5 p.m.",
            "Scale from 2 to 12 replicas by 4 p.m.",
        )
        assertEquals("Scale from 2 to 12 replicas by 4 p.m.", result.text)
        assertEquals(2, result.corrections.size)
    }

    /** A trailing full stop is punctuation, or the sentence would lose it. */
    @Test
    fun `sentence punctuation is not swallowed into the number`() {
        assertEquals(listOf("42"), NumericGuard.numbers("It costs 42."))
        assertEquals(listOf("3.5", "3"), NumericGuard.numbers("Use 3.5, not 3."))
    }

    @Test
    fun `separators inside numbers survive`() {
        assertEquals(
            listOf("1,024", "16:9", "2024-01"),
            NumericGuard.numbers("1,024 at 16:9 over 2024-01"),
        )
    }

    @Test
    fun `numbers attached to words are still found`() {
        assertEquals(listOf("4", "2", "8080"), NumericGuard.numbers("gpt-4o and v2 on port8080"))
    }

    /** A no-op when both runs agree, or it would be adding risk for nothing. */
    @Test
    fun `identical transcripts are unchanged`() {
        val text = "Deploy 3 replicas on port 8080 at 9:30."
        val result = NumericGuard.reconcile(text, text)
        assertEquals(text, result.text)
        assertTrue(result.corrections.isEmpty())
        assertFalse(result.skippedForMismatch)
    }

    /**
     * An audio-only run that failed entirely must not be allowed to strip numbers from a good
     * grounded transcript.
     */
    @Test
    fun `an empty audio-only run cannot damage the transcript`() {
        val result = NumericGuard.reconcile("Use port 8080.", "")
        assertEquals("Use port 8080.", result.text)
        assertTrue(result.skippedForMismatch)
    }

    // ---- When it fires --------------------------------------------------------------------------

    /**
     * The trigger is digits near the caret, not digits anywhere on screen: measured substitution is
     * 75% from the caret window against 30% from the visible text, and the visible text is ten
     * times the budget and full of numbers that have nothing to do with the utterance.
     */
    @Test
    fun `only the caret window counts as high risk`() {
        assertTrue(NumericGuard.isHighRisk(ScreenContext(textBeforeCaret = "version 2.5")))
        assertTrue(NumericGuard.isHighRisk(ScreenContext(textAfterCaret = "port 8080")))
        assertTrue(NumericGuard.isHighRisk(ScreenContext(selectedText = "1024")))

        assertFalse(
            "the visible text is not the trigger — see the measurements",
            NumericGuard.isHighRisk(ScreenContext(visibleText = "a sidebar showing 4240")),
        )
        assertFalse(NumericGuard.isHighRisk(ScreenContext(textBeforeCaret = "no digits")))
        assertFalse(NumericGuard.isHighRisk(null))
    }

    @Test
    fun `the outer policies ignore the context`() {
        assertFalse(NumberCheckPolicy.NEVER.applies(ScreenContext(textBeforeCaret = "2.5")))
        assertFalse(NumberCheckPolicy.NEVER.applies(null))
        assertTrue(NumberCheckPolicy.ALWAYS.applies(ScreenContext(textBeforeCaret = "2.5")))
        assertTrue(NumberCheckPolicy.ALWAYS.applies(null))
    }

    @Test
    fun `the default policy fires only where it was measured to help`() {
        val policy = NumberCheckPolicy.WHEN_CARET_HAS_NUMBERS
        assertTrue(policy.applies(ScreenContext(textBeforeCaret = "version 2.5")))
        assertFalse(policy.applies(ScreenContext(visibleText = "4240")))
    }

    /** The stored spelling has to round-trip, or a saved setting silently resets. */
    @Test
    fun `every policy round-trips through its stored spelling`() {
        NumberCheckPolicy.entries.forEach { policy ->
            assertEquals(policy, NumberCheckPolicy.from(policy.id))
        }
    }
}
