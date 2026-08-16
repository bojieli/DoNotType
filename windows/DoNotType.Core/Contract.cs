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
/// One file in prompt/ -- the same layout every platform ships.
/// </summary>
/// <remarks>
/// The contract used to be a single markdown file with the live text fenced off by
/// <c>&lt;!-- BEGIN SYSTEM --&gt;</c> markers, which meant a loader had to tell payload from prose by
/// convention -- and it got that wrong for as long as the markers existed, because the file
/// documented its own markers and a first-match search found the documentation. A part is a whole
/// file now. Everything in it is sent, so there is nothing to skip and nothing to mis-match.
/// </remarks>
public sealed record PromptPart(string Id, string RelativePath, string? Placeholder, string Group, string Label)
{
    public static readonly PromptPart System =
        new("system", "system.md", "{{FIDELITY_RULE}}", "Blocks", "Transcription");
    public static readonly PromptPart Rewrite =
        new("rewrite", "rewrite.md", "{{STYLE_RULE}}", "Blocks", "Rewrite");
    public static readonly PromptPart Summary =
        new("summary", "summary.md", "{{SUMMARY_RULE}}", "Blocks", "Summary");

    public static PromptPart Of(Fidelity fidelity) =>
        new($"fidelity:{fidelity.Id()}", $"fidelity/{fidelity.Id()}.md", null, "Fidelity", fidelity.Id());

    public static PromptPart Of(RewriteStyle style) =>
        new($"style:{style.Id()}", $"style/{style.Id()}.md", null, "Rewrite styles", style.Id());

    public static PromptPart Of(SummaryStyle style) =>
        new($"summary-style:{style.Id()}", $"summary-style/{style.Id()}.md", null, "Summary styles", style.Id());

    /// <summary>Every part that has a file, in the order a settings list should show them.</summary>
    public static IReadOnlyList<PromptPart> All { get; } = BuildAll();

    private static PromptPart[] BuildAll()
    {
        var parts = new List<PromptPart> { System, Rewrite, Summary };
        parts.AddRange(Enum.GetValues<Fidelity>().Select(Of));
        parts.AddRange(Enum.GetValues<RewriteStyle>().Where(s => s != RewriteStyle.Verbatim).Select(Of));
        parts.AddRange(Enum.GetValues<SummaryStyle>().Select(Of));
        return [.. parts];
    }

    public static PromptPart? Parse(string id) =>
        All.FirstOrDefault(p => string.Equals(p.Id, id.Trim(), StringComparison.OrdinalIgnoreCase));

    /// <summary>
    /// Whether this part is substituted into a numbered list item in another part.
    /// </summary>
    /// <remarks>
    /// The one transform in the whole loader: a clause is written as a wrapped paragraph and joined
    /// into a single line on load, because it lands inside `5. {{FIDELITY_RULE}}` and a hard newline
    /// there would break the list it lands in.
    /// </remarks>
    public bool IsClause => Placeholder is null;

    /// <summary>One line on what this part does, for the editor that has room to say so.</summary>
    public string SummaryLine => Id switch
    {
        "system" => "Sent on every request. Must contain {{FIDELITY_RULE}}.",
        "rewrite" => "Sent only when a rewrite style is chosen.",
        "summary" => "Sent only when a summary style is chosen.",
        _ when Group == "Fidelity" => "Substituted into the transcription block.",
        _ when Group == "Rewrite styles" => "Substituted into the rewrite block.",
        _ => "Substituted into the summary block.",
    };
}

/// <summary>
/// Where a part's text comes from: the shipped prompt/ directory, or the user's copy of one file
/// in it.
/// </summary>
/// <remarks>
/// The override is per part rather than all-or-nothing, which is the point of the split. Someone
/// who tuned fidelity/light.md keeps getting shipped updates to system.md, and a part they never
/// touched cannot be stale. The old single-file override froze the whole contract at whatever it
/// looked like on the day it was edited.
/// </remarks>
public sealed class PromptSource(string bundled, string? overrides = null)
{
    public string Bundled { get; } = bundled;
    public string? Overrides { get; } = overrides;

