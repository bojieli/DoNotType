namespace DoNotType.Core;

/// <summary>What the next dictation will do with what it hears.</summary>
/// <remarks>
/// Three values because the second stage has three answers, which the type system has said for a
/// while and the interface did not. A desktop chooses between them by <em>which key it is
/// holding</em>; the phones use a three-way chip. Both used to have a two-state choice that a
/// target language in Settings quietly overrode -- so a desktop's main key could deliver a
/// translation while the panel describing it still promised verbatim, and the phones' chip could
/// read "Rewrite" over a dictation that came back translated.
///
/// Hand-ported from the Swift with the strings word-identical, and the same three cases
/// <see cref="TranscriptMode"/> has -- named for what the user is choosing rather than for what
/// the pipeline does with it. See docs/PARITY.md.
/// </remarks>
public enum LiveMode
{
    /// <summary>Verbatim. The default, and the product.</summary>
    Dictate,

    /// <summary>Verbatim first, then rewritten in the configured style.</summary>
    Rewrite,

    /// <summary>Verbatim first, then written again in the configured language.</summary>
    Translate,
}

public static class LiveModeExtensions
{
    public static LiveMode Default => LiveMode.Dictate;

    public static string Id(this LiveMode mode) => mode switch
    {
        LiveMode.Rewrite => "rewrite",
        LiveMode.Translate => "translate",
        _ => "dictate",
    };

    /// <summary>What the chip says. Short, because the phones have 68dp for it.</summary>
    public static string Label(this LiveMode mode) => mode switch
    {
        LiveMode.Rewrite => "Rewrite",
        LiveMode.Translate => "Translate",
        _ => "Dictate",
    };

    public static LiveMode From(string? id) =>
        Enum.GetValues<LiveMode>().FirstOrDefault(
            mode => mode.Id() == id?.Trim().ToLowerInvariant(), LiveMode.Dictate);

    /// <summary>The stage this mode asks for, given the style and language configured.</summary>
    /// <remarks>
    /// One resolver rather than the same three-branch conditional in four call sites, and it is
    /// the place the empty cases are decided: a translation with no language and a rewrite with no
    /// style are both just a dictation, because the alternative is a second request that asks a
    /// model to do something unspecified to a transcript.
    /// </remarks>
    public static TranscriptMode Stage(this LiveMode mode, RewriteStyle style, string language)
    {
        switch (mode)
        {
            case LiveMode.Rewrite:
                return style.IsRewrite() ? TranscriptMode.Rewrite(style) : TranscriptMode.Verbatim;
            case LiveMode.Translate:
                var target = TranslationTarget.Sanitized(language);
                return target.Length == 0
                    ? TranscriptMode.Verbatim
                    : TranscriptMode.Translate(target);
            default:
                return TranscriptMode.Verbatim;
        }
    }

    /// <summary>Whether this mode can run right now, and what to say when it cannot.</summary>
    /// <remarks>
    /// The control asks before it offers: one that is greyed out with a reason beats one that is
    /// offered and then silently does something else, which is what the target-language override
    /// used to do to the rewrite key.
    /// </remarks>
    public static RewriteAvailability Availability(
        this LiveMode mode, ProviderKind provider, string language, Func<ProviderKind, bool> hasKey)
    {
        switch (mode)
        {
            case LiveMode.Rewrite:
                return RewriteAvailability.Resolve(provider, hasKey, SecondStageJob.Rewriting);
            case LiveMode.Translate:
                if (TranslationTarget.Sanitized(language).Length == 0)
                {
                    return new RewriteAvailability.NoTargetLanguage();
                }
                return RewriteAvailability.Resolve(provider, hasKey, SecondStageJob.Translating);
            default:
                // One stage, so there is nothing here that can be missing beyond the key the
                // dictation itself needs, which every client reports where it is actually noticed.
                return new RewriteAvailability.Available();
        }
    }
}
