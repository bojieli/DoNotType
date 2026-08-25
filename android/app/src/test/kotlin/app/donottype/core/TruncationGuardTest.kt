package app.donottype.core

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The thresholds, pinned against the measurements that chose them.
 *
 * Every number is from 2026-08-25: 350 real dictations for the legitimate floor, and one 90-second
 * Mandarin recording that `gemini-3.5-flash` truncated on 6 runs in 10 for the failure. Mirrors
 * `TruncationGuardTests` in Swift and C# — if a constant moves, all three say what it was traded
 * against.
 */
class TruncationGuardTest {
    private fun chars(count: Int) = "字".repeat(count)

    /** The observed failure: ~100 characters where ~310 belonged, 49 s of speech. */
    @Test
    fun `the measured truncation is caught`() {
        val verdict = TruncationGuard.inspect(chars(98), 49.0)
        assertTrue(verdict.isSuspect)
        assertTrue(verdict is TruncationGuard.Verdict.SuspectedTruncation && verdict.characters == 98)
    }

    @Test
    fun `a complete transcript of the same recording is kept`() {
        for (characters in listOf(309, 381)) {
            assertFalse(TruncationGuard.inspect(chars(characters), 49.0).isSuspect)
        }
    }

    /**
     * The lowest rate any of 350 real dictations reached was 4.92 characters a second of speech.
     * The floor has to sit below that with room, or the guard fires on ordinary dictation.
     */
    @Test
    fun `the slowest real dictation measured is not flagged`() {
        assertFalse(TruncationGuard.inspect(chars(109), 22.2).isSuspect)
        assertTrue(TruncationGuard.MINIMUM_CHARACTERS_PER_SECOND < 4.92)
    }

    @Test
    fun `a short clip is never judged`() {
        assertFalse(TruncationGuard.inspect("hi", 3.0).isSuspect)
        assertFalse(TruncationGuard.inspect("hi", 19.9).isSuspect)
    }

    @Test
    fun `unknown speech length is not suspicious`() {
        assertFalse(TruncationGuard.inspect("short", null).isSuspect)
    }

    /** An empty transcript is the [NO_SPEECH] path's business, not this one. */
    @Test
    fun `an empty transcript is left to the other guard`() {
        assertFalse(TruncationGuard.inspect("", 60.0).isSuspect)
        assertFalse(TruncationGuard.inspect("   ", 60.0).isSuspect)
    }

    @Test
    fun `the cheap screen admits the failure and skips ordinary transcripts`() {
        assertTrue(TruncationGuard.warrantsInspection(chars(98), 90.0))
        assertFalse(TruncationGuard.warrantsInspection("x".repeat(681), 90.0))
        assertFalse(TruncationGuard.warrantsInspection("anything", null))
    }

    @Test
    fun `the summary shows its arithmetic`() {
        val summary = TruncationGuard.inspect(chars(98), 49.0).summary
        assertTrue(summary.contains("98"))
        assertTrue(summary.contains("2.00"))
        assertTrue(summary.contains("3.50"))
    }
}
