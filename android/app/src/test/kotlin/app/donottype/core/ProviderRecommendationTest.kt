package app.donottype.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * What the settings picker advises, and the invariants that keep the advice honest.
 *
 * The same recommendation is hand-written four times — Swift for macOS and iOS, C# for Windows,
 * this one for Android — and the failure mode of that arrangement is one client quietly advising
 * something the others do not. Matching tests exist in the other two languages, for the same
 * reason [FailureAdviceTest] does.
 */
class ProviderRecommendationTest {

    /** Two, and these two. The list is the product decision; everything below is a consequence. */
    @Test
    fun `the recommended set is the two ends of one axis`() {
        assertEquals(listOf(ProviderKind.GEMINI, ProviderKind.XAI), ProviderKind.RECOMMENDED)
        // The axis itself: one reads the screen, the other cannot. Two recommendations that
        // differed on nothing would be a coin toss dressed as advice.
        assertFalse(ProviderKind.GEMINI.isSpeechRecognition)
        assertTrue(ProviderKind.XAI.isSpeechRecognition)
    }

    /** A picker that recommends everything recommends nothing. */
    @Test
    fun `only the recommended two carry a note`() {
        for (kind in ProviderKind.entries) {
            assertEquals(
                "${kind.id} disagrees about whether it is recommended",
                kind.isRecommended,
                kind.recommendationNote.isNotEmpty(),
            )
        }
    }

    /**
     * Order is the recommendation that survives a Spinner showing three rows at a time, and the
     * settings screen indexes into this list, so a gap or a duplicate would save the wrong backend.
     */
    @Test
    fun `every backend is offered once and the recommended ones come first`() {
        assertEquals(ProviderKind.entries.toSet(), ProviderKind.PICKER_ORDER.toSet())
        assertEquals(ProviderKind.entries.size, ProviderKind.PICKER_ORDER.size)
        assertEquals(ProviderKind.RECOMMENDED, ProviderKind.PICKER_ORDER.take(2))
    }

    /**
     * The default a fresh install gets has to be one we tell people to pick, or the settings
     * screen is arguing with the installer.
     */
    @Test
    fun `the default for new installs is recommended`() {
        assertTrue(ProviderKind.DEFAULT.isRecommended)
        assertEquals("gemini-3.5-flash", ProviderKind.DEFAULT.defaultModel)
        assertEquals("google/gemini-3.5-flash", ProviderKind.OPENROUTER.defaultModel)
    }

    /**
     * Advice belongs on the row of a picker. The name used for the key hint and for records says
     * what ran.
     */
    @Test
    fun `advice stays out of the name used for records`() {
        for (kind in ProviderKind.entries) {
            assertFalse(kind.displayName.contains("recommended"))
            assertTrue(kind.pickerLabel.startsWith(kind.displayName))
        }
        assertEquals("Gemini — recommended", ProviderKind.GEMINI.pickerLabel)
        assertEquals("Deepgram (transcription only)", ProviderKind.DEEPGRAM.pickerLabel)
    }

    /**
     * The claim each one is recommended for, in the words the other clients use. A number that
     * moves in docs/EVALUATION.md has to move in four places, and this is the one that says so.
     */
    @Test
    fun `the notes make the measured claim and not a vaguer one`() {
        assertTrue(ProviderKind.GEMINI.recommendationNote.contains("reads the screen"))
        assertTrue(ProviderKind.GEMINI.recommendationNote.contains("seven recent jargon-heavy recordings"))
        assertTrue(ProviderKind.GEMINI.recommendationNote.contains("no human goldens"))
        assertTrue(ProviderKind.XAI.recommendationNote.contains("cannot see the screen"))
        assertTrue(ProviderKind.XAI.recommendationNote.contains("15 of 48"))
    }
}
