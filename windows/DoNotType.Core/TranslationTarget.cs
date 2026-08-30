namespace DoNotType.Core;

/// <summary>
/// The language a dictation is written in when it is not the one that was spoken.
/// </summary>
/// <remarks>
/// <para>
/// Free text, and deliberately so, for the same reason the Model field is: languages are not ours
/// to enumerate. "Traditional Chinese", "Brazilian Portuguese", "plain English for a five-year-old"
/// and "Swiss German" are all things a model can do and none of them is a row in an enum somebody
/// would have thought to add. The check here is about <b>shape</b>, never about existence — what
/// passes is still sent to the model, which remains the authority on whether it can write it.
/// </para>
/// <para>
/// Hand-ported from <c>Sources/DoNotTypeCore/TranslationTarget.swift</c>; the Kotlin port is
/// <c>android/app/src/main/kotlin/app/donottype/core/TranslationTarget.kt</c>.
/// </para>
/// </remarks>
public static class TranslationTarget
{
    /// <summary>
    /// Long enough for "Traditional Chinese, in the register of a business email"; short enough
    /// that nobody pastes a paragraph into it and wonders why every request got slower.
    /// </summary>
    public const int MaxCharacters = 60;

    /// <summary>Empty means off, which is the default and the only value that changes nothing.</summary>
    public static string Sanitized(string? text)
    {
        if (string.IsNullOrEmpty(text)) return string.Empty;
        // One line, because this lands inside a sentence in the instruction. A newline pasted from
        // a language list would break the sentence around it rather than the language it names.
        var collapsed = string.Join(
            ' ',
            text.Replace('\r', ' ').Replace('\n', ' ').Replace('\t', ' ')
                .Split(' ', StringSplitOptions.RemoveEmptyEntries));
        return collapsed.Length > MaxCharacters ? collapsed[..MaxCharacters].Trim() : collapsed;
    }

    /// <summary>
    /// The sentence under the field when what is in it could not be a language, or null when it
    /// could.
    /// </summary>
    /// <remarks>
    /// Phrased as what the field takes rather than as a rejection — nothing is lost while it is
    /// showing, exactly as with a model ID. Must stay word-identical across the four clients.
    /// </remarks>
    public static string? ValidationMessage(string? text)
    {
        var value = text ?? string.Empty;
        // Empty is off, not invalid.
        if (value.Trim().Length == 0) return null;
        if (Sanitized(value).Length > MaxCharacters || value.Length > MaxCharacters)
        {
            return $"A language name is at most {MaxCharacters} characters.";
        }
        return null;
    }

    /// <summary>
    /// One tap for the languages people ask for most, in each language's own name where it has
    /// one. Not a whitelist: the field accepts anything, and this list is only a shortcut.
    /// </summary>
    public static IReadOnlyList<string> Suggestions { get; } =
    [
        "English",
        "简体中文",
        "繁體中文",
        "日本語",
        "한국어",
        "Español",
        "Français",
        "Deutsch",
        "Português",
        "Русский",
        "Italiano",
        "हिन्दी",
        "العربية",
    ];
}

/// <summary>
/// What the <c>styled</c> field of a transcription request is being asked for.
/// </summary>
/// <remarks>
/// <para>
/// One request returns the verbatim transcript and a second version of it side by side, which is
/// what makes a rewrite cost no extra round trip while leaving "what did I actually say"
/// answerable. There are two things worth asking for in that field, and they are not the same job —
/// a rewrite keeps the speaker's language and may reshape the prose; a translation changes the
/// language and may reshape nothing — so the request says which, rather than the call site passing
/// a clause and hoping the sentence around it happens to fit.
/// </para>
/// <para>
/// A closed hierarchy rather than two nullable parameters, because only one of them may ever be
/// set: two nullables would make "both at once" a state somebody has to remember not to construct.
/// </para>
/// </remarks>
public abstract record StyledRequest
{
    private StyledRequest() { }

    /// <summary>The transcript rewritten in a style, carrying the clause text from prompt/style/.</summary>
    public sealed record Style(string Clause) : StyledRequest;

    /// <summary>The transcript written again in another language, named by the user.</summary>
    public sealed record Translation(string Language) : StyledRequest;
}
