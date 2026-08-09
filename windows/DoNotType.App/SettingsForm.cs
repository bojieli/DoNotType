using System.Windows.Forms;
using DoNotType.Core;

namespace DoNotType.App;

/// <summary>
/// Providers and keys, the hotkey, grounding, and history with retry — the four things this
/// category of app is expected to expose.
///
/// Built in code rather than a designer file: a .Designer.cs is generated, unreviewable in a
/// diff, and this is a two-tab form.
/// </summary>
public sealed class SettingsForm : Form
{
    private readonly AppSettings _settings;
    private readonly DictationController _controller;

    private readonly ComboBox _provider = new() { DropDownStyle = ComboBoxStyle.DropDownList };
    private readonly TextBox _model = new();
    private readonly TextBox _apiKey = new() { UseSystemPasswordChar = true };
    private readonly Label _connection = new() { AutoSize = true, MaximumSize = new Size(420, 0) };
    private readonly ComboBox _trigger = new() { DropDownStyle = ComboBoxStyle.DropDownList };
    private readonly ComboBox _mode = new() { DropDownStyle = ComboBoxStyle.DropDownList };
    private readonly ComboBox _fidelity = new() { DropDownStyle = ComboBoxStyle.DropDownList };
    private readonly CheckBox _grounding = new() { Text = "Ground transcription in screen text", AutoSize = true };
    private readonly ComboBox _retention = new() { DropDownStyle = ComboBoxStyle.DropDownList };
    private readonly CheckBox _keepAudio = new() { Text = "Keep audio for successful dictations", AutoSize = true };
    private readonly ListView _history = new()
    {
        View = View.Details,
        FullRowSelect = true,
        Dock = DockStyle.Fill,
    };
    private readonly Label _historySummary = new() { AutoSize = true };

    public SettingsForm(AppSettings settings, DictationController controller)
    {
        _settings = settings;
        _controller = controller;

        Text = "DoNotType Settings";
        Size = new Size(660, 620);
        StartPosition = FormStartPosition.CenterScreen;
        MinimizeBox = false;

        var tabs = new TabControl { Dock = DockStyle.Fill };
        tabs.TabPages.Add(BuildGeneralTab());
        tabs.TabPages.Add(BuildHistoryTab());
        Controls.Add(tabs);

        LoadValues();
        RefreshHistory();
    }

    // ---- General -----------------------------------------------------------------------------

    private TabPage BuildGeneralTab()
    {
        var page = new TabPage("General");
        var layout = new FlowLayoutPanel
        {
            Dock = DockStyle.Fill,
            FlowDirection = FlowDirection.TopDown,
            WrapContents = false,
            AutoScroll = true,
            Padding = new Padding(18),
        };

        layout.Controls.Add(Heading("Provider"));
        layout.Controls.Add(Labelled("Service", _provider));
        layout.Controls.Add(Labelled("Model", _model));
        layout.Controls.Add(Labelled("API key", _apiKey));

        var test = new Button { Text = "Test connection", Width = 140 };
        test.Click += async (_, _) => await TestConnectionAsync(test).ConfigureAwait(true);
        layout.Controls.Add(test);
        layout.Controls.Add(_connection);
        layout.Controls.Add(Caption(
            "Calls go straight to the provider with your key. Nothing routes through a server of "
            + "ours; the key is encrypted for your Windows account."));

        layout.Controls.Add(Heading("Dictation"));
        layout.Controls.Add(Labelled("Key", _trigger));
        layout.Controls.Add(Labelled("Behaviour", _mode));
        layout.Controls.Add(Labelled("Fidelity", _fidelity));
        layout.Controls.Add(Caption(
            "A quick tap starts recording and a second tap ends it; holding the key past a moment "
            + "records only while held. Escape cancels. Even Tidy only changes typography — none "
            + "of the fidelity settings reword you."));

        layout.Controls.Add(Heading("Grounding"));
        layout.Controls.Add(_grounding);
        layout.Controls.Add(Caption(
            "Screen text is sent as-is — no vocabulary list, no dictionary, no previous "
            + "transcripts. It may correct spelling, never the words you said."));

        var save = new Button { Text = "Save", Width = 120 };
        save.Click += (_, _) => SaveValues();
        layout.Controls.Add(save);

        page.Controls.Add(layout);
        return page;
    }

    // ---- History -----------------------------------------------------------------------------

