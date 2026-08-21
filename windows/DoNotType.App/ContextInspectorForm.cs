using DoNotType.Core;

namespace DoNotType.App;

/// <summary>
/// Shows exactly what was sent with one dictation.
/// </summary>
/// <remarks>
/// <para>
/// This is the open-source answer to a competitor encrypting its captured context to a server key
/// you do not hold: if an app reads your screen, you should be able to read what it read.
/// </para>
/// <para>
/// It renders the stored <see cref="ScreenContext"/> back through the real
/// <see cref="ContextEncoder"/>, so what appears here is the text that actually went over the wire
/// rather than a description of it. A view that formatted the fields itself would drift from the
/// encoder the moment either changed, and would be reassuring rather than true.
/// </para>
/// </remarks>
public sealed class ContextInspectorForm : Form
{
    private readonly DictationRecord _record;

    public ContextInspectorForm(DictationRecord record)
    {
        _record = record;

        Text = "What was sent";
        Size = new Size(720, 640);
        StartPosition = FormStartPosition.CenterParent;
        MinimizeBox = false;
        MaximizeBox = false;

        var body = new FlowLayoutPanel
        {
            Dock = DockStyle.Fill,
            FlowDirection = FlowDirection.TopDown,
            WrapContents = false,
            AutoScroll = true,
            Padding = new Padding(14),
        };

        body.Controls.Add(Header());
        if (record.Context is null)
        {
            body.Controls.Add(Explanation(
                "No context was sent.\r\n\r\n"
                + "Grounding was off, the app was on the blocklist, the accessibility tree "
                + "returned nothing, or this dictation predates contexts being stored."));
        }
        else
        {
            var parts = new ContextEncoder().Encode(record.Context);
            for (var index = 0; index < parts.Count; index++) AddPart(body, index, parts[index]);
        }

        body.Controls.Add(AudioNote());
        AddTranscriptComparison(body);

        var footer = new FlowLayoutPanel
        {
            Dock = DockStyle.Bottom,
            FlowDirection = FlowDirection.RightToLeft,
            AutoSize = true,
            AutoSizeMode = AutoSizeMode.GrowAndShrink,
            Padding = new Padding(10, 8, 10, 8),
        };

        var close = new Button { Text = "Done", Width = 90, DialogResult = DialogResult.OK };
        footer.Controls.Add(close);

        // Copying the whole thing matters more here than anywhere else in the app: this is the
        // evidence somebody attaches to a report about a transcript that came out wrong.
        var copy = new Button { Text = "Copy everything", Width = 130 };
        copy.Click += (_, _) => Clipboard.SetText(AsText());
        footer.Controls.Add(copy);

        Controls.Add(body);
        Controls.Add(footer);

        // As in SettingsForm, and last for the same reason: the sizes above are 96 DPI pixels, and
        // saying so is what lets WinForms carry them to the DPI actually in use. This window is the
        // evidence somebody attaches to a bug report, so it is the last one that can afford to
        // render with its buttons cut in half.
        AutoScaleDimensions = new SizeF(7F, 15F);
        AutoScaleMode = AutoScaleMode.Font;

        AcceptButton = close;
        CancelButton = close;
    }

    private Control Header()
    {
        var when = _record.CreatedAt.ToLocalTime().ToString("d MMM HH:mm");
        var where = _record.AppName is { Length: > 0 } app
            ? $"{app}{(_record.WindowTitle is { Length: > 0 } title ? $" — {title}" : string.Empty)}"
            : "an unknown window";
        var tokens = _record.Context is { } context
            ? $" · ~{new ContextEncoder().EstimatedTokens(context)} context tokens"
            : string.Empty;

        return new Label
        {
            Text = $"{when} · {where}\r\n{_record.Model}{tokens}",
            AutoSize = true,
            MaximumSize = new Size(660, 0),
            Font = new Font(SystemFonts.MessageBoxFont!, FontStyle.Bold),
            Margin = new Padding(0, 0, 0, 12),
        };
    }

    private void AddPart(Control parent, int index, InputPart part)
    {
        switch (part)
        {
            case InputPart.Text text:
                parent.Controls.Add(
                    PartLabel($"Part {index + 1} · text", $"{text.Value.Length} characters"));
                parent.Controls.Add(Body(text.Value));
                break;

            case InputPart.Image image:
                parent.Controls.Add(PartLabel(
                    $"Part {index + 1} · screenshot",
                    $"{image.Data.Length / 1024} KB · sent because the accessibility tree was thin"));
                break;

            // The recording is described separately, below.
            default:
                break;
        }
    }

    private Control AudioNote()
    {
        var detail = _record.AudioFileName is null
            ? "Not retained. Audio is kept only for dictations that still need retrying, unless "
                + "\"Keep audio\" is on."
            : "Retained so this dictation can be retried.";

        var panel = new FlowLayoutPanel
        {
            FlowDirection = FlowDirection.TopDown,
            WrapContents = false,
            AutoSize = true,
            Margin = new Padding(0, 10, 0, 0),
        };
        panel.Controls.Add(PartLabel("Audio", "your recording"));
        panel.Controls.Add(Explanation(detail));
        return panel;
    }

    /// <summary>
    /// Both versions, when a rewrite was applied. Seeing what changed is the point of storing the
    /// verbatim transcript separately.
    /// </summary>
    private void AddTranscriptComparison(Control parent)
    {
        if (_record.StyledText is not { Length: > 0 } styled) return;

        parent.Controls.Add(PartLabel("What you said", "verbatim, always stored"));
        parent.Controls.Add(Body(_record.Text));
        parent.Controls.Add(PartLabel(
            "What was inserted",
            _record.Mode is { Length: > 0 } mode ? $"rewritten · {mode}" : "rewritten"));
        parent.Controls.Add(Body(styled));
    }

    private static Label PartLabel(string title, string detail) => new()
    {
        Text = $"{title}   {detail}",
        AutoSize = true,
        ForeColor = Color.FromArgb(110, 120, 130),
        Margin = new Padding(0, 10, 0, 4),
    };

    /// <summary>
    /// Selectable and read-only, so any part of it can be copied without being editable — the
    /// thing on screen is a record of what happened, not a field.
    /// </summary>
    private static TextBox Body(string text) => new()
    {
        Text = text,
        Multiline = true,
        ReadOnly = true,
        ScrollBars = ScrollBars.Vertical,
        Width = 650,
        Height = Math.Clamp(text.Length / 6 + 40, 60, 240),
        Font = new Font(FontFamily.GenericMonospace, 8.5f),
        BackColor = Color.FromArgb(246, 247, 249),
    };

    private static Label Explanation(string text) => new()
    {
        Text = text,
        AutoSize = true,
        MaximumSize = new Size(650, 0),
        ForeColor = Color.FromArgb(90, 100, 110),
    };

    /// <summary>The whole thing as plain text, for pasting into a report.</summary>
    private string AsText() => ContextReport.Describe(_record);

}
