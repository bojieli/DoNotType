using System.Windows.Forms;
using DoNotType.Core;

namespace DoNotType.App;

/// <summary>
/// Providers and keys, the hotkey, grounding, and history with retry — the four things this
/// category of app is expected to expose.
///
/// Built in code rather than a designer file: a .Designer.cs is generated and unreviewable in a
/// diff.
/// </summary>
public sealed class SettingsForm : Form
{
    private readonly AppSettings _settings;
    private readonly DictationController _controller;

    private readonly ComboBox _provider = new() { DropDownStyle = ComboBoxStyle.DropDownList };
    private readonly TextBox _model = new();
    private readonly TextBox _apiKey = new() { UseSystemPasswordChar = true };

    /// <summary>
    /// What the selected backend is recommended for. Empty and hidden for the ones there is no
    /// recommendation for, which is most of them.
    /// </summary>
    private readonly Label _recommendationNote = new() { AutoSize = true, MaximumSize = new Size(430, 0) };

    /// <summary>What the selected backend gives up. Empty and hidden for a model provider.</summary>
    private readonly Label _providerNote = new() { AutoSize = true, MaximumSize = new Size(430, 0) };

    private readonly Label _connection = new() { AutoSize = true, MaximumSize = new Size(420, 0) };

    private readonly ComboBox _fallback = new() { DropDownStyle = ComboBoxStyle.DropDownList };
    private readonly TextBox _fallbackKey = new() { UseSystemPasswordChar = true };
    private readonly NumericUpDown _fallbackAfter = new() { Minimum = 1, Maximum = 120, Width = 70 };
    private readonly Label _fallbackNote = new() { AutoSize = true, MaximumSize = new Size(430, 0) };
    private readonly ComboBox _trigger = new() { DropDownStyle = ComboBoxStyle.DropDownList };
    private readonly ComboBox _cancelShortcut = new() { DropDownStyle = ComboBoxStyle.DropDownList };
    private readonly ComboBox _finishAndSend = new() { DropDownStyle = ComboBoxStyle.DropDownList };
    private readonly ComboBox _secondTrigger = new() { DropDownStyle = ComboBoxStyle.DropDownList };
    private readonly ComboBox _secondStyle = new() { DropDownStyle = ComboBoxStyle.DropDownList };
    private readonly ComboBox _microphone = new() { DropDownStyle = ComboBoxStyle.DropDownList };
    private readonly CheckBox _sounds = new() { Text = "Play a tone when recording starts and stops", AutoSize = true };
    private readonly Label _secondKeyNote = new()
    {
        AutoSize = true,
        MaximumSize = new Size(520, 0),
        ForeColor = Color.FromArgb(190, 140, 60),
        Visible = false,
    };
    private readonly ComboBox _mode = new() { DropDownStyle = ComboBoxStyle.DropDownList };
    private readonly ComboBox _fidelity = new() { DropDownStyle = ComboBoxStyle.DropDownList };
    private readonly CheckBox _grounding = new() { Text = "Ground transcription in screen text", AutoSize = true };
    private readonly ComboBox _retention = new() { DropDownStyle = ComboBoxStyle.DropDownList };
    private readonly CheckBox _keepAudio = new() { Text = "Keep audio for successful dictations", AutoSize = true };
    private readonly TextBox _search = new() { PlaceholderText = "Search transcripts, errors, apps" };
    private readonly ComboBox _statusFilter = new() { DropDownStyle = ComboBoxStyle.DropDownList };
    private readonly HistoryQuery _query = new();
    private readonly ListView _history = new()
    {
        View = View.Details,
        FullRowSelect = true,
        Dock = DockStyle.Fill,
    };
    private readonly Label _historySummary = new() { AutoSize = true };
    private readonly ListView _dictionary = new()
    {
        View = View.Details,
        FullRowSelect = true,
        Dock = DockStyle.Fill,
        MultiSelect = false,
    };
    private readonly TextBox _dictionaryEntry = new() { Width = 280 };
    private readonly Label _dictionaryStatus = new() { AutoSize = true, MaximumSize = new Size(540, 0) };
    private readonly CheckBox _learnDictionary = new()
    {
        Text = "Learn spelling corrections I make after dictation",
        AutoSize = true,
    };
    private readonly Action<IReadOnlyList<string>> _dictionaryLearnedHandler;

    private sealed record DictionaryRow(string Term, bool Learned);