    private TabPage BuildHistoryTab()
    {
        var page = new TabPage("History");

        _history.Columns.Add("When", 110);
        _history.Columns.Add("Status", 80);
        _history.Columns.Add("Transcript", 380);

        var toolbar = new FlowLayoutPanel
        {
            Dock = DockStyle.Top,
            Height = 74,
            Padding = new Padding(10, 10, 10, 0),
        };
        toolbar.Controls.Add(Labelled("Keep", _retention));
        toolbar.Controls.Add(_keepAudio);

        var retry = new Button { Text = "Retry failed", Width = 110 };
        retry.Click += async (_, _) =>
        {
            retry.Enabled = false;
            var (succeeded, failed) = await _controller.RetryAllAsync().ConfigureAwait(true);
            _historySummary.Text = $"{succeeded} succeeded, {failed} still failing";
            RefreshHistory();
            retry.Enabled = true;
        };
        toolbar.Controls.Add(retry);

        var deleteAll = new Button { Text = "Delete all", Width = 100 };
        deleteAll.Click += (_, _) =>
        {
            _controller.History.DeleteAll();
            RefreshHistory();
        };
        toolbar.Controls.Add(deleteAll);
        toolbar.Controls.Add(_historySummary);

        // Per-item retry: double-clicking a failed row reissues just that dictation.
        _history.DoubleClick += async (_, _) =>
        {
            if (SelectedRecord() is not { CanRetry: true } record) return;

            _historySummary.Text = "Retrying…";
            await _controller.RetryAsync(record).ConfigureAwait(true);
            RefreshHistory();
        };

        // Per-item delete, from the keyboard and from a right-click menu. Deleting one transcript
        // should not require deleting all of them.
        var rowMenu = new ContextMenuStrip();
        var deleteOne = new ToolStripMenuItem("Delete this transcript");
        deleteOne.Click += (_, _) => DeleteSelected();
        var retryOne = new ToolStripMenuItem("Retry this dictation");
        retryOne.Click += async (_, _) =>
        {
            if (SelectedRecord() is not { CanRetry: true } record) return;
            await _controller.RetryAsync(record).ConfigureAwait(true);
            RefreshHistory();
        };
        var copyOne = new ToolStripMenuItem("Copy transcript");
        copyOne.Click += (_, _) =>
        {
            if (SelectedRecord() is { } record && record.Text.Length > 0) Clipboard.SetText(record.Text);
        };
        rowMenu.Opening += (_, _) =>
        {
            var record = SelectedRecord();
            retryOne.Enabled = record?.CanRetry == true;
            copyOne.Enabled = record?.Text.Length > 0;
            deleteOne.Enabled = record is not null;
        };
        rowMenu.Items.AddRange([retryOne, copyOne, new ToolStripSeparator(), deleteOne]);
        _history.ContextMenuStrip = rowMenu;

        _history.KeyDown += (_, e) =>
        {
            if (e.KeyCode != Keys.Delete) return;
            DeleteSelected();
            e.Handled = true;
        };

        page.Controls.Add(_history);
        page.Controls.Add(toolbar);
        return page;
    }

    private DictationRecord? SelectedRecord() =>
        _history.SelectedItems.Count == 0
            ? null
            : _history.SelectedItems[0].Tag as DictationRecord;

    private void DeleteSelected()
    {
        // Multi-select is enabled, so a range delete is one action rather than N.
        var records = _history.SelectedItems
            .Cast<ListViewItem>()
            .Select(item => item.Tag)
            .OfType<DictationRecord>()
            .ToList();
        if (records.Count == 0) return;

        foreach (var record in records) _controller.History.Delete(record.Id);
        RefreshHistory();
    }

    private void RefreshHistory()
    {
        _controller.History.Configure(_settings.Retention, _settings.KeepAudio);
        var records = _controller.History.All();

        // Rendered in one pass rather than truncated. A capped list that says nothing about the
        // cap reads as "this is your whole history" when it is not — and the retention policy,
        // not the view, is what is supposed to bound how much there is.
        _history.BeginUpdate();
        _history.Items.Clear();
        foreach (var record in records)
        {
            var item = new ListViewItem(record.CreatedAt.ToString("MMM d HH:mm"))
            {
                Tag = record,
            };
            item.SubItems.Add(record.Status.ToString());
            item.SubItems.Add(record.Summary.Replace('\n', ' '));
            if (record.CanRetry) item.ForeColor = Color.Firebrick;
            _history.Items.Add(item);
        }
        _history.EndUpdate();

        var retryable = records.Count(r => r.CanRetry);
        var bytes = _controller.History.AudioBytes();
        _historySummary.Text =
            $"{records.Count} dictations · {retryable} to retry · {bytes / 1024} KB audio"
            + "   (double-click to retry · Delete key or right-click to remove)";
    }

    // ---- Values ------------------------------------------------------------------------------

