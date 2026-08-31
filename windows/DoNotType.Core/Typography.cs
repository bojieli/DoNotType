using System.Text;

namespace DoNotType.Core;

/// <summary>
/// What happens where Chinese or Japanese text meets Latin letters and digits.
/// </summary>
/// <remarks>
/// A setting rather than a rule because there is no single right answer — the space is
/// conventional in Chinese typography and plenty of people dislike it — but there <em>is</em> a
/// wrong answer, which is what the product did before: whatever the model felt like that request.
/// The same sentence dictated twice came back spaced once and tight once.
/// </remarks>
public enum TypographySpacing
{
    /// <summary>
    /// One space at every boundary. What most Chinese style guides ask for, and the default: a
    /// rule the user can predict beats a coin flip in either direction.
    /// </summary>
    Spaced,

    /// <summary>No space at any boundary.</summary>
    Tight,

    /// <summary>
    /// Whatever came back. Not the default, because this is the behaviour that was reported as a
    /// bug — but it is the honest escape hatch for anyone this transform gets wrong.
    /// </summary>
    Unchanged,
}

/// <summary>
/// Typography applied to a finished transcript, deterministically.
/// </summary>
/// <remarks>
/// <para>
/// This is the half of the formatting problem that does not belong in a prompt. A model asked to
/// space Chinese and Latin consistently does it most of the time, which is the worst available
/// outcome: consistent output and occasional output are told apart only by reading, and the thing
/// being read is the thing the user stopped watching because they were dictating. The rules here
/// are arithmetic over characters, so they hold on every request, for every backend, at no latency
/// and no tokens.
/// </para>
/// <para>
/// <b>It never changes a word.</b> Every rule adds or removes horizontal space; nothing here
/// inserts punctuation, converts a character, reorders anything, or deletes anything that is not a
/// space. That boundary is why the feature is split in two: asking the model for full-width commas
/// rather than spaces between clauses <em>is</em> a content change — a comma the speaker did not
/// say — so it is asked for in <c>prompt/typography.md</c>, where it can be refused, rather than
/// imposed here, where it could not be.
/// </para>
/// <para>
/// Hand-ported from <c>Sources/DoNotTypeCore/Typography.swift</c>; the Kotlin port is
/// <c>android/app/src/main/kotlin/app/donottype/core/Typography.kt</c>. The three suites assert
/// the same table.
/// </para>
/// </remarks>
public static class Typography
{
    public const TypographySpacing DefaultSpacing = TypographySpacing.Spaced;

    /// <summary>The most of a formatting example that is sent.</summary>
    /// <remarks>
    /// A cap rather than a validation error, and the settings screen says the number: this is one
    /// or two sentences demonstrating spacing and punctuation, and a page of prose pasted into it
    /// would be a page of prose on every request.
    /// </remarks>
    public const int MaxSampleCharacters = 500;

    public static string Spelling(TypographySpacing spacing) => spacing switch
    {
        TypographySpacing.Tight => "tight",
        TypographySpacing.Unchanged => "unchanged",
        _ => "spaced",
    };

    public static TypographySpacing ParseSpacing(string? id) => id?.Trim().ToLowerInvariant() switch
    {
        "tight" => TypographySpacing.Tight,
        "unchanged" => TypographySpacing.Unchanged,
        _ => DefaultSpacing,
    };

    /// <summary>The user's formatting example, as it will be sent.</summary>
    /// <remarks>
    /// Cleaned rather than rejected. The field is free text on purpose — the whole point is to
    /// demonstrate a convention this codebase has no name for — so the only things removed are the
    /// ones that would break the block it is pasted into: control characters, and more than one
    /// blank line in a row.
    /// </remarks>
    public static string SanitizedSample(string? text)
    {
        if (string.IsNullOrEmpty(text)) return string.Empty;
        var cleaned = text.Replace("\r\n", "\n").Replace('\r', '\n');
        cleaned = new string([.. cleaned.Where(c => c is '\n' or '\t' || !IsControl(c))]);
        while (cleaned.Contains("\n\n\n")) cleaned = cleaned.Replace("\n\n\n", "\n\n");
        cleaned = cleaned.Trim();
        return cleaned.Length > MaxSampleCharacters
            ? cleaned[..MaxSampleCharacters].Trim()
            : cleaned;
    }

    private static bool IsControl(char value) => value < 0x20 || (value >= 0x7F && value <= 0x9F);

    public static string Label(TypographySpacing spacing) => spacing switch
    {
        TypographySpacing.Spaced => "Spaced — one space where Chinese meets Latin",
        TypographySpacing.Tight => "Tight — no space where Chinese meets Latin",
        _ => "Unchanged — however the model wrote it",
    };

