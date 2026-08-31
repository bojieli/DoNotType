package app.donottype.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The example presets and the rule that migrates a pre-example install onto them, asserted in the
 * same shape in `Tests/DoNotTypeCoreTests/TypographyTests.swift` and
 * `windows/DoNotType.Core.Tests/CoreTests.cs`.
 *
 * The assembled instruction itself is checked on the other two platforms, which can read `prompt/`
 * from disk in a unit test. Reaching the parts here needs a `Context` and an APK, so that half is
 * covered by the instrumentation suite instead — which is why the migration is exercised with a
 * stub resolver rather than the real files.
 */
class DictationPresetTest {

    /** The spelling is the file name under `prompt/dictation-style/`, and a transfer field. */
    @Test
    fun `spellings round trip and unknown values resolve to nothing`() {
        for (preset in DictationPreset.entries) {
            assertEquals(preset, DictationPreset.from(preset.id))
        }
        assertEquals(DictationPreset.CHAT, DictationPreset.from(" CHAT "))
        // Null rather than a default: an unknown name has no text to fill the box with, and a
        // default would quietly put Chat's words in somebody's request.
        assertNull(DictationPreset.from("nonsense"))
        assertNull(DictationPreset.from(null))
        assertNull(DictationPreset.from("spoken"))
        assertNull(DictationPreset.from("custom"))
    }

    /**
     * A name and a shape, never a mood. The old labels promised a register — "Chat — short lines,
     * light punctuation" — and delivered a layout rule, which is the confusion this control was
     * rebuilt to remove.
     */
    @Test
    fun `a preset is named, and says what shape it makes`() {
        for (preset in DictationPreset.entries) {
            assertTrue(preset.label.isNotEmpty())
            assertTrue(preset.label, !preset.label.contains("—"))
            assertTrue(preset.shape.isNotEmpty())
        }
        assertEquals("Chat", DictationPreset.CHAT.label)
        assertEquals("Short lines, one thought each", DictationPreset.CHAT.shape)
    }

    /**
     * Upgrading must not change anybody's request — only make it visible. Somebody on Chat had
     * `chat.md`'s words in every dictation, and afterwards has those same words in their box.
     */
    @Test
    fun `migration preserves the request it replaces`() {
        val stub: (DictationPreset) -> String? = { "text for ${it.id}" }

        for (preset in DictationPreset.entries) {
            assertEquals(
                "text for ${preset.id}",
                DictationExample.migrating(preset.id, "", stub),
            )
        }

        // "spoken", absent, and a name from a future build all mean an empty box, which sends
        // nothing — the behaviour SPOKEN had, and the safe answer for text this build cannot
        // resolve.
        for (legacy in listOf("spoken", "", "sonnet-style")) {
            assertEquals("", DictationExample.migrating(legacy, "", stub))
        }
        assertEquals("", DictationExample.migrating(null, null, stub))

        // A preset this build knows whose file it cannot read is *not knowable yet*, and must not
        // be confused with "no style" — a caller that did would clear the retired setting and
        // destroy the only record of what the user chose, over an unreadable asset.
        assertNull(DictationExample.migrating("chat", "", { null }))

        // Custom carried the user's own text and still does, sanitiser and cap included.
        assertEquals(
            "中文 English。",
            DictationExample.migrating("custom", " 中文 English。 ", stub),
        )
    }


    /**
     * A fresh install starts on Prose, and somebody who pressed Clear stays cleared.
     *
     * The two are the same empty string in every store on every platform, so the rule is written
     * against *absence* rather than emptiness. Getting it backwards would put the default back into
     * a box that had just been deliberately emptied, on every launch, forever.
     */
    @Test
    fun `seeding fills a fresh install and leaves a cleared box alone`() {
        val stub: (DictationPreset) -> String? = { "text for ${it.id}" }

        assertEquals(DictationPreset.PROSE, DictationExample.DEFAULT_PRESET)
        assertEquals(DictationPreset.PROSE, DictationPreset.entries.first())
        assertEquals("text for prose", DictationExample.seeding(null, stub))

        assertNull(DictationExample.seeding("", stub))
        assertNull(DictationExample.seeding("whatever", stub))
        assertNull(DictationExample.seeding(null) { null })
    }

    /** The rewrite side kept its enum: it is a stage, not a layout, and still has three shipped clauses. */
    @Test
    fun `the rewrite styles are unchanged`() {
        assertTrue(RewriteStyle.FORMAL.hasClauseFile)
        assertTrue(RewriteStyle.CUSTOM.isRewrite)
        assertEquals(false, RewriteStyle.CUSTOM.hasClauseFile)
        assertEquals(false, RewriteStyle.VERBATIM.hasClauseFile)
        assertEquals(RewriteStyle.CUSTOM, RewriteStyle.from("custom"))
        assertNull(RewriteStyle.from("nonsense"))
    }
}
