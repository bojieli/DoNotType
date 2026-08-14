using System.Text;

namespace DoNotType.Core;

/// <summary>
/// How much cleanup the transcript may receive. Even <see cref="Tidy"/> may only change
/// typography, never words. Kept identical to the Swift and Kotlin enums and to PROMPT.md.
/// </summary>
public enum Fidelity
{
    Raw,
    Light,
    Tidy,
}

public static class FidelityExtensions
{
    public static string Id(this Fidelity fidelity) => fidelity switch
    {
        Fidelity.Raw => "raw",
        Fidelity.Light => "light",
        _ => "tidy",
    };

    public static Fidelity Parse(string? id) => id switch
    {
        "raw" => Fidelity.Raw,
        "tidy" => Fidelity.Tidy,
        _ => Fidelity.Light,
    };

    public static string Describe(this Fidelity fidelity) => fidelity switch
    {
        Fidelity.Raw => "Raw — every um and false start",
        Fidelity.Light => "Light — drop fillers, keep your words",
        _ => "Tidy — light, plus punctuation",
    };
}

/// <summary>
/// Everything captured from the screen for one dictation. Field names and budgets mirror the
/// other platforms so a context block is comparable across them while debugging.
/// </summary>
public sealed class ScreenContext
{
    public string? AppName { get; set; }
    public string? WindowTitle { get; set; }
    public string? BrowserUrl { get; set; }
    public string? Role { get; set; }
    public bool? IsEditable { get; set; }
    public string? VisibleText { get; set; }
    public string? TextBeforeCaret { get; set; }
    public string? TextAfterCaret { get; set; }
    public string? SelectedText { get; set; }
    public byte[]? ScreenshotPng { get; set; }

    public bool IsEmpty =>
        ScreenshotPng is null &&
        new[] { AppName, WindowTitle, BrowserUrl, VisibleText, TextBeforeCaret, TextAfterCaret, SelectedText }
            .All(string.IsNullOrWhiteSpace);

    /// <summary>Too little text to rely on, so the screenshot path should fire.</summary>
    public bool IsAccessibilityThin(int threshold = 300) =>
        (VisibleText?.Trim().Length ?? 0)
        + (TextBeforeCaret?.Trim().Length ?? 0)
        + (TextAfterCaret?.Trim().Length ?? 0) < threshold;
}

/// <summary>
/// Token estimation and truncation, ported so every platform cuts buffers at the same place.
/// The direction is the point: screen text is clipped keeping the <em>tail</em>, because the end
/// of a buffer is the part nearest the caret.
/// </summary>
public static class TokenBudget
{
    public static int Estimate(string text)
    {
        if (string.IsNullOrEmpty(text)) return 0;

        var length = text.Length;
        var han = text.Count(c => c >= 0x4E00 && c <= 0x9FFF);
        if ((double)han / length > 0.3)
        {
            return (int)Math.Ceiling(length / 1.3);
        }

        var words = text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Length;
        return (int)Math.Ceiling(Math.Max(words * 1.3, length / 4.0));
    }

    public static string ClipKeepingTail(string text, int maxChars) =>
        maxChars <= 0 ? string.Empty
        : text.Length <= maxChars ? text
        : text[^maxChars..];

    public static string ClipKeepingHead(string text, int maxChars) =>
        maxChars <= 0 ? string.Empty
        : text.Length <= maxChars ? text
        : text[..maxChars];
}

/// <summary>One entry in the request's input list.</summary>
public abstract record InputPart
{
    public sealed record Text(string Value) : InputPart;
    public sealed record Image(byte[] Data, string MimeType) : InputPart;
    public sealed record Audio(byte[] Data, string MimeType) : InputPart;
    /// <summary>Audio already uploaded to the Files API; referenced rather than carried.</summary>
    public sealed record RemoteAudio(string Uri, string MimeType) : InputPart;
}

