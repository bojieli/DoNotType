package app.donottype.core

/**
 * What happens where Chinese or Japanese text meets Latin letters and digits.
 *
 * A setting rather than a rule because there is no single right answer — the space is conventional
 * in Chinese typography and plenty of people dislike it — but there *is* a wrong answer, which is
 * what the product did before: whatever the model felt like that request. The same sentence
 * dictated twice came back spaced once and tight once.
 */
enum class TypographySpacing(val id: String, val label: String) {
    /**
     * One space at every boundary. What most Chinese style guides ask for, and the default: a rule
     * the user can predict beats a coin flip in either direction.
     */
    SPACED("spaced", "Spaced — one space where Chinese meets Latin"),

    /** No space at any boundary. */
    TIGHT("tight", "Tight — no space where Chinese meets Latin"),

    /**
     * Whatever came back. Not the default, because this is the behaviour that was reported as a
     * bug — but it is the honest escape hatch for anyone this transform gets wrong.
     */
    UNCHANGED("unchanged", "Unchanged — however the model wrote it");

    companion object {
        val DEFAULT = SPACED

        /** The persisted spelling, shared with the other three clients' settings transfer. */
        fun from(id: String?): TypographySpacing =
            entries.firstOrNull { it.id == id?.trim()?.lowercase() } ?: DEFAULT
    }
}

/**
 * Which characters Chinese is written in.
 *
 * Speech does not carry a writing system. Mandarin dictated by someone in Taipei and by someone in
 * Shanghai is the same audio, and the model has to pick — so it picks, differently, sometimes inside
 * one dictation. That was reported as the same complaint as the spacing: not that the answer was
 * wrong, but that it was not the same answer twice.
 *
 * [SPOKEN] is the shipped contract's own rule and the default, so choosing nothing sends nothing
 * extra: `prompt/system.md` already says Simplified unless the speaker asks otherwise, and the
 * measured numbers in `docs/PROMPT.md` describe that request exactly.
 *
 * This is a script choice, never a translation. Wording and language stay governed by the fidelity
 * and language-preservation rules, which the formatting block restates rather than relaxes.
 */
enum class ChineseScript(val id: String, val label: String) {
    SPOKEN("spoken", "Follow the speaker — Simplified unless they ask otherwise"),
    SIMPLIFIED("simplified", "Always Simplified"),
    TRADITIONAL("traditional", "Always Traditional");

    /** Whether this is the shipped contract's own behaviour, and so adds nothing to a request. */
    val isDefault: Boolean get() = this == SPOKEN

    companion object {
        val DEFAULT = SPOKEN

        fun from(id: String?): ChineseScript =
            entries.firstOrNull { it.id == id?.trim()?.lowercase() } ?: DEFAULT
    }
}

/**
 * How a dictation is written down, chosen from a short list or written by the user.
 *
 * Not what it says — that is [Fidelity], which decides how much of the speaker's own noise
 * survives, and neither of them may change a word. This is the shape of the written form: line
 * breaks, punctuation density, whether it reads like a chat message or a paragraph.
 *
 * [SPOKEN] is the default and sends **nothing**. That is load-bearing rather than tidy: every
 * measured number in `docs/PROMPT.md` describes the default request, and a clause added to it
 * unconditionally would invalidate the whole table at once.
 *
 * [CUSTOM] is the other half of the same control, and the reason this is an enum rather than a text
 * box: most people want one of a few answers and should get it in one tap, and the people who want
 * something else should not be limited to the few we thought of. The custom text goes through the
 * same host block as every preset.
 */
enum class DictationStyle(val id: String, val label: String) {
    SPOKEN("spoken", "As spoken — however the model writes it"),
    CHAT("chat", "Chat — short lines, light punctuation"),
    NOTES("notes", "Notes — sentence case, one point per line"),
    PROSE("prose", "Prose — complete sentences and paragraphs"),
    CUSTOM("custom", "Custom — your own description or example");

    /** Whether this style adds anything to the request. False only for [SPOKEN]. */
    val isStyled: Boolean get() = this != SPOKEN

    /**
     * Whether the clause comes from a file in `prompt/dictation-style/`. False for [CUSTOM], whose
     * clause is the user's own text, and for [SPOKEN], which has no clause at all.
     */
    val hasClauseFile: Boolean get() = isStyled && this != CUSTOM

