using DoNotType.Core;

namespace DoNotType.App;

/// <summary>
/// The log, in the app.
/// </summary>
/// <remarks>
/// The tray app had nowhere to read what it was doing: no console, no Console.app equivalent, and
/// the one artifact a bug report could carry did not exist. This is the last few thousand events
/// with the recording level next to them, so turning detail up does not mean quitting and
/// relaunching from a terminal — which on Windows is doubly awkward because a WinExe launched from
/// Explorer inherits no shell environment at all.
/// </remarks>
internal sealed class LogsTab
{
    private readonly AppSettings _settings;
    private readonly ComboBox _record = new()
    {
        Dock = DockStyle.Fill,
        DropDownStyle = ComboBoxStyle.DropDownList,
    };
    private readonly ComboBox _show = new()
    {
        Dock = DockStyle.Fill,
        DropDownStyle = ComboBoxStyle.DropDownList,
    };
    private readonly TextBox _filter = new() { Dock = DockStyle.Fill };
    private readonly CheckBox _content = new() { Text = "Include transcripts", AutoSize = true };
    private readonly Label _warning = new() { Dock = DockStyle.Fill, AutoSize = false, Height = 20 };
    private readonly TextBox _output = new()
    {
        Dock = DockStyle.Fill,
        Multiline = true,
        ReadOnly = true,
        ScrollBars = ScrollBars.Both,
        WordWrap = false,
        Font = new Font(FontFamily.GenericMonospace, 8.5f),
    };
    private readonly System.Windows.Forms.Timer _poll = new() { Interval = 700 };

    private static readonly LogLevel[] RecordLevels =
        [LogLevel.Trace, LogLevel.Debug, LogLevel.Info, LogLevel.Warn, LogLevel.Error, LogLevel.Off];

    private static readonly (LogLevel Level, string Label)[] ShowLevels =
    [
        (LogLevel.Trace, "All"),
        (LogLevel.Debug, "Debug and up"),
        (LogLevel.Info, "Info and up"),
        (LogLevel.Warn, "Warnings and up"),
        (LogLevel.Error, "Errors only"),
    ];

    private long _lastSeen = -1;

    public LogsTab(AppSettings settings) => _settings = settings;

    public TabPage Build()
    {
        var page = new TabPage("Logs");

        foreach (var level in RecordLevels) _record.Items.Add(level.Describe());
        _record.SelectedIndex = Math.Max(0, Array.IndexOf(RecordLevels, _settings.LogLevel));
        _record.SelectedIndexChanged += (_, _) =>
        {
            _settings.LogLevel = RecordLevels[_record.SelectedIndex];
            _settings.Save();
            LogRouter.SetLevel(_settings.LogLevel);
        };

        foreach (var (_, label) in ShowLevels) _show.Items.Add(label);
        _show.SelectedIndex = 0;
        _show.SelectedIndexChanged += (_, _) => Refresh(force: true);

        _filter.TextChanged += (_, _) => Refresh(force: true);

        _content.Checked = _settings.LogContent;
        _content.CheckedChanged += (_, _) =>
        {
            _settings.LogContent = _content.Checked;
            _settings.Save();
            LogRouter.SetIncludesContent(_content.Checked);
            RefreshWarning();
        };

        var layout = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 4,
            Padding = new Padding(12),
        };
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 60));
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 150));
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 170));

        layout.Controls.Add(new Label { Text = "Record", AutoSize = true }, 0, 0);
        layout.Controls.Add(_record, 1, 0);
        layout.Controls.Add(_show, 2, 0);
        layout.Controls.Add(_content, 3, 0);

        layout.Controls.Add(new Label { Text = "Filter", AutoSize = true }, 0, 1);
        layout.Controls.Add(_filter, 1, 1);

        var buttons = new FlowLayoutPanel { Dock = DockStyle.Fill, AutoSize = true };
        var copy = new Button { Text = "Copy", Width = 70 };
        copy.Click += (_, _) =>
        {
            if (_output.TextLength > 0) Clipboard.SetText(_output.Text);
        };
        var reveal = new Button { Text = "Show file", Width = 90 };
        reveal.Click += (_, _) => Reveal();
        var clear = new Button { Text = "Clear", Width = 70 };
        clear.Click += (_, _) =>
        {
            LogRouter.ClearBuffer();
            Refresh(force: true);
        };
        buttons.Controls.Add(copy);
        buttons.Controls.Add(reveal);
        buttons.Controls.Add(clear);
        layout.Controls.Add(buttons, 2, 1);
        layout.SetColumnSpan(buttons, 2);

        layout.Controls.Add(_warning, 1, 2);
        layout.SetColumnSpan(_warning, 3);

        layout.Controls.Add(_output, 0, 3);
        layout.SetColumnSpan(_output, 4);
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));

        page.Controls.Add(layout);

        // Polled rather than pushed. A sink calling back into WinForms would have to marshal to the
        // UI thread on every line — including lines emitted from the audio callback — and a log
        // viewer that adds latency to the thing it is observing is not worth having.
        _poll.Tick += (_, _) => Refresh();
        _poll.Start();
        page.Disposed += (_, _) => _poll.Dispose();

        RefreshWarning();
        Refresh(force: true);
        return page;
    }

    private void Refresh(bool force = false)
    {
        var count = LogRouter.EmittedCount;
        if (!force && count == _lastSeen) return;
        _lastSeen = count;

        var events = LogRouter.Recent(
            limit: 1_000,
            minimumLevel: ShowLevels[Math.Max(_show.SelectedIndex, 0)].Level,
            containing: _filter.Text);

        _output.Text = events.Count == 0
            ? "Nothing logged yet. Set Record to Debug to see every request, the grounding route "
                + "each backend was given, and every retry."
            : string.Join(Environment.NewLine, events.Select(e => e.Render()));
        _output.SelectionStart = _output.TextLength;
        _output.ScrollToCaret();
    }

    private void RefreshWarning() =>
        _warning.Text = _settings.LogContent
            ? "The log now contains what you said. Turn this off before sharing it."
            : LogRouter.FilePath ?? "No log file.";

    private void Reveal()
    {
        if (LogRouter.FilePath is not { } path) return;
        LogRouter.Flush();
        // Selecting the file rather than opening it: a log opened in whatever is registered for
        // .log is a coin flip, and the useful action is nearly always "show me where it is".
        System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
        {
            FileName = "explorer.exe",
            Arguments = $"/select,\"{path}\"",
            UseShellExecute = true,
        });
    }
}