    public SettingsForm(AppSettings settings, DictationController controller)
    {
        _settings = settings;
        _controller = controller;
        _dictionaryLearnedHandler = terms =>
        {
            if (IsDisposed) return;
            BeginInvoke(() =>
            {
                RefreshDictionary();
                _dictionaryStatus.Text = "Learned " + string.Join(", ", terms.Select(t => $"“{t}”"))
                    + ". Use the tray menu to undo.";
            });
        };
        _controller.DictionaryLearned += _dictionaryLearnedHandler;
        FormClosed += (_, _) => _controller.DictionaryLearned -= _dictionaryLearnedHandler;

        Text = "DoNotType Settings";
        Icon = AppIcon.Window;
        Size = new Size(660, 620);
        // A floor, as macOS has one. A WinForms TabControl scrolls its tabs rather than hiding
        // them the way an NSToolbar does, so this cannot lose the tab strip outright — but a
        // settings window that can be dragged down to nothing is no more usable for it.
        MinimumSize = new Size(620, 520);
        StartPosition = FormStartPosition.CenterScreen;
        MinimizeBox = false;

        var tabs = new TabControl { Dock = DockStyle.Fill };
        tabs.TabPages.Add(BuildGeneralTab());
        tabs.TabPages.Add(BuildDictionaryTab());
        tabs.TabPages.Add(new FileTranscriptionTab(_settings).Build());
        tabs.TabPages.Add(BuildHistoryTab());
        tabs.TabPages.Add(BuildPromptTab());
        tabs.TabPages.Add(new LogsTab(_settings).Build());
        tabs.TabPages.Add(new SettingsTransferTab(
            _settings, _controller, RefreshAfterSettingsTransfer).Build());
        tabs.TabPages.Add(new AboutTab().Build());
        Controls.Add(tabs);

        // Every size in this file is a pixel count written against Segoe UI 9pt at 96 DPI, and none
        // of them mean anything at another DPI unless the form is told which baseline they were
        // authored against. Left unset, AutoScaleMode stays Inherit and WinForms scales nothing,
        // while the fonts scale regardless because the manifest asks for PerMonitorV2. At 200% that
        // put 31px text inside 23px buttons and a 248px block of wrapped help text inside a 112px
        // panel: the controls were not merely cramped, they were cut through the middle.
        //
        // Assigned last, not with the other form properties at the top. Setting AutoScaleMode scales
        // the form there and then and adopts the result as the new baseline, so doing it before the
        // tabs exist scales an empty form and leaves every child that arrives afterwards at its
        // unscaled size — which looks like a fix on a 96 DPI monitor and changes nothing on any
        // other. A .Designer.cs assigns it before Controls.Add and is still correct, which is not
        // a counter-example: InitializeComponent runs inside SuspendLayout/ResumeLayout, so the
        // scaling pass is deferred to the resume, by which point every child exists. There is no
        // SuspendLayout here, so the assignment is itself the scaling pass and has to come last.
        AutoScaleDimensions = new SizeF(7F, 15F);
        AutoScaleMode = AutoScaleMode.Font;

        LoadValues();
        RefreshDictionary();
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
        layout.Controls.Add(_recommendationNote);
        layout.Controls.Add(_providerNote);
        layout.Controls.Add(Labelled("Model", _model));
        layout.Controls.Add(Labelled("API key", _apiKey));

        var test = new Button { Text = "Test connection", Width = 140 };
        test.Click += async (_, _) => await TestConnectionAsync(test).ConfigureAwait(true);
        layout.Controls.Add(test);
        layout.Controls.Add(_connection);
        layout.Controls.Add(Caption(
            "Calls go straight to the provider with your key. Nothing routes through a server of "
            + "ours; the key is encrypted for your Windows account."));

        // Its own section because it has its own key: the pairing only works when both are
        // configured, and a second key buried under the first one's field is how someone ends up
        // with a fallback that silently never fires.
        layout.Controls.Add(Heading("Fallback"));
        layout.Controls.Add(Labelled("Second service", _fallback));
        layout.Controls.Add(Labelled("Second API key", _fallbackKey));
        layout.Controls.Add(Labelled("Start it after (s)", _fallbackAfter));
        layout.Controls.Add(_fallbackNote);

        layout.Controls.Add(Heading("Dictation"));
        layout.Controls.Add(Labelled("Key", _trigger));
        layout.Controls.Add(Labelled("Behaviour", _mode));
        layout.Controls.Add(Labelled("Cancel shortcut", _cancelShortcut));
        layout.Controls.Add(Labelled("Finish with Enter", _finishAndSend));
        layout.Controls.Add(Labelled("Fidelity", _fidelity));
        layout.Controls.Add(Caption(
            "A quick tap starts recording and a second tap ends it; holding the key past a moment "
            + "records only while held. Escape can cancel recording or transcription, but is "
            + "intercepted only while one is active; choose None to disable it. Press Enter while "
            + "recording to stop and insert; optionally send Enter or Ctrl+Enter afterward. Enter "
            + "remains untouched at all other times. Even Tidy only "
            + "changes typography — none "
            + "of the fidelity settings reword you."));

        // Its own heading, not two more rows under Dictation. "Second key" names the mechanism and
        // never the feature, so somebody looking for rewriting had no reason to read it — and on a
        // fresh install nothing is bound, so the word appeared nowhere in the window at all.
        layout.Controls.Add(Heading("Rewrite"));
        layout.Controls.Add(Labelled("Second key", _secondTrigger));
        layout.Controls.Add(Labelled("It produces", _secondStyle));
        layout.Controls.Add(_secondKeyNote);
        layout.Controls.Add(Caption(
            "Optional. A second key that dictates and then rewrites, so the choice is made before "
            + "you speak rather than from a menu afterwards — there is no mode to leave switched "
            + "on. The verbatim transcript is kept either way and stays in History, so a rewrite "
            + "never loses what you actually said."));
        layout.Controls.Add(Caption(
            "Summaries are not offered here — see the Files tab, which transcribes a recording you "
            + "already have and can summarise it."));

        layout.Controls.Add(Heading("Audio"));
        layout.Controls.Add(Labelled("Microphone", _microphone));
        layout.Controls.Add(_sounds);
        layout.Controls.Add(Caption(
            "The system default follows whatever was plugged in last, so a headset can quietly "
            + "become a monitor's built-in microphone across the room — and the first sign is a "
            + "transcript that is worse than usual. Pinning one stops that. If the pinned device "
            + "is unplugged, recording falls back to the default rather than failing."));

        layout.Controls.Add(Heading("Grounding"));
        layout.Controls.Add(_grounding);
        layout.Controls.Add(Caption(
            "Every regression grounding has produced in the evaluation suite is a number — 1.5 "
            + "becoming 2.5, 4240 becoming 1024 — and unlike a misspelled name a wrong number is "
            + "not recoverable by reading it. This sends a second request that cannot see the "
            + "screen and takes the digits from that one. It costs a second request, so it fires "
            + "by default only where it was measured to matter: when the text around the caret "
            + "already contains numbers (75% substitution there, against 30% elsewhere)."));
        layout.Controls.Add(Caption(
            "Screen text is sent as-is and remains separate from your explicit personal "
            + "dictionary. It may correct spelling, never the words you said."));

        var save = new Button { Text = "Save", Width = 120 };
        save.Click += (_, _) => SaveValues();
        layout.Controls.Add(save);

        // This panel's 18px of bottom padding sits outside its own scrollable extent, so the last
        // control has to carry it or it cannot be scrolled to — 31 of the Save button's 48px stayed
        // below the fold at 200%, with nothing further to scroll. Derived from the padding rather
        // than written on the button, so the two numbers cannot drift apart.
        ScrollReach.MakeBottomReachable(layout);

        page.Controls.Add(layout);
        return page;
    }