/// <summary>
/// Turns a <see cref="ScreenContext"/> into request parts, verbatim.
///
/// Does no analysis: no term extraction, no ranking, no summarising. See CONTEXT_FORMAT.md.
/// </summary>
public sealed class ContextEncoder(
    int visibleTextChars = 10_000,
    int beforeCaretChars = 1_000,
    int afterCaretChars = 1_000,
    int thinTextThreshold = 300)
{
    public const string Header = "===== SCREEN CONTEXT — REFERENCE ONLY, DO NOT TRANSCRIBE =====";

    /// <summary>
    /// Restates the content rule immediately before the audio, where the system instruction is
    /// thousands of tokens away.
    /// </summary>
    /// <remarks>
    /// Deliberately abstract. An earlier version illustrated the rule with the same version numbers
    /// as the test case and made substitution <em>worse</em> (11/19 → 15/18): naming the wrong
    /// answer in the instruction appears to prime it. Examples here must never contain a concrete
    /// value that could be echoed.
    ///
    /// Must stay byte-identical to the other ports -- see <c>eval/conformance/</c>.
    /// </remarks>
    public const string Footer =
        "===== END SCREEN CONTEXT =====\n"
        + "None of the text above was spoken. It is a spelling reference only.\n"
        + "Numbers, version numbers, dates and names in your output must come from the audio alone,\n"
        + "even when the text above shows a different value for the same thing.\n"
        + "The audio that follows is the ONLY thing to transcribe.";

    public IReadOnlyList<InputPart> Encode(ScreenContext context)
    {
        if (context.IsEmpty) return Array.Empty<InputPart>();

        var parts = new List<InputPart>();
        var opening = new List<string> { Header };
        opening.AddRange(IdentityLines(context));
        parts.Add(new InputPart.Text(string.Join("\n", opening)));

        if (context.ScreenshotPng is { } png)
        {
            parts.Add(new InputPart.Image(png, "image/png"));
        }

        var sections = new List<string>();
        var thin = (context.VisibleText?.Trim().Length ?? 0) < thinTextThreshold;
        if (context.ScreenshotPng is not null || !thin)
        {
            AddSection(sections, "VISIBLE TEXT (accessibility)",
                TokenBudget.ClipKeepingTail(context.VisibleText ?? string.Empty, visibleTextChars));
        }
        AddSection(sections, "TEXT BEFORE CARET",
            TokenBudget.ClipKeepingTail(context.TextBeforeCaret ?? string.Empty, beforeCaretChars));
        AddSection(sections, "TEXT AFTER CARET",
            TokenBudget.ClipKeepingHead(context.TextAfterCaret ?? string.Empty, afterCaretChars));
        AddSection(sections, "SELECTED TEXT", context.SelectedText ?? string.Empty);

        sections.Add(Footer);
        parts.Add(new InputPart.Text(string.Join("\n\n", sections)));
        return parts;
    }

    public int EstimatedTokens(ScreenContext context) =>
        Encode(context).Sum(part => part switch
        {
            InputPart.Text text => TokenBudget.Estimate(text.Value),
            // A 1024px-long-edge window screenshot tiles to roughly this many tokens.
            InputPart.Image => 1_300,
            _ => 0,
        });

    private static IEnumerable<string> IdentityLines(ScreenContext context)
    {
        var app = context.AppName?.Trim() ?? string.Empty;
        var title = context.WindowTitle?.Trim() ?? string.Empty;

        if (app.Length > 0 && title.Length > 0) yield return $"App: {app} — {title}";
        else if (app.Length > 0) yield return $"App: {app}";
        else if (title.Length > 0) yield return $"Window: {title}";

        if (!string.IsNullOrWhiteSpace(context.BrowserUrl)) yield return $"URL: {context.BrowserUrl.Trim()}";
        if (!string.IsNullOrWhiteSpace(context.Role))
        {
            yield return $"Field: {context.Role.Trim()}{(context.IsEditable == true ? " · editable" : string.Empty)}";
        }
    }

    /// <summary>Empty sections are omitted: a bare header costs tokens and invites the model to fill it.</summary>
    private static void AddSection(List<string> into, string title, string body)
    {
        var trimmed = body.Trim();
        if (trimmed.Length > 0) into.Add($"--- {title} ---\n{trimmed}");
    }
}

