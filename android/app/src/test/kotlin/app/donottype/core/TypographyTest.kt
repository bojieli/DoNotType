package app.donottype.core

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The typography table, repeated verbatim in `Tests/DoNotTypeCoreTests/TypographyTests.swift` and
 * `windows/DoNotType.Core.Tests/TypographyTests.cs`.
 *
 * Repeated rather than shared through a fixture file, like the mode grammar: a fixture is read by
 * whichever platform remembers to read it, and a transcript that is spaced on a laptop and tight on
 * a phone is exactly the inconsistency this object was added to remove.
 */
class TypographyTest {

    private data class Row(val input: String, val spaced: String, val tight: String)

    private val table = listOf(
        // The boundary, in both directions and with the space already there or not.
        Row("中文English", "中文 English", "中文English"),
        Row("中文 English", "中文 English", "中文English"),
        Row("中文  English", "中文 English", "中文English"),
        Row("English中文", "English 中文", "English中文"),
        Row("English 中文", "English 中文", "English中文"),
        // Digits count as the Latin side. This is the convention, and it is also what makes
        // "gemini-3.5-flash" read the same way in Chinese prose as in English.
        Row("在2026年", "在 2026 年", "在2026年"),
        Row("使用GPT-4模型", "使用 GPT-4 模型", "使用GPT-4模型"),
        // The reported bug: a stray space after a full-width stop, on some sentences and not
        // others. No convention allows it, so both settings remove it.
        Row("你好。 世界", "你好。世界", "你好。世界"),
        Row("你好 ，世界", "你好，世界", "你好，世界"),
        Row("完成了。 Then I said hi.", "完成了。Then I said hi.", "完成了。Then I said hi."),
        Row("《书名》 abc", "《书名》abc", "《书名》abc"),
        // English is not touched at all, whichever setting is in force.
        Row("Hello world.", "Hello world.", "Hello world."),
        Row("Two  spaces stay.", "Two  spaces stay.", "Two  spaces stay."),
        // A space between two Han characters is left alone. Removing it would join words the
        // speaker meant to keep apart, and this transform is never allowed to change wording — the
        // model is asked for proper punctuation there instead, in prompt/typography.md.
        Row("这是 一个 句子", "这是 一个 句子", "这是 一个 句子"),
        // Structure survives: a newline is not horizontal space, and an indent is the caller's.
        Row("第一行\n第二行abc", "第一行\n第二行 abc", "第一行\n第二行abc"),
        Row("  缩进", "  缩进", "  缩进"),
        Row("中文 ", "中文 ", "中文 "),
        // Symbols are not the Latin side, deliberately: a rule that fires on punctuation has far
        // more ways to be wrong.
        Row("50%的人", "50%的人", "50%的人"),
        // Korean separates its own words. TIGHT must not take that space away.
        Row("Web 개발", "Web 개발", "Web 개발"),
        // Kana is treated like Han, so Japanese is consistent within itself.
        Row("Webかいはつ", "Web かいはつ", "Webかいはつ"),
        Row("A・B", "A・B", "A・B"),
        Row("", "", ""),
    )

    @Test
    fun theTableHolds() {
        for (row in table) {
            assertEquals(
                "spaced: ${row.input}",
                row.spaced,
                Typography.normalize(row.input, TypographySpacing.SPACED),
            )
            assertEquals(
                "tight: ${row.input}",
                row.tight,
                Typography.normalize(row.input, TypographySpacing.TIGHT),
            )
        }
    }

    /** The escape hatch has to be exactly that: not a milder rule, no rule at all. */
    @Test
    fun unchangedTouchesNothing() {
        for (row in table) {
            assertEquals(
                row.input,
                Typography.normalize(row.input, TypographySpacing.UNCHANGED),
            )
        }
    }

    /**
     * A split recording is normalised per chunk and again over the stitch, so this is load bearing
     * rather than a nicety.
     */
    @Test
    fun normalisingTwiceIsNormalisingOnce() {
        for (row in table) {
            for (spacing in TypographySpacing.entries) {
                val once = Typography.normalize(row.input, spacing)
                assertEquals(row.input, once, Typography.normalize(once, spacing))
            }
        }
    }

    /**
     * The invariant that makes this safe to run on every transcript: it is a space transform.
     * Anything else here would be editing what the user said.
     */
    @Test
    fun onlySpacingEverChanges() {
        for (row in table) {
            val expected = row.input.filterNot { it.isWhitespace() }
            for (spacing in TypographySpacing.entries) {
                assertEquals(
                    "${spacing.id}: ${row.input}",
                    expected,
                    Typography.normalize(row.input, spacing).filterNot { it.isWhitespace() },
                )
            }
        }
    }

    @Test
    fun theDefaultIsAStableRuleRatherThanTheModelsJudgement() {
        assertEquals(TypographySpacing.SPACED, TypographySpacing.DEFAULT)
    }

    /** The persisted spelling is shared with the other three clients; an unknown one is the default. */
    @Test
    fun spellingsRoundTripAndUnknownValuesFallBack() {
        for (spacing in TypographySpacing.entries) {
            assertEquals(spacing, TypographySpacing.from(spacing.id))
        }
        assertEquals(TypographySpacing.DEFAULT, TypographySpacing.from("nonsense"))
        assertEquals(TypographySpacing.DEFAULT, TypographySpacing.from(null))
        assertEquals(TypographySpacing.TIGHT, TypographySpacing.from(" TIGHT "))
    }
}