    companion object {
        val DEFAULT = SPOKEN

        fun from(id: String?): DictationStyle =
            entries.firstOrNull { it.id == id?.trim()?.lowercase() } ?: DEFAULT
    }
}

/**
 * Typography applied to a finished transcript, deterministically.
 *
 * This is the half of the formatting problem that does not belong in a prompt. A model asked to
 * space Chinese and Latin consistently does it most of the time, which is the worst available
 * outcome: consistent output and occasional output are told apart only by reading, and the thing
 * being read is the thing the user stopped watching because they were dictating. The rules here
 * are arithmetic over characters, so they hold on every request, for every backend, at no latency
 * and no tokens.
 *
 * **It never changes a word.** Every rule adds or removes horizontal space; nothing here inserts
 * punctuation, converts a character, reorders anything, or deletes anything that is not a space.
 * That boundary is why the feature is split in two: asking the model for full-width commas rather
 * than spaces between clauses *is* a content change — a comma the speaker did not say — so it is
 * asked for in `prompt/typography.md`, where it can be refused, rather than imposed here, where it
 * could not be.
 *
 * Hand-ported from `Sources/DoNotTypeCore/Typography.swift`; the C# port is
 * `windows/DoNotType.Core/Typography.cs`. The three suites assert the same table.
 */
object Typography {

    /**
     * The most of a formatting example that is sent.
     *
     * A cap rather than a validation error, and the settings screen says the number: this is one or
     * two sentences demonstrating spacing and punctuation, and a page of prose pasted into it would
     * be a page of prose on every request.
     */
    const val MAX_SAMPLE_CHARACTERS = 500

    /**
     * The user's formatting example, as it will be sent.
     *
     * Cleaned rather than rejected. The field is free text on purpose — the whole point is to
     * demonstrate a convention this codebase has no name for — so the only things removed are the
     * ones that would break the block it is pasted into: control characters, and more than one blank
     * line in a row.
     */
    fun sanitizedSample(text: String?): String {
        if (text.isNullOrEmpty()) return ""
        var cleaned = text.replace("\r\n", "\n").replace('\r', '\n')
        cleaned = cleaned.filter { it == '\n' || it == '\t' || !isControl(it) }
        while (cleaned.contains("\n\n\n")) cleaned = cleaned.replace("\n\n\n", "\n\n")
        cleaned = cleaned.trim()
        return if (cleaned.length > MAX_SAMPLE_CHARACTERS) {
            cleaned.substring(0, MAX_SAMPLE_CHARACTERS).trim()
        } else {
            cleaned
        }
    }

    private fun isControl(value: Char): Boolean =
        value.code < 0x20 || (value.code in 0x7F..0x9F)

    /**
     * Applies the user's spacing rule and removes space that no convention allows.
     *
     * Idempotent: normalising twice is normalising once, which matters because a split recording is
     * normalised per chunk and again after stitching.
     */
    fun normalize(text: String, spacing: TypographySpacing): String {
        if (spacing == TypographySpacing.UNCHANGED || text.isEmpty()) return text

        val output = StringBuilder(text.length + 8)
        // The last code point written, which is what a boundary is measured against.
        var previous = -1
        var index = 0

        while (index < text.length) {
            val width = codePointWidth(text, index)
            val current = text.codePointAt(index)

            if (!isHorizontalSpace(current)) {
                // A boundary the model wrote without a space. Only SPACED has anything to add;
                // TIGHT has nothing to do until it meets a space.
                if (spacing == TypographySpacing.SPACED && isScriptBoundary(previous, current)) {
                    output.append(' ')
                }
                output.append(text, index, index + width)
                previous = current
                index += width
                continue
            }

            // The whole run at once, so two spaces at a boundary collapse to the one the rule asks
            // for rather than to two.
            var end = index
            while (end < text.length && isHorizontalSpace(text.codePointAt(end))) {
                end += codePointWidth(text, end)
            }
            val next = if (end < text.length) text.codePointAt(end) else -1

            if (previous < 0 || next < 0) {
                // Leading and trailing space is layout the speaker or the caller owns — an indent,
                // or the join between two stitched chunks — and is left exactly as it arrived.
                output.append(text, index, end)
                previous = ' '.code
                index = end
                continue
            }

            if (isFullWidthPunctuation(previous) || isFullWidthPunctuation(next)) {
                // Not a preference. A full-width mark carries its own space inside the glyph, so no
                // convention in any of these scripts puts another one beside it — which is why this
                // runs under both settings. The reported symptom was an extra space after a full
                // stop, arriving on some sentences and not others.
                index = end
                continue
            }

            if (isScriptBoundary(previous, next)) {
                if (spacing == TypographySpacing.SPACED) {
                    output.append(' ')
                    previous = ' '.code
                }
                index = end
                continue
            }

            output.append(text, index, end)
            previous = ' '.code
            index = end
        }

        return output.toString()
    }

