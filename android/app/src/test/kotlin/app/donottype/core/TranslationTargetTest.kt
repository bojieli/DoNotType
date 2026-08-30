package app.donottype.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The target-language field, whose rules are repeated in
 * `Tests/DoNotTypeCoreTests/TranscriptModeTests.swift` and
 * `windows/DoNotType.Core.Tests/TranscriptModeTests.cs`.
 */
class TranslationTargetTest {

    @Test
    fun `the sanitiser is identical on every platform`() {
        val table = listOf(
            "English" to "English",
            "  English  " to "English",
            "Traditional  Chinese" to "Traditional Chinese",
            "Brazilian\nPortuguese" to "Brazilian Portuguese",
            "a\tb" to "a b",
            "" to "",
            "   " to "",
        )
        table.forEach { (typed, expected) ->
            assertEquals(typed, expected, TranslationTarget.sanitized(typed))
        }
        assertEquals(
            TranslationTarget.MAX_CHARACTERS,
            TranslationTarget.sanitized("x".repeat(200)).length,
        )
    }

    /**
     * Empty is off rather than invalid, which is the difference between a field you can clear and
     * one that shouts at you for clearing it.
     */
    @Test
    fun `an empty field is not an error`() {
        assertNull(TranslationTarget.validationMessage(""))
        assertNull(TranslationTarget.validationMessage("   "))
        assertNull(TranslationTarget.validationMessage(null))
        assertNull(TranslationTarget.validationMessage("简体中文"))
        assertEquals(
            "A language name is at most 60 characters.",
            TranslationTarget.validationMessage("x".repeat(200)),
        )
    }

    /**
     * Not a whitelist, and the suite says so: a language that is not in the list must still be
     * accepted, because the model is the authority on what it can write.
     */
    @Test
    fun `the suggestions are not a whitelist`() {
        assertNull(TranslationTarget.validationMessage("Klingon"))
        assertEquals("translate:Klingon", TranscriptMode.from("translate:Klingon")?.id)
        assertTrue(TranslationTarget.SUGGESTIONS.contains("English"))
    }
}