    /// <summary>Walks up from a starting directory, so the app works from a build output folder.</summary>
    public static string? FindPromptDirectory(string? start = null)
    {
        var directory = new DirectoryInfo(start ?? AppContext.BaseDirectory);
        for (var i = 0; i < 8 && directory is not null; i++)
        {
            var candidate = Path.Combine(directory.FullName, "prompt");
            // Matches on a file inside the directory rather than the directory itself, so an
            // unrelated prompt/ folder in a parent tree cannot shadow the real one.
            if (File.Exists(Path.Combine(candidate, PromptPart.System.RelativePath))) return candidate;
            directory = directory.Parent;
        }
        return null;
    }

    public string? OverridePath(PromptPart part) =>
        Overrides is null ? null : Path.Combine(Overrides, part.RelativePath);

    public bool IsOverridden(PromptPart part) =>
        OverridePath(part) is { } path && File.Exists(path);

    public IReadOnlyList<PromptPart> OverriddenParts =>
        [.. PromptPart.All.Where(IsOverridden)];

    /// <summary>The file actually in force for a part.</summary>
    public string PathFor(PromptPart part) =>
        IsOverridden(part) ? OverridePath(part)! : Path.Combine(Bundled, part.RelativePath);

    /// <summary>The part's text, exactly as it will be sent.</summary>
    public string TextFor(PromptPart part)
    {
        var text = EditableTextFor(part);
        if (text.Length == 0)
        {
            throw new InvalidOperationException(
                $"{PathFor(part)} is empty. A part file is sent in full, so an empty one would "
                + $"send nothing for {part.Id}.");
        }
        return part.IsClause
            ? text.Replace("\r\n", " ").Replace("\n", " ").Replace("\r", " ")
            : text;
    }

    /// <summary>The text as it sits on disk, unjoined -- what an editor should show and save.</summary>
    public string EditableTextFor(PromptPart part)
    {
        var path = PathFor(part);
        if (!File.Exists(path))
        {
            throw new InvalidOperationException(
                $"The prompt is missing {part.RelativePath} — nothing to send for {part.Id}. "
                + $"Looked in {path}.");
        }
        return File.ReadAllText(path).Trim();
    }
}

/// <summary>
/// Assembles an instruction out of the parts in a PromptSource -- the same files the other
/// platforms ship.
/// </summary>
public sealed class PromptBuilder(PromptSource source)
{
    public PromptBuilder(string directory) : this(new PromptSource(directory)) { }

    public PromptSource Source { get; } = source;

    public static PromptBuilder FromDirectory(string path) => new(path);

    public static string? FindPromptDirectory(string? start = null) =>
        PromptSource.FindPromptDirectory(start);

    public string TextFor(PromptPart part) => Source.TextFor(part);

    public string SystemInstruction(Fidelity fidelity) =>
        Assemble(PromptPart.System, PromptPart.Of(fidelity));

    /// <summary>
    /// The instruction for whichever second stage a mode asks for, or null when it asks for none.
    /// </summary>
    /// <remarks>
    /// One entry point, so a caller cannot route a summary through the rewrite part by picking the
    /// wrong method -- which is the mistake the two-part split exists to make impossible. A rewrite
    /// may never drop a fact; a summary exists to.
    /// </remarks>
    public string? SecondStageInstruction(TranscriptMode mode) => mode switch
    {
        TranscriptMode.RewriteMode rewrite =>
            Assemble(PromptPart.Rewrite, PromptPart.Of(rewrite.Style)),
        TranscriptMode.SummaryMode summary =>
            Assemble(PromptPart.Summary, PromptPart.Of(summary.Style)),
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

    /// <summary>
    /// Checks that every part resolves and every placeholder is fillable, so a broken prompt is
    /// found at startup rather than mid-dictation.
    /// </summary>
    public void Validate()
    {
        foreach (var part in PromptPart.All) _ = Source.TextFor(part);
        foreach (var fidelity in Enum.GetValues<Fidelity>()) _ = SystemInstruction(fidelity);
    }

    private string Assemble(PromptPart host, PromptPart clause)
    {
        var body = Source.TextFor(host);
        return host.Placeholder is null ? body : body.Replace(host.Placeholder, Source.TextFor(clause));
    }
}
