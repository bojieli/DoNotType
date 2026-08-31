package app.donottype.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The keyboard's mode picker, asserted in the same shape as
 * `Tests/DoNotTypeCoreTests/LiveModeTests.swift` and `windows/DoNotType.Core.Tests/CoreTests.cs`.
 *
 * The table is duplicated rather than shared on purpose: a fixture read from disk would be read by
 * whichever platform remembered to read it, and this is the file that says a phone and a laptop are
 * the same product — see `docs/PARITY.md`.
 */
class LiveModeTest {

    /** The persisted spelling is what the settings transfer carries between the two phones. */
    @Test
    fun `the spellings are stable and unknown values fall back`() {
        assertEquals(listOf("dictate", "rewrite", "translate"), LiveMode.entries.map { it.id })
        for (mode in LiveMode.entries) assertEquals(mode, LiveMode.from(mode.id))
        assertEquals(LiveMode.DEFAULT, LiveMode.from("nonsense"))
        assertEquals(LiveMode.DEFAULT, LiveMode.from(null))
        assertEquals(LiveMode.DICTATE, LiveMode.DEFAULT)
    }

    /** Dictation is the product; a picker that starts anywhere else changes a fresh install. */
    @Test
    fun `the default is a plain dictation whatever else is configured`() {
        assertEquals(
            TranscriptMode.Verbatim,
            LiveMode.DEFAULT.stage(RewriteStyle.FORMAL, "French"),
        )
    }

    @Test
    fun `each mode asks for its own stage`() {
        assertEquals(TranscriptMode.Verbatim, LiveMode.DICTATE.stage(RewriteStyle.FORMAL, "French"))
        assertEquals(
            TranscriptMode.Rewrite(RewriteStyle.FORMAL),
            LiveMode.REWRITE.stage(RewriteStyle.FORMAL, "French"),
        )
        assertEquals(
            TranscriptMode.Translate("French"),
            LiveMode.TRANSLATE.stage(RewriteStyle.FORMAL, "French"),
        )
    }

    /**
     * The exclusivity the picker exists to make visible. A target language used to override the
     * rewrite toggle from Settings, so the chip said Rewrite over a request that translated.
     */
    @Test
    fun `translate and rewrite cannot happen at once`() {
        for (mode in LiveMode.entries) {
            val stage = mode.stage(RewriteStyle.FORMAL, "French")
            assertFalse(
                "$mode asked for two second stages",
                stage is TranscriptMode.Rewrite && stage is TranscriptMode.Translate,
            )
        }
    }

    /** A stale mode with nothing configured is a dictation, not an unspecified second request. */
    @Test
    fun `an unconfigured mode falls back to the transcript`() {
        assertEquals(TranscriptMode.Verbatim, LiveMode.TRANSLATE.stage(RewriteStyle.FORMAL, ""))
        assertEquals(TranscriptMode.Verbatim, LiveMode.TRANSLATE.stage(RewriteStyle.FORMAL, "   "))
        assertEquals(
            TranscriptMode.Verbatim,
            LiveMode.REWRITE.stage(RewriteStyle.VERBATIM, "French"),
        )
    }

    /** Dictation has no second stage, so there is nothing here that can be missing. */
    @Test
    fun `a plain dictation is always available`() {
        assertTrue(
            LiveMode.DICTATE.availability(ProviderKind.GEMINI, "") { false }.isAvailable,
        )
        assertNull(LiveMode.DICTATE.availability(ProviderKind.GEMINI, "") { false }.reason)
    }

    /** The two backend-shaped answers come back worded for the job that was chosen. */
    @Test
    fun `the reason names the job the user asked for`() {
        val unkeyed: (ProviderKind) -> Boolean = { false }
        assertEquals(
            "Add an API key first — without one nothing can run, rewriting included.",
            LiveMode.REWRITE.availability(ProviderKind.GEMINI, "", unkeyed).reason,
        )
        assertEquals(
            "Add an API key first — without one nothing can run, translating included.",
            LiveMode.TRANSLATE.availability(ProviderKind.GEMINI, "French", unkeyed).reason,
        )
        assertEquals(
            "Deepgram only transcribes audio and cannot rewrite text. Add a key for a backend " +
                "that can, and rewriting will use it.",
            RewriteAvailability.BackendCannotRewrite(
                ProviderKind.DEEPGRAM,
                SecondStageJob.REWRITING,
            ).reason,
        )
        assertEquals(
            "Deepgram only transcribes audio and cannot translate text. Add a key for a backend " +
                "that can, and translating will use it.",
            RewriteAvailability.BackendCannotRewrite(
                ProviderKind.DEEPGRAM,
                SecondStageJob.TRANSLATING,
            ).reason,
        )
    }

    /**
     * Translate with nothing to translate into: the one state the old two-way toggle could not
     * represent, because it was a target language silently overriding whatever the chip said.
     */
    @Test
    fun `translate without a language is unavailable for that reason alone`() {
        val keyed: (ProviderKind) -> Boolean = { true }
        assertEquals(
            RewriteAvailability.NoTargetLanguage,
            LiveMode.TRANSLATE.availability(ProviderKind.GEMINI, "  ", keyed),
        )
        assertEquals(
            "Set a target language in Settings first, and Translate will write in it.",
            RewriteAvailability.NoTargetLanguage.reason,
        )
        assertTrue(
            LiveMode.TRANSLATE.availability(ProviderKind.GEMINI, "French", keyed).isAvailable,
        )
    }

    /** 68dp on Android, 86pt on iOS. Both bars are laid out for these three words. */
    @Test
    fun `the labels are short enough for the chip`() {
        for (mode in LiveMode.entries) {
            assertTrue(mode.label.isNotEmpty())
            assertTrue(mode.label, mode.label.length <= 9)
        }
    }
}
