namespace DoNotType.Core;

/// <summary>
/// An optional rewrite applied to a finished transcript.
/// </summary>
/// <remarks>
/// <see cref="Verbatim"/> is not a style -- it is the absence of one, and the default. The others
/// exist because people do sometimes want formal prose; what makes this different from the tool
/// this project replaces is that the raw transcript is always produced first, always stored, and
/// always recoverable.
/// </remarks>
public enum RewriteStyle
{
    Verbatim,
    Formal,
    Concise,
    Casual,

    /// <summary>
    /// The user's own description or example, from settings rather than from a file.
    /// </summary>
    /// <remarks>
    /// Three shipped styles are three guesses at what somebody wants their email to sound like.
    /// This is the fourth answer — the one we did not think of — and it goes through the same
    /// prompt/rewrite.md host block as the presets, so the never-remove-a-fact rule applies to it
    /// exactly as it applies to Formal.
    /// </remarks>
    Custom,
}

/// <summary>
/// The shape of a summary.
/// </summary>
/// <remarks>
/// Summarising is the one thing this codebase does that is <em>supposed</em> to lose content, which
/// is why it is not a <see cref="RewriteStyle"/>. Rule 1 of the rewrite block -- never remove a fact
/// -- is the rule this project exists to enforce, and a summary style living alongside `formal` and
/// `concise` would mean one entry in that list quietly exempt from it. It gets its own prompt block,
/// its own instruction, and its own place in the type system so no caller can reach it by accident.
/// </remarks>
public enum SummaryStyle
{
    Brief,
    Bullets,
    Actions,
}

public static class StyleExtensions
{
    public static string Id(this RewriteStyle style) => style switch
    {
        RewriteStyle.Formal => "formal",
        RewriteStyle.Concise => "concise",
        RewriteStyle.Casual => "casual",
        RewriteStyle.Custom => "custom",
        _ => "verbatim",
    };

    public static bool IsRewrite(this RewriteStyle style) => style != RewriteStyle.Verbatim;

    /// <summary>
    /// Whether the clause comes from a file in prompt/style/. False for Custom, whose clause is the
    /// user's own text, and for Verbatim, which is the absence of a rewrite.
    /// </summary>
    public static bool HasClauseFile(this RewriteStyle style) =>
        style.IsRewrite() && style != RewriteStyle.Custom;

    public static string Label(this RewriteStyle style) => style switch
    {
        RewriteStyle.Formal => "Formal — professional prose",
        RewriteStyle.Concise => "Concise — same voice, fewer words",
        RewriteStyle.Casual => "Casual — relaxed, as if typed",
        RewriteStyle.Custom => "Custom — your own description or example",
        _ => "Verbatim — exactly what you said",
    };

    public static string Id(this SummaryStyle style) => style switch
    {
        SummaryStyle.Bullets => "bullets",
        SummaryStyle.Actions => "actions",
        _ => "brief",
    };

    public static string Label(this SummaryStyle style) => style switch
    {
        SummaryStyle.Bullets => "Bullets — the key points",
        SummaryStyle.Actions => "Actions — decisions and next steps",
        _ => "Brief — a short paragraph",
    };
}

/// <summary>
/// What the user gets back, once the transcript exists.
/// </summary>
/// <remarks>
/// The ordering matters and is the project's whole position in one type. Transcription happens first
/// and produces the verbatim text; everything else is a <em>second</em> stage over text that has
/// already been stored. There is deliberately no mode that transcribes and summarises in one
/// request, because such a request has no verbatim output to keep -- and "what did I actually say"
/// stops being answerable the moment one exists.
/// </remarks>
public abstract record TranscriptMode
{
    private TranscriptMode() { }

    public sealed record VerbatimMode : TranscriptMode;

    public sealed record RewriteMode(RewriteStyle Style) : TranscriptMode;

    public sealed record SummaryMode(SummaryStyle Style) : TranscriptMode;

    /// <summary>
    /// Verbatim, then written again in another language. The words change; nothing else may.
    /// </summary>
    /// <remarks>
    /// The language is free text rather than an enum for the same reason a model ID is: languages
    /// are not ours to enumerate, and the model is the authority on which it can write. See
    /// <see cref="TranslationTarget"/>.
    /// </remarks>
    public sealed record TranslateMode(string Language) : TranscriptMode;

    public static readonly TranscriptMode Verbatim = new VerbatimMode();

    public static TranscriptMode Rewrite(RewriteStyle style) => new RewriteMode(style);

    public static TranscriptMode Summary(SummaryStyle style) => new SummaryMode(style);

    public static TranscriptMode Translate(string language) =>
        new TranslateMode(TranslationTarget.Sanitized(language));

    /// <summary>`verbatim`, `rewrite:formal`, `summary:actions` -- the CLI and history spelling.</summary>
    public string Id => this switch
    {
        RewriteMode rewrite => $"rewrite:{rewrite.Style.Id()}",
        SummaryMode summary => $"summary:{summary.Style.Id()}",
        TranslateMode translate => $"translate:{translate.Language}",
        _ => "verbatim",
    };

    public string Label => this switch
    {
        RewriteMode rewrite => $"Rewrite — {rewrite.Style.Label()}",
        SummaryMode summary => $"Summary — {summary.Style.Label()}",
        TranslateMode translate => $"Translate — into {translate.Language}",
        _ => "Verbatim — word for word",
    };