    // ---- Dictionary -------------------------------------------------------------------------

    private TabPage BuildDictionaryTab()
    {
        var page = new TabPage("Dictionary");
        _dictionary.Columns.Add("Spelling", 360);
        _dictionary.Columns.Add("Source", 110);

        var header = new FlowLayoutPanel
        {
            Dock = DockStyle.Top,
            Height = 112,
            FlowDirection = FlowDirection.TopDown,
            WrapContents = false,
            Padding = new Padding(12, 10, 12, 0),
        };
        header.Controls.Add(_learnDictionary);
        header.Controls.Add(Caption(
            "Optional. For one minute after an insertion, DoNotType watches only that same "
            + "editable control and learns stable spelling or capitalisation corrections. "
            + "Password fields, additions, deletions, numbers and ordinary rewrites are ignored."));

        var editor = new FlowLayoutPanel
        {
            Dock = DockStyle.Bottom,
            Height = 92,
            Padding = new Padding(12, 8, 12, 0),
            WrapContents = true,
        };
        editor.Controls.Add(_dictionaryEntry);
        var add = new Button { Text = "Add / save", Width = 100 };
        add.Click += (_, _) => SaveDictionaryEntry();
        editor.Controls.Add(add);
        var remove = new Button { Text = "Remove", Width = 90 };
        remove.Click += (_, _) => RemoveDictionaryEntry();
        editor.Controls.Add(remove);
        var import = new Button { Text = "Import CSV…", Width = 100 };
        import.Click += (_, _) => ImportDictionary();
        editor.Controls.Add(import);
        editor.Controls.Add(_dictionaryStatus);

        _dictionary.SelectedIndexChanged += (_, _) =>
        {
            if (SelectedDictionaryRow() is { } row) _dictionaryEntry.Text = row.Term;
        };
        _dictionaryEntry.KeyDown += (_, eventArgs) =>
        {
            if (eventArgs.KeyCode != Keys.Enter) return;
            SaveDictionaryEntry();
            eventArgs.SuppressKeyPress = true;
        };
        _learnDictionary.CheckedChanged += (_, _) =>
        {
            _settings.LearnDictionaryFromEdits = _learnDictionary.Checked;
            _settings.Save();
        };

        page.Controls.Add(_dictionary);
        page.Controls.Add(editor);
        page.Controls.Add(header);
        return page;
    }

    private DictionaryRow? SelectedDictionaryRow() =>
        _dictionary.SelectedItems.Count == 0
            ? null
            : _dictionary.SelectedItems[0].Tag as DictionaryRow;

    private void RefreshDictionary()
    {
        _learnDictionary.Checked = _settings.LearnDictionaryFromEdits;
        _dictionary.BeginUpdate();
        _dictionary.Items.Clear();
        foreach (var term in _settings.DictionaryTerms)
        {
            var row = new DictionaryRow(term, false);
            var item = new ListViewItem(term) { Tag = row };
            item.SubItems.Add("Added");
            _dictionary.Items.Add(item);
        }
        foreach (var term in _settings.LearnedDictionaryTerms)
        {
            var row = new DictionaryRow(term, true);
            var item = new ListViewItem(term) { Tag = row };
            item.SubItems.Add("Learned");
            _dictionary.Items.Add(item);
        }
        _dictionary.EndUpdate();
        _dictionaryStatus.Text = $"{_settings.PersonalDictionaryTerms().Count} of "
            + $"{DoNotType.Core.PersonalDictionary.MaxTerms} entries";
    }

    private void SaveDictionaryEntry()
    {
        try
        {
            var value = DoNotType.Core.PersonalDictionary.Normalize(_dictionaryEntry.Text);
            var selected = SelectedDictionaryRow();
            var allExceptSelected = _settings.PersonalDictionaryTerms()
                .Where(term => selected is null
                    || !term.Equals(selected.Term, StringComparison.OrdinalIgnoreCase))
                .ToList();
            if (allExceptSelected.Contains(value, StringComparer.OrdinalIgnoreCase))
                throw new DoNotType.Core.PersonalDictionary.ValidationException(
                    $"“{value}” is already in the dictionary.");
            if (selected is null && allExceptSelected.Count >= DoNotType.Core.PersonalDictionary.MaxTerms)
                throw new DoNotType.Core.PersonalDictionary.ValidationException(
                    $"The dictionary can contain at most {DoNotType.Core.PersonalDictionary.MaxTerms} entries.");

            if (selected is null) _settings.DictionaryTerms.Add(value);
            else
            {
                var terms = selected.Learned
                    ? _settings.LearnedDictionaryTerms : _settings.DictionaryTerms;
                var index = terms.FindIndex(term => term == selected.Term);
                if (index >= 0) terms[index] = value;
            }
            _settings.Save();
            _dictionaryEntry.Clear();
            RefreshDictionary();
        }
        catch (DoNotType.Core.PersonalDictionary.ValidationException error)
        {
            _dictionaryStatus.Text = error.Message;
        }
    }