    private fun codePointWidth(text: String, index: Int): Int =
        if (Character.isHighSurrogate(text[index]) &&
            index + 1 < text.length &&
            Character.isLowSurrogate(text[index + 1])
        ) {
            2
        } else {
            1
        }

    /**
     * Space that is typography. A newline is not, and neither is anything else that carries
     * structure: this transform must be unable to join two lines together.
     */
    private fun isHorizontalSpace(value: Int): Boolean =
        value == ' '.code || value == '\t'.code

    /**
     * Han ideographs and Japanese kana.
     *
     * Hangul is deliberately absent. Korean already separates its words with spaces, so TIGHT would
     * take out a space the language requires — a setting about Chinese and Latin has no business
     * editing Korean. Kana is included so Japanese is treated consistently within itself: excluding
     * it would space `Web開発` and not `Webかいはつ`, which is the inconsistency this whole object
     * exists to remove.
     */
    internal fun isCJK(value: Int): Boolean = when (value) {
        in 0x3400..0x4DBF -> true      // CJK Unified Ideographs Extension A
        in 0x4E00..0x9FFF -> true      // CJK Unified Ideographs
        in 0xF900..0xFAFF -> true      // CJK Compatibility Ideographs
        in 0x20000..0x2A6DF -> true    // Extension B
        in 0x2A700..0x2EBEF -> true    // Extensions C through F
        in 0x2F800..0x2FA1F -> true    // Compatibility Ideographs Supplement
        // The one exception in the kana block: ・ is punctuation, and spacing around it would turn
        // A・B into A ・ B.
        in 0x3041..0x30FF -> value != 0x30FB
        in 0x31F0..0x31FF -> true      // Katakana phonetic extensions
        else -> false
    }

    /**
     * The Latin side of a boundary: letters and digits only.
     *
     * Symbols are deliberately excluded, which makes `50%的人` come back unchanged rather than as
     * `50% 的人`. Conservative on purpose — a rule that fires on punctuation has far more ways to be
     * wrong, and nobody reported symbols.
     */
    internal fun isLatinAlphanumeric(value: Int): Boolean {
        // × and ÷ sit inside the Latin-1 letter range and are neither.
        if (value == 0x00D7 || value == 0x00F7) return false
        return when (value) {
            in '0'.code..'9'.code -> true
            in 'A'.code..'Z'.code -> true
            in 'a'.code..'z'.code -> true
            in 0x00C0..0x024F -> true  // Latin-1 Supplement, Latin Extended-A and B
            else -> false
        }
    }

    /**
     * Marks that already contain their own space. Latin quotation marks are excluded: `"` and `'`
     * are used in English exactly as often, and stripping the space beside one would be editing
     * English prose on behalf of a Chinese setting.
     */
    internal fun isFullWidthPunctuation(value: Int): Boolean = when (value) {
        // 、。〈〉《》「」『』【】〔〕… — and the rest of CJK punctuation
        in 0x3001..0x303F -> true
        0x30FB -> true                 // ・
        in 0xFF01..0xFF0F -> true      // ！＂＃＄％＆＇（）＊＋，－．／
        in 0xFF1A..0xFF20 -> true      // ：；＜＝＞？＠
        in 0xFF3B..0xFF40 -> true      // ［＼］＾＿｀
        in 0xFF5B..0xFF65 -> true      // ｛｜｝～｟｠｡｢｣､･
        else -> false
    }

    private fun isScriptBoundary(left: Int, right: Int): Boolean =
        (isCJK(left) && isLatinAlphanumeric(right)) ||
            (isLatinAlphanumeric(left) && isCJK(right))
}