    /// <summary>
    /// Applies the user's spacing rule and removes space that no convention allows.
    /// </summary>
    /// <remarks>
    /// Idempotent: normalising twice is normalising once, which matters because a split recording
    /// is normalised per chunk and again after stitching.
    /// </remarks>
    public static string Normalize(string text, TypographySpacing spacing)
    {
        if (spacing == TypographySpacing.Unchanged || string.IsNullOrEmpty(text)) return text;

        var output = new StringBuilder(text.Length + 8);
        // The last code point written, which is what a boundary is measured against.
        var previous = -1;
        var index = 0;

        while (index < text.Length)
        {
            var width = CodePointWidth(text, index);
            var current = CodePointAt(text, index);

            if (!IsHorizontalSpace(current))
            {
                // A boundary the model wrote without a space. Only Spaced has anything to add;
                // Tight has nothing to do until it meets a space.
                if (spacing == TypographySpacing.Spaced && IsScriptBoundary(previous, current))
                {
                    output.Append(' ');
                }

                output.Append(text, index, width);
                previous = current;
                index += width;
                continue;
            }

            // The whole run at once, so two spaces at a boundary collapse to the one the rule asks
            // for rather than to two.
            var end = index;
            while (end < text.Length && IsHorizontalSpace(CodePointAt(text, end)))
            {
                end += CodePointWidth(text, end);
            }

            var next = end < text.Length ? CodePointAt(text, end) : -1;

            if (previous < 0 || next < 0)
            {
                // Leading and trailing space is layout the speaker or the caller owns — an indent,
                // or the join between two stitched chunks — and is left exactly as it arrived.
                output.Append(text, index, end - index);
                previous = ' ';
                index = end;
                continue;
            }

            if (IsFullWidthPunctuation(previous) || IsFullWidthPunctuation(next))
            {
                // Not a preference. A full-width mark carries its own space inside the glyph, so no
                // convention in any of these scripts puts another one beside it — which is why this
                // runs under both settings. The reported symptom was an extra space after a full
                // stop, arriving on some sentences and not others.
                index = end;
                continue;
            }

            if (IsScriptBoundary(previous, next))
            {
                if (spacing == TypographySpacing.Spaced)
                {
                    output.Append(' ');
                    previous = ' ';
                }

                index = end;
                continue;
            }

            output.Append(text, index, end - index);
            previous = ' ';
            index = end;
        }

        return output.ToString();
    }

    private static int CodePointWidth(string text, int index) =>
        char.IsHighSurrogate(text[index])
        && index + 1 < text.Length
        && char.IsLowSurrogate(text[index + 1])
            ? 2 : 1;

    /// <summary>
    /// The code point at <paramref name="index"/>, tolerating an unpaired surrogate rather than
    /// throwing. A transcript is text from a network response; it does not get to crash a
    /// dictation because a model emitted half a character.
    /// </summary>
    private static int CodePointAt(string text, int index) =>
        CodePointWidth(text, index) == 2
            ? char.ConvertToUtf32(text[index], text[index + 1])
            : text[index];

    /// <summary>
    /// Space that is typography. A newline is not, and neither is anything else that carries
    /// structure: this transform must be unable to join two lines together.
    /// </summary>
    private static bool IsHorizontalSpace(int value) => value == ' ' || value == '\t';

    /// <summary>Han ideographs and Japanese kana.</summary>
    /// <remarks>
    /// Hangul is deliberately absent. Korean already separates its words with spaces, so Tight
    /// would take out a space the language requires — a setting about Chinese and Latin has no
    /// business editing Korean. Kana is included so Japanese is treated consistently within
    /// itself: excluding it would space <c>Web開発</c> and not <c>Webかいはつ</c>, which is the
    /// inconsistency this whole type exists to remove.
    /// </remarks>
    internal static bool IsCJK(int value) => value switch
    {
        >= 0x3400 and <= 0x4DBF => true,      // CJK Unified Ideographs Extension A
        >= 0x4E00 and <= 0x9FFF => true,      // CJK Unified Ideographs
        >= 0xF900 and <= 0xFAFF => true,      // CJK Compatibility Ideographs
        >= 0x20000 and <= 0x2A6DF => true,    // Extension B
        >= 0x2A700 and <= 0x2EBEF => true,    // Extensions C through F
        >= 0x2F800 and <= 0x2FA1F => true,    // Compatibility Ideographs Supplement
        // The one exception in the kana block: ・ is punctuation, and spacing around it would turn
        // A・B into A ・ B.
        >= 0x3041 and <= 0x30FF => value != 0x30FB,
        >= 0x31F0 and <= 0x31FF => true,      // Katakana phonetic extensions
        _ => false,
    };