    private void LoadValues()
    {
        _provider.Items.AddRange(Enum.GetNames<ProviderKind>());
        _provider.SelectedItem = _settings.Provider.ToString();
        _model.Text = _settings.Model;
        _apiKey.Text = _settings.ApiKey ?? string.Empty;

        foreach (var trigger in Enum.GetValues<HotkeyMonitor.Trigger>())
        {
            _trigger.Items.Add(HotkeyMonitor.Label(trigger));
        }
        _trigger.SelectedIndex = (int)_settings.Trigger;

        _mode.Items.AddRange(["Tap to toggle, hold to talk", "Hold to talk", "Tap to start, tap to stop"]);
        _mode.SelectedIndex = _settings.HotkeyMode switch
        {
            HotkeyMonitor.Mode.PushToTalk => 1,
            HotkeyMonitor.Mode.HandsFree => 2,
            _ => 0,
        };

        foreach (var fidelity in Enum.GetValues<Fidelity>()) _fidelity.Items.Add(fidelity.Describe());
        _fidelity.SelectedIndex = (int)_settings.Fidelity;

        _grounding.Checked = _settings.GroundingEnabled;

        foreach (var policy in Enum.GetValues<RetentionPolicy>()) _retention.Items.Add(policy.Label());
        _retention.SelectedIndex = (int)_settings.Retention;
        _retention.SelectedIndexChanged += (_, _) =>
        {
            _settings.Retention = (RetentionPolicy)_retention.SelectedIndex;
            _settings.Save();
            RefreshHistory();
        };

        _keepAudio.Checked = _settings.KeepAudio;
        _keepAudio.CheckedChanged += (_, _) =>
        {
            _settings.KeepAudio = _keepAudio.Checked;
            _settings.Save();
            RefreshHistory();
        };
    }

    private void SaveValues()
    {
        _settings.Provider = Enum.Parse<ProviderKind>((string)_provider.SelectedItem!);
        _settings.Model = string.IsNullOrWhiteSpace(_model.Text)
            ? _settings.Provider.DefaultModel()
            : _model.Text.Trim();
        _settings.ApiKey = _apiKey.Text.Trim();
        _settings.Trigger = (HotkeyMonitor.Trigger)_trigger.SelectedIndex;
        _settings.HotkeyMode = _mode.SelectedIndex switch
        {
            1 => HotkeyMonitor.Mode.PushToTalk,
            2 => HotkeyMonitor.Mode.HandsFree,
            _ => HotkeyMonitor.Mode.Automatic,
        };
        _settings.Fidelity = (Fidelity)_fidelity.SelectedIndex;
        _settings.GroundingEnabled = _grounding.Checked;
        _settings.Save();

        _controller.ReloadHotkey();
        _connection.Text = "Saved.";
    }

    private async Task TestConnectionAsync(Button button)
    {
        var key = _apiKey.Text.Trim();
        if (key.Length == 0) key = _settings.ResolvedApiKey() ?? string.Empty;
        if (key.Length == 0)
        {
            _connection.Text = "No API key set.";
            return;
        }

        button.Enabled = false;
        _connection.Text = "Checking…";
        try
        {
            var kind = Enum.Parse<ProviderKind>((string)_provider.SelectedItem!);
            var provider = ProviderFactory.Create(kind, key, _model.Text.Trim());
            await provider.TranscribeAsync(
                "You are a transcription engine.",
                [new InputPart.Text("Pretend the audio said: ok. Transcribe it.")])
                .ConfigureAwait(true);
            _connection.Text = $"✓ {provider.Name} reachable, key accepted";
        }
        catch (Exception error)
        {
            _connection.Text = $"✗ {error.Message}";
        }
        finally
        {
            button.Enabled = true;
        }
    }

    // ---- Tiny view helpers -------------------------------------------------------------------

    private static Label Heading(string text) => new()
    {
        Text = text,
        AutoSize = true,
        Font = new Font(SystemFonts.MessageBoxFont!, FontStyle.Bold),
        Margin = new Padding(0, 14, 0, 6),
    };

    private static Label Caption(string text) => new()
    {
        Text = text,
        AutoSize = true,
        MaximumSize = new Size(560, 0),
        ForeColor = SystemColors.GrayText,
        Margin = new Padding(0, 2, 0, 10),
    };

    private static Control Labelled(string label, Control control)
    {
        control.Width = 300;
        var row = new FlowLayoutPanel
        {
            FlowDirection = FlowDirection.LeftToRight,
            AutoSize = true,
            WrapContents = false,
            Margin = new Padding(0, 2, 0, 2),
        };
        row.Controls.Add(new Label { Text = label, AutoSize = true, Width = 90, Padding = new Padding(0, 5, 0, 0) });
        row.Controls.Add(control);
        return row;
    }
}