    private void RemoveDictionaryEntry()
    {
        if (SelectedDictionaryRow() is not { } row) return;
        var terms = row.Learned ? _settings.LearnedDictionaryTerms : _settings.DictionaryTerms;
        terms.RemoveAll(term => term == row.Term);
        _settings.Save();
        _dictionaryEntry.Clear();
        RefreshDictionary();
    }

    private void ImportDictionary()
    {
        using var dialog = new OpenFileDialog
        {
            Filter = "CSV or text (*.csv;*.txt)|*.csv;*.txt|All files (*.*)|*.*",
            Title = "Import personal dictionary",
        };
        if (dialog.ShowDialog(this) != DialogResult.OK) return;
        try
        {
            var imported = DoNotType.Core.PersonalDictionary.EntriesFromCsv(
                File.ReadAllBytes(dialog.FileName));
            var all = _settings.PersonalDictionaryTerms().ToList();
            var seen = new HashSet<string>(all, StringComparer.OrdinalIgnoreCase);
            var additions = new List<string>();
            foreach (var term in imported)
            {
                if (!seen.Add(term)) continue;
                if (all.Count + additions.Count >= DoNotType.Core.PersonalDictionary.MaxTerms)
                    throw new DoNotType.Core.PersonalDictionary.ValidationException(
                        $"The dictionary can contain at most {DoNotType.Core.PersonalDictionary.MaxTerms} entries.");
                additions.Add(term);
            }
            _settings.DictionaryTerms.AddRange(additions);
            _settings.Save();
            RefreshDictionary();
            _dictionaryStatus.Text = $"Imported {additions.Count} new entries.";
        }
        catch (Exception error) when (error is IOException
                                      or DoNotType.Core.PersonalDictionary.ValidationException)
        {
            _dictionaryStatus.Text = error.Message;
        }
    }

    // ---- History -----------------------------------------------------------------------------

    private TabPage BuildHistoryTab()
    {
        var page = new TabPage("History");

        _history.Columns.Add("When", 110);
        _history.Columns.Add("Status", 80);
        // The wait, per dictation. Shown per row rather than only in aggregate, because "that one
        // felt slow" is a claim the user should be able to check.
        _history.Columns.Add("Wait", 60);
        _history.Columns.Add("Transcript", 320);

        // Search sits above the list because it is the reason history is kept at all.
        var searchBar = new FlowLayoutPanel
        {
            Dock = DockStyle.Top,
            Height = 40,
            Padding = new Padding(10, 6, 10, 0),
        };
        _search.Width = 320;
        _search.TextChanged += (_, _) =>
        {
            _query.Text = _search.Text;
            RefreshHistory();
        };
        searchBar.Controls.Add(_search);

        _statusFilter.Items.AddRange(["All", "Completed", "Needs retry"]);
        _statusFilter.SelectedIndex = 0;
        _statusFilter.Width = 130;
        _statusFilter.SelectedIndexChanged += (_, _) =>
        {
            _query.Status = (HistoryQuery.StatusFilter)_statusFilter.SelectedIndex;
            RefreshHistory();
        };
        searchBar.Controls.Add(_statusFilter);

        // Sized by its contents rather than by a constant. This row wraps, and how many rows it
        // wraps into depends on the font: two at 96 DPI, three once the text is twice the width,
        // at which point any fixed height is wrong by a row no matter what it is scaled by.
        var toolbar = new FlowLayoutPanel
        {
            Dock = DockStyle.Top,
            AutoSize = true,
            AutoSizeMode = AutoSizeMode.GrowAndShrink,
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

        // Per-item retry: double-clicking a failed row reissues just that dictation. Deliberately
        // still only a failed one, though a completed row can now be re-transcribed as well: that
        // row is not broken, a double-click on it is as likely to be exploratory as intended, and
        // every one of these spends a request. The redo asks for itself, from the menu below.
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
        // One item rather than two, renamed for the row it is opened on. The request is identical;
        // what differs is what the user is asking for. On a failed row it is Retry — the words
        // never arrived. On a completed one it is a redo — they arrived wrong, and re-running the
        // transcription is the only fix that does not mean saying it all again.
        var retryOne = new ToolStripMenuItem("Retry this dictation");
        retryOne.Click += async (_, _) =>
        {
            if (SelectedRecord() is not { CanRedo: true } record) return;
            await _controller.RetryAsync(record).ConfigureAwait(true);
            RefreshHistory();
        };

        // The recording is the evidence behind the row: what a wrong transcript should be judged
        // against, and the one thing here that cannot be reconstructed.
        var saveAudioOne = new ToolStripMenuItem("Save the original audio…");
        saveAudioOne.Click += (_, _) => SaveSelectedAudio();
        // The point of the whole grounding argument: if the app reads your screen, you can read
        // what it read. One click from the row it belongs to, rather than a separate screen you
        // have to know exists.
        var inspectOne = new ToolStripMenuItem("Show what was sent…");
        inspectOne.Click += (_, _) =>
        {
            if (SelectedRecord() is not { } record) return;
            using var inspector = new ContextInspectorForm(record);
            inspector.ShowDialog(this);
        };

        var copyOne = new ToolStripMenuItem("Copy transcript");
        copyOne.Click += (_, _) =>
        {
            if (SelectedRecord() is { } record && record.Text.Length > 0) Clipboard.SetText(record.Text);
        };
        rowMenu.Opening += (_, _) =>
        {
            var record = SelectedRecord();
            retryOne.Text = record?.Status == DictationStatus.Completed
                ? "Redo the transcription"
                : "Retry this dictation";
            retryOne.Enabled = record?.CanRedo == true;
            saveAudioOne.Enabled = record?.CanRedo == true;
            copyOne.Enabled = record?.Text.Length > 0;
            deleteOne.Enabled = record is not null;
        };
        rowMenu.Items.AddRange(
            [inspectOne, retryOne, saveAudioOne, copyOne, new ToolStripSeparator(), deleteOne]);
        _history.ContextMenuStrip = rowMenu;

        _history.KeyDown += (_, e) =>
        {
            if (e.KeyCode != Keys.Delete) return;
            DeleteSelected();
            e.Handled = true;
        };

        page.Controls.Add(_history);
        page.Controls.Add(searchBar);
        page.Controls.Add(toolbar);
        return page;
    }

    private DictationRecord? SelectedRecord() =>
        _history.SelectedItems.Count == 0
            ? null
            : _history.SelectedItems[0].Tag as DictationRecord;

    /// <summary>
    /// Writes the selected row's recording somewhere the user chose. A copy rather than a move:
    /// the history keeps its own file, so saving a recording does not cost the ability to redo it.
    /// </summary>
    private void SaveSelectedAudio()
    {
        if (SelectedRecord() is not { CanRedo: true } record) return;

        var wav = _controller.History.AudioFor(record);
        if (wav is null)
        {
            _historySummary.Text = "The recording for this dictation is no longer on disk.";
            return;
        }

        using var dialog = new SaveFileDialog
        {
            FileName = record.AudioExportName,
            Filter = "WAV audio (*.wav)|*.wav",
            DefaultExt = "wav",
            AddExtension = true,
        };
        if (dialog.ShowDialog(this) != DialogResult.OK) return;

        try
        {
            File.WriteAllBytes(dialog.FileName, wav);
            _historySummary.Text = $"Saved {Path.GetFileName(dialog.FileName)}.";
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            // Uncut: the path and the reason are what the user needs to pick a different folder.
            _historySummary.Text = error.Message;
        }
    }

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
        var all = _controller.History.All();
        var records = _query.Apply(all);

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
            item.SubItems.Add(PerformanceStats.FormatDuration(record.LatencySeconds));
            item.SubItems.Add(record.Summary.Replace('\n', ' '));
            if (record.CanRetry) item.ForeColor = Color.Firebrick;
            _history.Items.Add(item);
        }
        _history.EndUpdate();

