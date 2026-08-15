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
    Bullets,
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
        RewriteStyle.Bullets => "bullets",
        _ => "verbatim",
    };

    public static bool IsRewrite(this RewriteStyle style) => style != RewriteStyle.Verbatim;

    public static string Label(this RewriteStyle style) => style switch
    {
        RewriteStyle.Formal => "Formal — professional prose",
        RewriteStyle.Concise => "Concise — same voice, fewer words",
        RewriteStyle.Bullets => "Bullets — one idea per line",
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

    public static readonly TranscriptMode Verbatim = new VerbatimMode();

    public static TranscriptMode Rewrite(RewriteStyle style) => new RewriteMode(style);

    public static TranscriptMode Summary(SummaryStyle style) => new SummaryMode(style);

    /// <summary>`verbatim`, `rewrite:formal`, `summary:actions` -- the CLI and history spelling.</summary>
    public string Id => this switch
    {
        RewriteMode rewrite => $"rewrite:{rewrite.Style.Id()}",
        SummaryMode summary => $"summary:{summary.Style.Id()}",
        _ => "verbatim",
    };

    public string Label => this switch
    {
        RewriteMode rewrite => $"Rewrite — {rewrite.Style.Label()}",
        SummaryMode summary => $"Summary — {summary.Style.Label()}",
        _ => "Verbatim — word for word",
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
        Rewrite(RewriteStyle.Bullets),
        Summary(SummaryStyle.Brief),
        Summary(SummaryStyle.Bullets),
        Summary(SummaryStyle.Actions),
    ];

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
                if (tail is null) return Rewrite(RewriteStyle.Formal);
                return tail switch
                {
                    "formal" => Rewrite(RewriteStyle.Formal),
                    "concise" => Rewrite(RewriteStyle.Concise),
                    "bullets" => Rewrite(RewriteStyle.Bullets),
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
            default:
                return null;
        }
    }

    /// <summary>Every accepted spelling, for a --help string that lists them.</summary>
    public static IReadOnlyList<string> AcceptedSpellings { get; } = All.Select(mode => mode.Id).ToList();
}