    /// <summary>The Latin side of a boundary: letters and digits only.</summary>
    /// <remarks>
    /// Symbols are deliberately excluded, which makes <c>50%的人</c> come back unchanged rather
    /// than as <c>50% 的人</c>. Conservative on purpose — a rule that fires on punctuation has far
    /// more ways to be wrong, and nobody reported symbols.
    /// </remarks>
    internal static bool IsLatinAlphanumeric(int value)
    {
        // × and ÷ sit inside the Latin-1 letter range and are neither.
        if (value == 0x00D7 || value == 0x00F7) return false;
        return value switch
        {
            >= '0' and <= '9' => true,
            >= 'A' and <= 'Z' => true,
            >= 'a' and <= 'z' => true,
            >= 0x00C0 and <= 0x024F => true,  // Latin-1 Supplement, Latin Extended-A and B
            _ => false,
        };
    }

    /// <summary>
    /// Marks that already contain their own space. Latin quotation marks are excluded: " and ' are
    /// used in English exactly as often, and stripping the space beside one would be editing
    /// English prose on behalf of a Chinese setting.
    /// </summary>
    internal static bool IsFullWidthPunctuation(int value) => value switch
    {
        // 、。〈〉《》「」『』【】〔〕… — and the rest of CJK punctuation
        >= 0x3001 and <= 0x303F => true,
        0x30FB => true,                       // ・
        >= 0xFF01 and <= 0xFF0F => true,      // ！＂＃＄％＆＇（）＊＋，－．／
        >= 0xFF1A and <= 0xFF20 => true,      // ：；＜＝＞？＠
        >= 0xFF3B and <= 0xFF40 => true,      // ［＼］＾＿｀
        >= 0xFF5B and <= 0xFF65 => true,      // ｛｜｝～｟｠｡｢｣､･
        _ => false,
    };

    private static bool IsScriptBoundary(int left, int right) =>
        (IsCJK(left) && IsLatinAlphanumeric(right))
        || (IsLatinAlphanumeric(left) && IsCJK(right));
}

/// <summary>
/// Which characters Chinese is written in.
/// </summary>
/// <remarks>
/// <para>
/// Speech does not carry a writing system. Mandarin dictated by someone in Taipei and by someone in
/// Shanghai is the same audio, and the model has to pick — so it picks, differently, sometimes
/// inside one dictation. That was reported as the same complaint as the spacing: not that the
/// answer was wrong, but that it was not the same answer twice.
/// </para>
/// <para>
/// <see cref="Spoken"/> is the shipped contract's own rule and the default, so choosing nothing
/// sends nothing extra: prompt/system.md already says Simplified unless the speaker asks otherwise,
/// and the measured numbers in docs/PROMPT.md describe that request exactly.
/// </para>
/// <para>
/// This is a script choice, never a translation. Wording and language stay governed by the fidelity
/// and language-preservation rules, which the formatting block restates rather than relaxes.
/// </para>
/// </remarks>
public enum ChineseScript
{
    Spoken,
    Simplified,
    Traditional,
}

public static class ChineseScriptExtensions
{
    public static string Id(this ChineseScript script) => script switch
    {
        ChineseScript.Simplified => "simplified",
        ChineseScript.Traditional => "traditional",
        _ => "spoken",
    };

    public static ChineseScript ParseScript(string? id) => id?.Trim().ToLowerInvariant() switch
    {
        "simplified" => ChineseScript.Simplified,
        "traditional" => ChineseScript.Traditional,
        _ => ChineseScript.Spoken,
    };

    public static string Label(this ChineseScript script) => script switch
    {
        ChineseScript.Simplified => "Always Simplified",
        ChineseScript.Traditional => "Always Traditional",
        _ => "Follow the speaker — Simplified unless they ask otherwise",
    };
}