/// <summary>
/// Assembles the system instruction from PROMPT.md — the same file the other platforms ship.
/// </summary>
public sealed class PromptBuilder(string template)
{
    private const string Begin = "<!-- BEGIN SYSTEM -->";
    private const string End = "<!-- END SYSTEM -->";
    private const string Placeholder = "{{FIDELITY_RULE}}";
    private const string RewriteBegin = "<!-- BEGIN REWRITE -->";
    private const string RewriteEnd = "<!-- END REWRITE -->";
    private const string StylePlaceholder = "{{STYLE_RULE}}";
    private const string SummaryBegin = "<!-- BEGIN SUMMARY -->";
    private const string SummaryEnd = "<!-- END SUMMARY -->";
    private const string SummaryPlaceholder = "{{SUMMARY_RULE}}";

    public static PromptBuilder FromFile(string path) => new(File.ReadAllText(path));

    /// <summary>Walks up from a starting directory, so the app works from a build output folder.</summary>
    public static string? FindPromptFile(string? start = null)
    {
        var directory = new DirectoryInfo(start ?? AppContext.BaseDirectory);
        for (var i = 0; i < 8 && directory is not null; i++)
        {
            var candidate = Path.Combine(directory.FullName, "PROMPT.md");
            if (File.Exists(candidate)) return candidate;
            directory = directory.Parent;
        }
        return null;
    }

    public string SystemInstruction(Fidelity fidelity)
    {
        var begin = template.IndexOf(Begin, StringComparison.Ordinal);
        var end = template.IndexOf(End, StringComparison.Ordinal);
        if (begin < 0 || end <= begin)
        {
            throw new InvalidOperationException("PROMPT.md is missing its system markers.");
        }

        var body = template[(begin + Begin.Length)..end].Trim();
        if (!body.Contains(Placeholder))
        {
            throw new InvalidOperationException($"PROMPT.md has no {Placeholder}.");
        }
        return body.Replace(Placeholder, Clause(fidelity));
    }

    /// <summary>
    /// The instruction for whichever second stage a mode asks for, or null when it asks for none.
    /// </summary>
    /// <remarks>
    /// One entry point, so a caller cannot route a summary through the rewrite block by picking the
    /// wrong method -- which is the mistake the two-block split in PROMPT.md exists to make
    /// impossible. A rewrite may never drop a fact; a summary exists to.
    /// </remarks>
    public string? SecondStageInstruction(TranscriptMode mode) => mode switch
    {
        TranscriptMode.RewriteMode rewrite =>
            Block(RewriteBegin, RewriteEnd, "rewrite")
                .Replace(StylePlaceholder, Clause($"style: {rewrite.Style.Id()}")),
        TranscriptMode.SummaryMode summary =>
            Block(SummaryBegin, SummaryEnd, "summary")
                .Replace(SummaryPlaceholder, Clause($"summary: {summary.Style.Id()}")),
        _ => null,
    };

    /// <summary>Whether the prompt in force can run a mode's second stage at all.</summary>
    public bool SupportsSecondStage(TranscriptMode mode)
    {
        try
        {
            SecondStageInstruction(mode);
            return true;
        }
        catch (InvalidOperationException)
        {
            return false;
        }
    }

    private string Block(string begin, string end, string name)
    {
        var start = template.IndexOf(begin, StringComparison.Ordinal);
        var finish = template.IndexOf(end, StringComparison.Ordinal);
        if (start < 0 || finish <= start)
        {
            throw new InvalidOperationException(
                $"This prompt has no {name} block. A prompt edited before summaries existed will "
                + "not have one — restore the shipped prompt, or copy that block across from it.");
        }
        return template[(start + begin.Length)..finish].Trim();
    }

    private string Clause(Fidelity fidelity) => Clause(fidelity.Id());

    /// <summary>The fenced clause under any `### name` heading -- a fidelity, a style, a summary.</summary>
    private string Clause(string name)
    {
        var heading = $"### {name}";
        var start = template.IndexOf(heading, StringComparison.Ordinal);
        if (start < 0) throw new InvalidOperationException($"PROMPT.md has no section {heading}.");

        var open = template.IndexOf("```", start, StringComparison.Ordinal);
        var close = open < 0 ? -1 : template.IndexOf("```", open + 3, StringComparison.Ordinal);
        if (open < 0 || close < 0) throw new InvalidOperationException($"No fenced clause under {heading}.");

        return template[(open + 3)..close].Trim().Replace("\n", " ").Replace("\r", string.Empty);
    }
}
