package app.donottype.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The dictation style enum, whose spellings and file-backing rules are asserted in the same shape
 * in `Tests/DoNotTypeCoreTests/TypographyTests.swift` and
 * `windows/DoNotType.Core.Tests/CoreTests.cs`.
 *
 * The assembled instruction itself is checked on the other two platforms, which can read `prompt/`
 * from disk in a unit test. Reaching the parts here needs a `Context` and an APK, so that half is
 * covered by the instrumentation suite instead.
 */
class DictationStyleTest {

    /** The persisted spelling is shared with the other three clients' settings transfer. */
    @Test
    fun `spellings round trip and unknown values fall back`() {
        for (style in DictationStyle.entries) {
            assertEquals(style, DictationStyle.from(style.id))
        }
        assertEquals(DictationStyle.DEFAULT, DictationStyle.from("nonsense"))
        assertEquals(DictationStyle.DEFAULT, DictationStyle.from(null))
        assertEquals(DictationStyle.CHAT, DictationStyle.from(" CHAT "))
    }

    /**
     * Two styles have no file: one sends nothing at all, and the other's clause is the user's own
     * text. Everything else must resolve to a shipped clause, or the prompt directory is missing a
     * file that a settings screen offers.
     */
    @Test
    fun `only the presets are backed by a file`() {
        assertTrue(DictationStyle.CHAT.hasClauseFile)
        assertTrue(DictationStyle.NOTES.hasClauseFile)
        assertTrue(DictationStyle.PROSE.hasClauseFile)
        assertEquals(false, DictationStyle.SPOKEN.hasClauseFile)
        assertEquals(false, DictationStyle.CUSTOM.hasClauseFile)
        assertEquals(false, DictationStyle.SPOKEN.isStyled)
        assertTrue(DictationStyle.CUSTOM.isStyled)
    }

    /** The same shape on the rewrite side, where `custom` joins three shipped styles. */
    @Test
    fun `the rewrite styles split the same way`() {
        assertTrue(RewriteStyle.FORMAL.hasClauseFile)
        assertTrue(RewriteStyle.CUSTOM.isRewrite)
        assertEquals(false, RewriteStyle.CUSTOM.hasClauseFile)
        assertEquals(false, RewriteStyle.VERBATIM.hasClauseFile)
        assertEquals(RewriteStyle.CUSTOM, RewriteStyle.from("custom"))
        assertNull(RewriteStyle.from("nonsense"))
    }
}