        var retryable = all.Count(r => r.CanRetry);
        var bytes = _controller.History.AudioBytes();
        var shown = records.Count == all.Count
            ? $"{all.Count} dictations"
            : $"{records.Count} of {all.Count}";
        // Hidden until three successes: a median of two samples is not a median.
        var stats = PerformanceStats.Compute(all);
        var performance = stats.Completed >= 3
            ? $"\r\nTypical wait {PerformanceStats.FormatDuration(stats.MedianLatency)}"
              + $" · slowest 5% {PerformanceStats.FormatDuration(stats.P95Latency)}"
              + $" · {stats.SuccessRate * 100:F0}% succeeded"
              + $" · {PerformanceStats.FormatCount(stats.Words)} words"
            : string.Empty;

        _historySummary.Text =
            $"{shown} · {retryable} to retry · {bytes / 1024} KB audio"
            + "   (double-click to retry · right-click to redo one or save its audio"
            + " · Delete key or right-click to remove)"
            + performance;
    }

    // ---- Prompt ------------------------------------------------------------------------------

    /// <summary>
    /// The contract, editable one part at a time.
    /// </summary>
    /// <remarks>
    /// Exposed because this is open-source software whose entire behaviour is a prompt. One box per
    /// file rather than one box for everything, because the contract is twelve separate
    /// instructions -- and a single buffer holding all of them is how the shipped text and the
    /// documentation about it came to live in the same place, with a marker convention as the only
    /// thing telling them apart.
    ///
    /// The warning is not boilerplate: the measured numbers describe the shipped text and stop
    /// applying to whichever part is edited.
    /// </remarks>
    private TabPage BuildPromptTab()
    {
        var page = new TabPage("Prompt");
        var store = new PromptStore(HistoryStore.DefaultDirectory());
        var bundled = PromptBuilder.FindPromptDirectory();

        var editor = new TextBox
        {
            Multiline = true,
            ScrollBars = ScrollBars.Vertical,
            Dock = DockStyle.Fill,
            Font = new Font(FontFamily.GenericMonospace, 9f),
            WordWrap = false,
        };
        var status = new Label { Dock = DockStyle.Bottom, AutoSize = false, Height = 40 };
        var parts = new ListBox { Dock = DockStyle.Left, Width = 190, IntegralHeight = false };

        if (bundled is null)
        {
            status.Text = "Could not locate the bundled prompt/ directory next to the executable.";
            page.Controls.Add(editor);
            page.Controls.Add(status);
            return page;
        }

        var source = store.Source(bundled);
        PromptPart Selected() => PromptPart.All[Math.Max(parts.SelectedIndex, 0)];

        void RefreshList()
        {
            var keep = parts.SelectedIndex;
            parts.BeginUpdate();
            parts.Items.Clear();
            foreach (var part in PromptPart.All)
            {
                parts.Items.Add(
                    (store.IsCustom(part) ? "• " : "   ") + $"{part.Group[..1]}  {part.Label}");
            }
            parts.SelectedIndex = keep < 0 ? 0 : Math.Min(keep, parts.Items.Count - 1);
            parts.EndUpdate();
        }

        void Load()
        {
            var part = Selected();
            try
            {
                editor.Text = source.EditableTextFor(part).Replace("\n", "\r\n");
                status.Text = $"{part.RelativePath} — {part.SummaryLine} "
                    + "Sent in full: everything in this box reaches the model.";
            }
            catch (Exception error)
            {
                editor.Text = string.Empty;
                status.Text = error.Message;
            }
        }

        parts.SelectedIndexChanged += (_, _) => Load();
        RefreshList();
        Load();

        var toolbar = new FlowLayoutPanel { Dock = DockStyle.Top, Height = 40 };
        var save = new Button { Text = "Save", Width = 100 };
        save.Click += (_, _) =>
        {
            var part = Selected();
            try
            {
                store.Save(editor.Text, part);
                RefreshList();
                status.Text = $"Saved {part.RelativePath}. The measured numbers in the changelog no "
                    + "longer describe this part — re-measure with `dnt-eval suite --prompt`.";
            }
            catch (Exception error)
            {
                status.Text = error.Message;
            }
        };
        // Restores the selected part only. The others keep whatever they are, which is the point of
        // per-part overrides: editing one clause should not pin the whole contract.
        var restore = new Button { Text = "Restore default", Width = 130 };
        restore.Click += (_, _) =>
        {
            var part = Selected();
            store.Restore(part);
            RefreshList();
            Load();
            status.Text = $"Restored the shipped {part.RelativePath}.";
        };
        var restoreAll = new Button { Text = "Restore all", Width = 100 };
        restoreAll.Click += (_, _) =>
        {
            store.RestoreAll();
            RefreshList();
            Load();
            status.Text = "Restored every part to the shipped contract.";
        };
        toolbar.Controls.Add(save);
        toolbar.Controls.Add(restore);
        toolbar.Controls.Add(restoreAll);

        page.Controls.Add(editor);
        page.Controls.Add(parts);
        page.Controls.Add(toolbar);
        page.Controls.Add(status);
        return page;
    }

    /// <summary>
    /// The backend the provider dropdown is pointing at.
    ///
    /// A lookup rather than a cast. The rows used to be in <c>Enum.GetValues</c> order, so
    /// <c>(ProviderKind)SelectedIndex</c> was accidentally correct; putting the recommended two
    /// first breaks that identity, and the failure would have been silent — the wrong backend
    /// described in the note, and the wrong one saved.
    /// </summary>
    private ProviderKind SelectedProvider()
    {
        var index = Math.Max(_provider.SelectedIndex, 0);
        return index < ProviderFactory.PickerOrder.Count
            ? ProviderFactory.PickerOrder[index]
            : ProviderFactory.DefaultForNewInstalls;
    }

    /// <summary>
    /// Whether a backend has a usable key, for the shared rewrite rule.
    /// </summary>
    /// <remarks>
    /// Reads the field for the selected backend rather than the saved setting, so the note and the
    /// controls answer for what is typed in front of the user rather than for what was last saved.
    /// Everything else comes from storage, which is where an unselected backend's key lives.
    /// </remarks>
    private bool HasKeyFor(ProviderKind kind) =>
        kind == SelectedProvider()
            ? !string.IsNullOrWhiteSpace(_apiKey.Text)
            : !string.IsNullOrWhiteSpace(_settings.KeyFor(kind))
                || !string.IsNullOrWhiteSpace(
                    Environment.GetEnvironmentVariable(kind.ApiKeyEnvVar()));

    /// <summary>The fallback choices are every backend except the primary, recommended first.</summary>
    private static List<ProviderKind> FallbackChoices(ProviderKind primary) =>
        ProviderFactory.PickerOrder.Where(k => k != primary).ToList();

    private ProviderKind? SelectedFallback()
    {
        if (_fallback.SelectedIndex <= 0) return null;
        var choices = FallbackChoices(_settings.Provider);
        var index = _fallback.SelectedIndex - 1;
        return index >= 0 && index < choices.Count ? choices[index] : null;
    }

    private int FallbackIndex(ProviderKind? kind)
    {
        if (kind is null) return 0;
        var index = FallbackChoices(_settings.Provider).IndexOf(kind.Value);
        return index < 0 ? 0 : index + 1;
    }

    /// <summary>Says what the selected backend gives up, and hides controls it cannot honour.</summary>
    private void RefreshProviderNotes()
    {
        var fallback = SelectedFallback();
        _fallbackKey.Enabled = fallback is not null;
        _fallbackAfter.Enabled = fallback is not null;
        _fallbackNote.Text = fallback is null
            ? "Off. Worth turning on when the primary is accurate but its latency has a tail — the "
              + "first-party Gemini API answered one three-second clip in 5 s and the next in 61 s. "
              + "The fallback bounds that wait; it does not improve a transcript the primary would "
              + "have got right."
            : $"If {_settings.Provider} has not answered in {(int)_fallbackAfter.Value}s, "
              + $"{fallback} starts alongside it and whichever finishes first is used. History "
              + "records which one served each dictation.";

        // Said here, where the choice is made, rather than found out by holding the key and getting
        // your own words back. Shown whether or not a key is bound: this used to appear only after
        // binding one, which meant the answer to "why can I not rewrite" arrived after the step it
        // was about.
        //
        // From the shared rule rather than asked locally. Windows warned but left the control
        // enabled, macOS never asked, and the mobiles asked a question about the kind of backend
        // rather than about whether one was usable.
        var kind = SelectedProvider();
        var availability = RewriteAvailability.Resolve(kind, HasKeyFor);
        _secondKeyNote.Text = availability.Reason;
        _secondKeyNote.Visible = _secondKeyNote.Text.Length > 0;

        // Disabled rather than hidden. A control that vanishes takes the explanation with it, and
        // "where is it" is a harder question than "why is it off".
        _secondTrigger.Enabled = availability.IsAvailable;
        _secondStyle.Enabled = availability.IsAvailable && _secondTrigger.SelectedIndex > 0;

        // What the choice buys, for the two there is a recommendation for, before what it costs.
        _recommendationNote.Text = kind.RecommendationNote();
        _recommendationNote.Visible = _recommendationNote.Text.Length > 0;

        _providerNote.Text = kind switch
        {
            // Not a capability difference — the gateway forwards audio correctly — but a measured
            // quality one, and the picker is where someone chooses between two entries that look
            // identical.
            ProviderKind.OpenRouter =>
                "Routes through a gateway. The same Gemini model measures worse this way than "
                + "through Gemini directly — 2 to 5 regressions per suite run against 1 — so "
                + "prefer the Gemini service unless you need a model Google does not serve.",
            ProviderKind.Mistral =>
                "Transcription only — this service cannot read your screen, and has no "
                + "spelling-hint channel either. It is the one that handles Mandarin and English "
                + "together.",
            // Louder than a trade-off note: this one predicts lost dictations. Deepgram returned
            // nothing for 44 of 68 Mandarin clips on the dictation corpus.
            ProviderKind.Deepgram =>
                "⚠ Transcription only, and it cannot transcribe Chinese with autodetection — it "
                + "returned nothing for 44 of 68 Mandarin clips. Choose another service if you "
                + "dictate in Chinese.",
            _ when kind.IsSpeechRecognition() =>
                "Transcription only — this service cannot read your screen, and cannot rewrite. "
                + "Fidelity has two settings here rather than three.",
            _ => string.Empty,
        };
        _providerNote.Visible = kind.IsSpeechRecognition();
    }

    /// <summary>
    /// A quarter-second of 16 kHz mono silence, built rather than shipped as a file so the install
    /// does not carry a resource used by one button.
    /// </summary>
    private static byte[] SilentProbeWav()
    {
        const int sampleRate = 16_000;
        var dataBytes = sampleRate / 4 * 2;
        using var stream = new MemoryStream();
        using var writer = new BinaryWriter(stream);

        writer.Write("RIFF"u8.ToArray());
        writer.Write(36 + dataBytes);
        writer.Write("WAVEfmt "u8.ToArray());
        writer.Write(16);
        writer.Write((short)1);
        writer.Write((short)1);
        writer.Write(sampleRate);
        writer.Write(sampleRate * 2);
        writer.Write((short)2);
        writer.Write((short)16);
        writer.Write("data"u8.ToArray());
        writer.Write(dataBytes);
        writer.Write(new byte[dataBytes]);
        writer.Flush();
        return stream.ToArray();
    }

    // ---- Values ------------------------------------------------------------------------------

    private void LoadValues()
    {
        // Picker labels rather than enum names, so the dropdown says what each backend gives up
        // and which two are recommended, instead of leaving both to be discovered. Recommended
        // order, not declaration order — hence the IndexOf below rather than a cast.
        foreach (var kind in ProviderFactory.PickerOrder)
        {
            _provider.Items.Add(kind.PickerLabel());
        }
        // ToList first: PickerOrder is an IReadOnlyList, which has no IndexOf of its own.
        _provider.SelectedIndex = Math.Max(ProviderFactory.PickerOrder.ToList().IndexOf(_settings.Provider), 0);
        _model.Text = _settings.ModelFor(_settings.Provider);
        _apiKey.Text = _settings.KeyFor(_settings.Provider) ?? string.Empty;

        _fallback.Items.Add("None");
        foreach (var kind in FallbackChoices(_settings.Provider))
        {
            _fallback.Items.Add(kind.PickerLabel());
        }
        _fallback.SelectedIndex = FallbackIndex(_settings.ResolvedFallbackProvider());
        _fallbackKey.Text = _settings.ResolvedFallbackProvider() is { } current
            ? _settings.KeyFor(current) ?? string.Empty
            : string.Empty;
        _fallbackAfter.Value = Math.Clamp(_settings.FallbackAfterSeconds, 1, 120);

        // Keys are per provider, so switching reloads rather than carrying one backend's key into
        // another's field.
        _fallback.SelectedIndexChanged += (_, _) =>
        {
            var chosen = SelectedFallback();
            _fallbackKey.Text = chosen is { } kind ? _settings.KeyFor(kind) ?? string.Empty : string.Empty;
            RefreshProviderNotes();
        };

        RefreshProviderNotes();

        // Keys and models are stored per provider; carrying one provider's key into another's
        // field would look like it had been saved.
        _provider.SelectedIndexChanged += (_, _) =>
        {
            var chosen = SelectedProvider();
            _model.Text = _settings.ModelFor(chosen);
            _apiKey.Text = _settings.KeyFor(chosen) ?? string.Empty;
            RefreshProviderNotes();
        };

        // Whether a rewrite can run depends on there being a key, so the section has to unlock as
        // one is typed. Without this it would stay greyed out, explaining that a key is missing,
        // while the user looks at the key they just entered.
        _apiKey.TextChanged += (_, _) => RefreshProviderNotes();

        foreach (var trigger in Enum.GetValues<HotkeyMonitor.Trigger>())
        {
            _trigger.Items.Add(HotkeyMonitor.Label(trigger));
        }
        _trigger.SelectedIndex = (int)_settings.Trigger;

        _cancelShortcut.Items.AddRange(["Escape", "None"]);
        _cancelShortcut.SelectedIndex = (int)_settings.CancelShortcut;

        _finishAndSend.Items.AddRange(["Insert only", "Insert + Enter", "Insert + Ctrl+Enter"]);
        _finishAndSend.SelectedIndex = (int)_settings.FinishAndSendAction;

        _secondTrigger.Items.Add("None");
        foreach (var trigger in Enum.GetValues<HotkeyMonitor.Trigger>())
        {
            _secondTrigger.Items.Add(HotkeyMonitor.Label(trigger));
        }
        _secondTrigger.SelectedIndex =
            _settings.SecondaryTrigger is { } secondary ? (int)secondary + 1 : 0;

        // Verbatim is absent on purpose: it is what the first key already does, and a second key
        // that produces the same thing is a setting with no effect.
        foreach (var style in Enum.GetValues<RewriteStyle>().Where(style => style.IsRewrite()))
        {
            _secondStyle.Items.Add(style.Label());
        }
        _secondStyle.SelectedIndex = Math.Max(0, (int)_settings.SecondaryStyle - 1);
        // Enablement is decided in one place, so a key change and a binding change cannot leave the
        // two controls disagreeing about whether a rewrite is possible.
        _secondTrigger.SelectedIndexChanged += (_, _) => RefreshProviderNotes();

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

        foreach (var device in AudioDevices.Available()) _microphone.Items.Add(device.Name);
        var pinned = _microphone.Items.IndexOf(_settings.MicrophoneName ?? string.Empty);
        // A pinned device that is no longer connected shows as the default rather than as a blank
        // row, which is what actually happens when a recording starts.
        _microphone.SelectedIndex = pinned >= 0 ? pinned : 0;
        _sounds.Checked = _settings.InteractionSounds;

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
        _settings.Provider = SelectedProvider();
        _settings.SetModelFor(_settings.Provider, _model.Text);
        _settings.SetKeyFor(_settings.Provider, _apiKey.Text.Trim());
        _settings.FallbackProvider = SelectedFallback();
        _settings.FallbackAfterSeconds = (int)_fallbackAfter.Value;
        if (SelectedFallback() is { } fallbackKind)
        {
            _settings.SetKeyFor(fallbackKind, _fallbackKey.Text.Trim());
        }
        _model.Text = _settings.ModelFor(_settings.Provider);
        _settings.Trigger = (HotkeyMonitor.Trigger)_trigger.SelectedIndex;
        _settings.CancelShortcut = (CancelShortcut)_cancelShortcut.SelectedIndex;
        _settings.FinishAndSendAction = (FinishAndSendAction)_finishAndSend.SelectedIndex;
        _settings.SecondaryTrigger = _secondTrigger.SelectedIndex > 0
            ? (HotkeyMonitor.Trigger)(_secondTrigger.SelectedIndex - 1)
            : null;
        _settings.SecondaryStyle = (RewriteStyle)(_secondStyle.SelectedIndex + 1);
        _settings.HotkeyMode = _mode.SelectedIndex switch
        {
            1 => HotkeyMonitor.Mode.PushToTalk,
            2 => HotkeyMonitor.Mode.HandsFree,
            _ => HotkeyMonitor.Mode.Automatic,
        };
        _settings.Fidelity = (Fidelity)_fidelity.SelectedIndex;
        _settings.GroundingEnabled = _grounding.Checked;
        // Index 0 is "System default", which is stored as null rather than as its label.
        _settings.MicrophoneName = _microphone.SelectedIndex > 0
            ? _microphone.Items[_microphone.SelectedIndex]?.ToString()
            : null;
        _settings.InteractionSounds = _sounds.Checked;
        _settings.Save();

        _controller.ReloadHotkey();
        _connection.Text = "Saved.";
    }

    private void RefreshAfterSettingsTransfer()
    {
        _provider.SelectedIndex = Math.Max(
            ProviderFactory.PickerOrder.ToList().IndexOf(_settings.Provider), 0);
        _model.Text = _settings.ModelFor(_settings.Provider);
        _apiKey.Text = _settings.KeyFor(_settings.Provider) ?? string.Empty;

        _fallback.Items.Clear();
        _fallback.Items.Add("None");
        foreach (var kind in FallbackChoices(_settings.Provider))
            _fallback.Items.Add(kind.PickerLabel());
        _fallback.SelectedIndex = FallbackIndex(_settings.ResolvedFallbackProvider());
        _fallbackKey.Text = _settings.ResolvedFallbackProvider() is { } fallback
            ? _settings.KeyFor(fallback) ?? string.Empty : string.Empty;
        _fallbackAfter.Value = Math.Clamp(_settings.FallbackAfterSeconds, 1, 120);

        _trigger.SelectedIndex = (int)_settings.Trigger;
        _cancelShortcut.SelectedIndex = (int)_settings.CancelShortcut;
        _finishAndSend.SelectedIndex = (int)_settings.FinishAndSendAction;
        _secondTrigger.SelectedIndex = _settings.SecondaryTrigger is { } secondary
            ? (int)secondary + 1 : 0;
        _secondStyle.SelectedIndex = Math.Max(0, (int)_settings.SecondaryStyle - 1);
        _mode.SelectedIndex = _settings.HotkeyMode switch
        {
            HotkeyMonitor.Mode.PushToTalk => 1,
            HotkeyMonitor.Mode.HandsFree => 2,
            _ => 0,
        };
        _fidelity.SelectedIndex = (int)_settings.Fidelity;
        _grounding.Checked = _settings.GroundingEnabled;
        _sounds.Checked = _settings.InteractionSounds;
        _retention.SelectedIndex = (int)_settings.Retention;
        _keepAudio.Checked = _settings.KeepAudio;
        _controller.ReloadHotkey();
        RefreshProviderNotes();
        RefreshDictionary();
        RefreshHistory();
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
            var kind = (ProviderKind)_provider.SelectedIndex;
            var provider = ProviderFactory.Create(kind, key, _model.Text.Trim());
            // Audio, for every backend — the same shape a dictation sends. Model backends used to
            // get a text round trip, which a text-only relay or checkpoint answers perfectly well
            // before dropping the first real recording. See ProviderProbe.check in the Swift core,
            // which this mirrors.
            IReadOnlyList<InputPart> parts = [new InputPart.Audio(SilentProbeWav(), "audio/wav")];
            try
            {
                await provider.TranscribeAsync("You are a transcription engine.", parts)
                    .ConfigureAwait(true);
            }
            catch (ProviderException empty) when (empty.Message.Contains("no output", StringComparison.OrdinalIgnoreCase))
            {
                // Silence transcribes to nothing, which is the correct answer and proves the
                // round trip worked.
            }
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