/// <summary>A named starting point for the dictation example — a button, never a stored setting.</summary>
/// <remarks>
/// <para>
/// This used to be <c>DictationStyle</c>, a five-case enum the user picked from and the app
/// persisted. That shape is what made the control unusable: the label had to compress a whole
/// instruction into a dash-clause, so "Chat — short lines, light punctuation" read as a mood and
/// behaved as a rule, and somebody who wanted the mood got line breaks they never asked for and
/// could not trace. The instruction was three files away from the only place it was described.
/// </para>
/// <para>
/// The instruction is the control now. A preset drops its text into the example box, where it can
/// be read and edited before it is used, and what the user ends up with is a string rather than a
/// case. Presets can therefore be added, renamed and reworded without migrating anybody.
/// </para>
/// <para>
/// The absence of a style is the empty string, which sends nothing — the same default the retired
/// <c>Spoken</c> had, and still what keeps every measured number in docs/PROMPT.md describing the
/// request a fresh install actually makes.
/// </para>
/// </remarks>
public enum DictationPreset
{
    /// <summary>First, and what a new install starts with. See <see cref="DictationExample"/>.</summary>
    Prose,
    Chat,
    Notes,
}

public static class DictationPresetExtensions
{
    public static string Id(this DictationPreset preset) => preset switch
    {
        DictationPreset.Notes => "notes",
        DictationPreset.Prose => "prose",
        _ => "chat",
    };

    public static DictationPreset? ParsePreset(string? id) => id?.Trim().ToLowerInvariant() switch
    {
        "chat" => DictationPreset.Chat,
        "notes" => DictationPreset.Notes,
        "prose" => DictationPreset.Prose,
        _ => null,
    };

    /// <summary>
    /// The button's text. A name and nothing else: what it means is the text it drops in the box,
    /// which is on screen the moment it is pressed.
    /// </summary>
    public static string Label(this DictationPreset preset) => preset switch
    {
        DictationPreset.Notes => "Notes",
        DictationPreset.Prose => "Prose",
        _ => "Chat",
    };

    /// <summary>One line beside the button, for the gap between pressing and reading.</summary>
    /// <remarks>
    /// Deliberately about <em>shape</em>, never about feel. The old labels promised a register and
    /// delivered a layout rule; these say what the text will physically look like.
    /// </remarks>
    public static string Shape(this DictationPreset preset) => preset switch
    {
        DictationPreset.Notes => "One point per line",
        DictationPreset.Prose => "Full sentences, paragraphs",
        _ => "Short lines, one thought each",
    };
}

/// <summary>How an older install's dictation-style setting becomes an example.</summary>
/// <remarks>
/// One named rule rather than the same three-branch conditional in four clients and two importers,
/// hand-ported from the Swift. It is a rule and not a default because the whole point of the
/// migration is that nobody's dictations change on upgrade: somebody who chose Chat had chat.md's
/// words in their request, so afterwards they have those same words in their box, byte for byte,
/// and can now see and edit them.
/// </remarks>
public static class DictationExample
{
    /// <summary>What a brand-new install starts with.</summary>
    /// <remarks>
    /// Empty used to be the default, and it had one real virtue: the shipped request was the one
    /// every measured number in docs/PROMPT.md described. It also meant a fresh install's
    /// transcripts were laid out however the model felt like that day, which is the complaint the
    /// whole formatting series started from -- a default of "no answer" is still an answer, and it
    /// was the least predictable one available.
    /// </summary>
    public const DictationPreset DefaultPreset = DictationPreset.Prose;

    /// <summary>The example a fresh install starts with, or null when there is nothing to do.</summary>
    /// <param name="stored">
    /// The persisted value, or null when the key has never been written. The distinction is the
    /// whole method: an empty string is somebody who pressed Clear and meant it, and seeding over
    /// that would put words back they had just removed. Only absence is a fresh install.
    /// </param>
    public static string? Seeding(string? stored, Func<DictationPreset, string?> presetText)
    {
        if (stored is not null) return null;
        return presetText(DefaultPreset) is { } text ? Typography.SanitizedSample(text) : null;
    }

    /// <returns>
    /// The text for the box, or <c>null</c> when the answer is not knowable yet -- a preset this
    /// build recognises whose file could not be read. Null is not "no style": a caller that treated
    /// it as one would clear the retired settings and destroy the only record of what the user had
    /// chosen, over something as temporary as an unreadable directory. Keep them and try again.
    /// </returns>
    public static string? Migrating(
        string? legacyStyle, string? legacyCustom, Func<DictationPreset, string?> presetText)
    {
        var name = (legacyStyle ?? string.Empty).Trim().ToLowerInvariant();
        if (name == "custom") return Typography.SanitizedSample(legacyCustom ?? string.Empty);
        if (DictationPresetExtensions.ParsePreset(name) is { } preset)
        {
            return presetText(preset) is { } text ? Typography.SanitizedSample(text) : null;
        }

        // "spoken", absent, or a value this build does not know. All three mean the box is empty,
        // which sends nothing -- the behaviour Spoken had, and the safe answer for a name this
        // build could not resolve even with the files in front of it.
        return string.Empty;
    }
}