    /// <summary>What to show while the second request is in flight.</summary>
    /// <remarks>
    /// The mode's own word rather than "Writing the result…". Somebody who chose a summary is
    /// waiting for a summary, and a label that says so is the difference between a wait that makes
    /// sense and one that looks like the app has stalled after already getting the words — which is
    /// what it looks like, because the transcript exists by then and nothing on screen is moving.
    ///
    /// Here rather than in each interface because there are five of them, and a summary called one
    /// thing on a phone and another on a laptop is drift nobody notices until they see both.
    /// </remarks>
    public string ProgressLabel => this switch
    {
        RewriteMode rewrite => rewrite.Style switch
        {
            RewriteStyle.Formal => "Rewriting…",
            RewriteStyle.Concise => "Tightening…",
            RewriteStyle.Casual => "Loosening…",
            // Deliberately the plain word. The other three are named after what that style does to
            // the prose, and nothing here knows what the user asked for.
            RewriteStyle.Custom => "Rewriting…",
            _ => "Finishing…",
        },
        SummaryMode summary => summary.Style switch
        {
            SummaryStyle.Bullets => "Summarising into bullets…",
            SummaryStyle.Actions => "Picking out the actions…",
            _ => "Summarising…",
        },
        TranslateMode => "Translating…",
        _ => "Finishing…",
    };

    /// <summary>
    /// Whether a second, text-only request is needed. False only for verbatim.
    /// </summary>
    /// <remarks>
    /// This is also the question "can a speech recognition backend do this?" -- a recogniser has no
    /// text input at all, so anything true here needs a language model somewhere in the chain.
    /// </remarks>
    public bool NeedsSecondPass => this is not VerbatimMode;

    /// <summary>
    /// The rewrite style this mode applied, for the history column that already exists. Null for
    /// verbatim and for summaries, which are not a rewrite style and must not be recorded as one.
    /// </summary>
    public RewriteStyle? RewriteStyleOrNull => this is RewriteMode rewrite ? rewrite.Style : null;

    /// <summary>Every mode a picker should offer, with the styles expanded.</summary>
    public static IReadOnlyList<TranscriptMode> All { get; } =
    [
        Verbatim,
        Rewrite(RewriteStyle.Formal),
        Rewrite(RewriteStyle.Concise),
        Rewrite(RewriteStyle.Casual),
        Rewrite(RewriteStyle.Custom),
        Summary(SummaryStyle.Brief),
        Summary(SummaryStyle.Bullets),
        Summary(SummaryStyle.Actions),
    ];

    /// <summary>
    /// The same list with a translation into <paramref name="language"/> in it, for the screens
    /// that have a target to offer.
    /// </summary>
    /// <remarks>
    /// Absent from <see cref="All"/> because a translation without a language is not a mode: there
    /// is nothing to put in the picker until the user has named one.
    /// </remarks>
    public static IReadOnlyList<TranscriptMode> AllTranslatingInto(string? language)
    {
        var target = TranslationTarget.Sanitized(language);
        return target.Length == 0 ? All : [.. All, Translate(target)];
    }

    /// <summary>
    /// Parses the CLI or stored spelling. A bare `rewrite` or `summary` takes that stage's default,
    /// so it is a complete instruction rather than a validation error.
    /// </summary>
    public static TranscriptMode? Parse(string? id)
    {
        var parts = (id ?? string.Empty).Trim().ToLowerInvariant().Split(':', 2);
        var head = parts.Length > 0 ? parts[0] : string.Empty;
        // An empty style is no style: `--mode rewrite:` is a colon someone typed and did not
        // finish, and it means the same as `--mode rewrite`. All three platforms agree on this
        // because they used to disagree — see the parity table in the tests.
        var tail = parts.Length > 1 && parts[1].Length > 0 ? parts[1] : null;

        switch (head)
        {
            case "verbatim" or "raw" or "transcribe" or "none":
                return Verbatim;
            case "rewrite":
                if (tail is null) return Rewrite(RewriteStyle.Casual);
                return tail switch
                {
                    "formal" => Rewrite(RewriteStyle.Formal),
                    "concise" => Rewrite(RewriteStyle.Concise),
                    "casual" => Rewrite(RewriteStyle.Casual),
                    "custom" => Rewrite(RewriteStyle.Custom),
                    _ => null,
                };
            case "summary" or "summarise" or "summarize":
                if (tail is null) return Summary(SummaryStyle.Brief);
                return tail switch
                {
                    "brief" => Summary(SummaryStyle.Brief),
                    "bullets" => Summary(SummaryStyle.Bullets),
                    "actions" => Summary(SummaryStyle.Actions),
                    _ => null,
                };
            case "translate":
                // No default language, so a bare `translate` is rejected rather than guessing one.
                // Every other stage has an obvious default; "into what?" has none, and picking
                // English would be this project choosing a language on someone's behalf.
                if (tail is null) return null;
                // Taken from the original spelling rather than the lowercased one: a language is a
                // name, and `--mode translate:Français` must not deliver `français`.
                var original = (id ?? string.Empty).Trim();
                var colon = original.IndexOf(':');
                if (colon < 0) return null;
                var language = TranslationTarget.Sanitized(original[(colon + 1)..]);
                return language.Length == 0 ? null : Translate(language);
            default:
                return null;
        }
    }

    /// <summary>Every accepted spelling, for a --help string that lists them.</summary>
    /// <remarks>
    /// The translation is a concrete example rather than a placeholder: the language is free text,
    /// so there is no list to enumerate, and --help showing something that cannot be typed is worse
    /// than showing one thing that can.
    /// </remarks>
    public static IReadOnlyList<string> AcceptedSpellings { get; } =
        [.. All.Select(mode => mode.Id), "translate:English"];
}
