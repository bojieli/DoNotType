namespace DoNotType.Core;

/// <summary>
/// One dictation's context, rendered as text: what the inspector shows and what its copy button
/// produces.
/// </summary>
/// <remarks>
/// <para>
/// In the core rather than beside the window, for the same reason the command line is: it is the
/// part with no platform in it, and it is the part worth testing. The claim it makes is strong —
/// "this is what was sent" — so it renders the stored <see cref="ScreenContext"/> back through the
/// real <see cref="ContextEncoder"/> rather than formatting the fields itself. A view that
/// formatted them itself would drift from the encoder the moment either changed, and would be
/// reassuring rather than true.
/// </para>
/// <para>
/// One string, and deliberately: what is on screen and what the copy button produces are then the
/// same by construction, so nobody can paste a report into an issue that differs from what they
/// were looking at.
/// </para>
/// </remarks>
public static class ContextReport
{
    public static string Describe(DictationRecord record)
    {
        var lines = new List<string>
        {
            $"# What was sent — {record.CreatedAt.ToLocalTime():O}",
            $"app: {record.AppName ?? "unknown"}",
            $"window: {record.WindowTitle ?? "unknown"}",
            $"model: {record.Model}",
            string.Empty,
        };

        if (record.Context is null)
        {
            // "Nothing was sent" and "something was sent and it was blank" are different facts,
            // and the one on screen has to be the true one.
            lines.Add(
                "No context was sent. Grounding was off, the app was on the blocklist, the "
                + "accessibility tree returned nothing, or this dictation predates contexts being "
                + "stored.");
        }
        else
        {
            lines.Add($"~{new ContextEncoder().EstimatedTokens(record.Context)} context tokens");
            var parts = new ContextEncoder().Encode(record.Context);
            for (var index = 0; index < parts.Count; index++)
            {
                lines.Add(string.Empty);
                lines.Add(parts[index] switch
                {
                    InputPart.Text text =>
                        $"── Part {index + 1} · text · {text.Value.Length} characters\n{text.Value}",
                    InputPart.Image image =>
                        $"── Part {index + 1} · screenshot · {image.Data.Length / 1024} KB",
                    _ => $"── Part {index + 1}",
                });
            }
        }

        lines.Add(string.Empty);
        lines.Add("── Audio");
        lines.Add(
            record.AudioFileName is null
                ? "Not retained. Audio is kept only for dictations that still need retrying, "
                    + "unless \"Keep audio\" is on."
                : "Retained so this dictation can be retried.");

        // Both versions, when a rewrite was applied. Seeing what changed is the point of storing
        // the verbatim transcript separately.
        lines.Add(string.Empty);
        lines.Add("── What you said");
        lines.Add(record.Text);
        if (record.StyledText is { Length: > 0 } styled)
        {
            lines.Add(string.Empty);
            lines.Add(
                record.Mode is { Length: > 0 } mode
                    ? $"── What was inserted · {mode}"
                    : "── What was inserted");
            lines.Add(styled);
        }

        return string.Join("\n", lines);
    }
}
