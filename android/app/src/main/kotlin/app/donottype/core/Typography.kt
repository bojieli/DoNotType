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
 * A named starting point for the dictation example — a button, never a stored setting.
 *
 * This used to be `DictationStyle`, a five-case enum the user picked from and the app persisted.
 * That shape is what made the control unusable: the label had to compress a whole instruction into
 * a dash-clause, so `Chat — short lines, light punctuation` read as a mood and behaved as a rule,
 * and somebody who wanted the mood got line breaks they never asked for and could not trace. The
 * instruction was three files away from the only place it was described.
 *
 * The instruction is the control now. A preset drops its text into the example box, where it can be
 * read and edited before it is used, and what the user ends up with is a string rather than a case.
 * Presets can therefore be added, renamed and reworded without migrating anybody.
 *
 * The absence of a style is the empty string, which sends nothing — the same default the retired
 * `SPOKEN` had, and still what keeps every measured number in `docs/PROMPT.md` describing the
 * request a fresh install actually makes.
 *
 * @property label the button's text. A name and nothing else: what it means is the text it drops in
 *   the box, which is on screen the moment it is pressed.
 * @property shape one line beside the button, for the gap between pressing and reading. Deliberately
 *   about *shape*, never about feel — the old labels promised a register and delivered a layout
 *   rule.
 */
enum class DictationPreset(val id: String, val label: String, val shape: String) {
    /** First, and what a new install starts with. See [DictationExample.seeding]. */
    PROSE("prose", "Prose", "Full sentences, paragraphs"),
    CHAT("chat", "Chat", "Short lines, one thought each"),
    NOTES("notes", "Notes", "One point per line");

    companion object {
        /** Null rather than a default: an unknown name has no text to fill the box with. */
        fun from(id: String?): DictationPreset? =
            entries.firstOrNull { it.id == id?.trim()?.lowercase() }
    }
}

/**
 * How an older install's dictation-style setting becomes an example.
 *
 * One named rule rather than the same three-branch conditional in four clients and two importers,
 * hand-ported from the Swift. It is a rule and not a default because the whole point of the
 * migration is that nobody's dictations change on upgrade: somebody who chose Chat had `chat.md`'s
 * words in their request, so afterwards they have those same words in their box, byte for byte, and
 * can now see and edit them.
 */
object DictationExample {
    /**
     * What a brand-new install starts with.
     *
     * Empty used to be the default, and it had one real virtue: the shipped request was the one
     * every measured number in `docs/PROMPT.md` described. It also meant a fresh install's
     * transcripts were laid out however the model felt like that day, which is the complaint the
     * whole formatting series started from — a default of "no answer" is still an answer, and it was
     * the least predictable one available.
     */
    val DEFAULT_PRESET = DictationPreset.PROSE

    /**
     * The example a fresh install starts with, or null when there is nothing to do.
     *
     * @param stored the persisted value, or null when the key has never been written. The
     *   distinction is the whole function: an empty string is somebody who pressed Clear and meant
     *   it, and seeding over that would put words back they had just removed.
     */
    fun seeding(stored: String?, presetText: (DictationPreset) -> String?): String? {
        if (stored != null) return null
        val text = presetText(DEFAULT_PRESET) ?: return null
        return Typography.sanitizedSample(text)
    }

    /**
     * @return the text for the box, or **null** when the answer is not knowable yet — a preset this
     *   build recognises whose file could not be read. Null is not "no style": a caller that
     *   treated it as one would clear the retired keys and destroy the only record of what the user
     *   had chosen, over something as temporary as an unreadable asset. Keep them and try again.
     */
    fun migrating(
        legacyStyle: String?,
        legacyCustom: String?,
        presetText: (DictationPreset) -> String?,
    ): String? {
        val name = legacyStyle?.trim()?.lowercase().orEmpty()
        if (name == "custom") return Typography.sanitizedSample(legacyCustom.orEmpty())
        val preset = DictationPreset.from(name)
        if (preset != null) {
            val text = presetText(preset) ?: return null
            return Typography.sanitizedSample(text)
        }
        // "spoken", absent, or a value this build does not know. All three mean the box is empty,
        // which sends nothing — the behaviour SPOKEN had, and the safe answer for a name this build
        // could not resolve even with the files in front of it.
        return ""
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

/**
 * The shape of a settings preview, and the words it is presented with.
 *
 * Hand-ported from `Sources/DoNotTypeCore/StylePreview.swift`, because the four clients have to
 * describe the same thing the same way — somebody comparing a laptop to a phone is comparing the
 * same product — and because *which baseline to use* is a rule rather than a preference.
 *
 * The preview exists because every control in a settings panel is a *cause* and what a user needs is
 * the *effect*. The label that read `Chat — short lines, light punctuation` was describing its
 * effect accurately while being read as a mood.
 */
object StylePreview {
    /** Where the left-hand pane's text comes from. */
    enum class Baseline(val label: String) {
        /** A dictation already in History: a real past result, free, and the most honest "before". */
        STORED("What you got"),

        /**
         * A clip just recorded, which has no past. The baseline is the same audio sent with the
         * example box emptied — the one comparison that answers "what is my example doing".
         */
        WITHOUT_EXAMPLE("Without your example"),

        /** A clip recorded while the box is empty. The second request would be the first again. */
        NONE("Your transcript"),
    }

    const val STYLED_LABEL = "With these settings"

    /**
     * How many model requests a preview of a freshly recorded clip will cost.
     *
     * Stated as a function rather than assumed at each call site, because the answer is the
     * difference between one request and two and the user is told which before pressing.
     */
    fun baselineForClip(example: String): Baseline =
        if (Typography.sanitizedSample(example).isEmpty()) Baseline.NONE else Baseline.WITHOUT_EXAMPLE

    /** What the button says it will cost. A preview is a real request, so it says so. */
    fun costNote(baseline: Baseline): String = when (baseline) {
        Baseline.STORED ->
            "Sends your most recent recording again with the settings above, and shows both " +
                "answers. One request."
        Baseline.WITHOUT_EXAMPLE ->
            "Records a clip, then transcribes it twice — once with your example and once without — " +
                "so you can see what the example is doing. Two requests."
        Baseline.NONE ->
            "Records a clip and transcribes it with the settings above. One request."
    }

    /** Said where a preview cannot run at all, rather than leaving a control disabled in silence. */
    const val NO_STORED_RECORDING =
        "No kept recording to try this on. Record a clip instead, or turn on Keep audio and make a " +
            "dictation."
}
