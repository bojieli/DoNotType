using DoNotType.Core;

namespace DoNotType.App;

/// <summary>
/// Transcribe a recording that already exists — a voice memo, a call recording, a file someone
/// sent you.
/// </summary>
/// <remarks>
/// <para>
/// The tray app could only transcribe speech it had just recorded, which left every recording
/// already on disk outside a tool built for turning speech into text. This is the same pipeline
/// entered through a file dialog, sharing <see cref="FileTranscriber"/> with the CLI so the two
/// cannot drift on what a mode means or on which backend runs the second stage.
/// </para>
/// <para>
/// Reads what the other platforms read: WAV in managed code, Opus through libopus, and everything
/// else through Media Foundation. See <see cref="AudioDecoder"/>.
/// </para>
/// </remarks>
internal sealed class FileTranscriptionTab
{
    private readonly AppSettings _settings;
    private readonly TextBox _path = new() { Dock = DockStyle.Fill, ReadOnly = true };
    private readonly ComboBox _mode = new()
    {
        Dock = DockStyle.Fill,
        DropDownStyle = ComboBoxStyle.DropDownList,
    };
    private readonly Label _note = new() { Dock = DockStyle.Fill, AutoSize = false, Height = 34 };
    private readonly Label _status = new() { Dock = DockStyle.Fill, AutoSize = false, Height = 22 };
    private readonly TextBox _result = new()
    {
        Dock = DockStyle.Fill,
        Multiline = true,
        ReadOnly = true,
        ScrollBars = ScrollBars.Vertical,
    };
    private readonly Button _transcribe = new() { Text = "Transcribe", Width = 110 };
    private readonly Button _toggle = new() { Text = "Show what was said", Width = 160, Visible = false };

    private FileTranscriber.Outcome? _outcome;
    private bool _showingVerbatim;
    private bool _running;

    public FileTranscriptionTab(AppSettings settings)
    {
        _settings = settings;
        foreach (var mode in TranscriptMode.All) _mode.Items.Add(mode.Label);
        _mode.SelectedIndex = Math.Max(
            0, TranscriptMode.All.ToList().FindIndex(m => m.Id == settings.FileMode));
        _mode.SelectedIndexChanged += (_, _) =>
        {
            _settings.FileMode = TranscriptMode.All[_mode.SelectedIndex].Id;
            _settings.Save();
            RefreshNote();
        };
    }

    public TabPage Build()
    {
        var page = new TabPage("Recordings");
        var layout = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            ColumnCount = 3,
            Padding = new Padding(12),
        };
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 110));
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 170));

        var choose = new Button { Text = "Choose…", Width = 100 };
        choose.Click += (_, _) => Choose();
        _transcribe.Click += async (_, _) => await RunAsync().ConfigureAwait(true);
        _toggle.Click += (_, _) =>
        {
            _showingVerbatim = !_showingVerbatim;
            RefreshResult();
        };

        layout.Controls.Add(new Label { Text = "Recording", AutoSize = true }, 0, 0);
        layout.Controls.Add(_path, 1, 0);
        layout.Controls.Add(choose, 2, 0);

        layout.Controls.Add(new Label { Text = "Produce", AutoSize = true }, 0, 1);
        layout.Controls.Add(_mode, 1, 1);
        layout.Controls.Add(_transcribe, 2, 1);

        layout.Controls.Add(_note, 1, 2);
        layout.SetColumnSpan(_note, 2);

        layout.Controls.Add(_status, 1, 3);
        layout.Controls.Add(_toggle, 2, 3);

        layout.Controls.Add(_result, 0, 4);
        layout.SetColumnSpan(_result, 3);
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));

        var actions = new FlowLayoutPanel { Dock = DockStyle.Bottom, Height = 36, Padding = new Padding(12, 0, 12, 0) };
        var copy = new Button { Text = "Copy", Width = 90 };
        copy.Click += (_, _) =>
        {
            if (_result.TextLength > 0) Clipboard.SetText(_result.Text);
        };
        var save = new Button { Text = "Save…", Width = 90 };
        save.Click += (_, _) => Save();
        actions.Controls.Add(copy);
        actions.Controls.Add(save);

        page.Controls.Add(layout);
        page.Controls.Add(actions);
        RefreshNote();
        return page;
    }

    private void Choose()
    {
        using var dialog = new OpenFileDialog
        {
            Title = "Choose a recording",
            Filter =
                "Audio (*.wav;*.mp3;*.m4a;*.aac;*.opus;*.ogg;*.wma;*.flac)"
                + "|*.wav;*.mp3;*.m4a;*.aac;*.opus;*.ogg;*.wma;*.flac"
                + "|All files (*.*)|*.*",
        };
        if (dialog.ShowDialog() != DialogResult.OK) return;

        _path.Text = dialog.FileName;
        _outcome = null;
        _result.Clear();
        _status.Text = string.Empty;
        RefreshNote();
    }

    private async Task RunAsync()
    {
        if (_running || _path.TextLength == 0) return;

        var mode = TranscriptMode.All[_mode.SelectedIndex];
        var key = _settings.KeyFor(_settings.Provider);
        if (string.IsNullOrEmpty(key))
        {
            _status.Text = "No API key. Add one on the General tab.";
            return;
        }

        var promptPath = PromptBuilder.FindPromptFile();
        if (promptPath is null)
        {
            _status.Text = "Could not find PROMPT.md beside the app.";
            return;
        }

        var builder = new PromptStore(HistoryStore.DefaultDirectory()).Builder(promptPath);
        var service = new TranscriptionService(
            ProviderFactory.Create(_settings.Provider, key, _settings.Model),
            builder.SystemInstruction(_settings.Fidelity))
        {
            Fidelity = _settings.Fidelity,
            KeytermBiasing = _settings.KeytermBiasing,
        };

        var transcriber = new FileTranscriber(service, builder, _settings.Fidelity, SecondStage(builder));
        if (!transcriber.Supports(mode))
        {
            _status.Text =
                $"{_settings.Provider} only transcribes audio; it cannot produce a {mode.Id}. "
                + "Choose Verbatim, or add a key for a model backend.";
            return;
        }

        _running = true;
        _transcribe.Enabled = false;
        _transcribe.Text = "Transcribing…";
        try
        {
            var outcome = await transcriber.TranscribeAsync(
                    _path.Text, mode,
                    onProgress: progress => _status.BeginInvoke(() =>
                        _status.Text = Describe(progress)))
                .ConfigureAwait(true);

            _outcome = outcome;
            _showingVerbatim = false;
            // Written to history like any other transcript, so it is searchable next to the
            // dictations. The recording stays where the user put it.
            new HistoryStore(HistoryStore.DefaultDirectory()).Insert(outcome.ToRecord(), null);
            _status.Text = Summarise(outcome);
            RefreshResult();
        }
        catch (Exception error) when (error is ProviderException or IOException
                                          or AudioDecoder.DecodeException)
        {
            _status.Text = error.Message;
        }
        finally
        {
            _running = false;
            _transcribe.Enabled = true;
            _transcribe.Text = "Transcribe";
        }
    }

    /// <summary>
    /// A model backend for the second stage, when the chosen one is a recogniser and cannot do
    /// text at all. Picks the first one configured rather than adding a second provider dropdown
    /// to a panel that should be four controls; the status line says which one ran.
    /// </summary>
    private TranscriptionService? SecondStage(PromptBuilder builder)
    {
        if (!_settings.Provider.IsSpeechRecognition()) return null;

        foreach (var kind in Enum.GetValues<ProviderKind>().Where(k => !k.IsSpeechRecognition()))
        {
            var key = _settings.KeyFor(kind);
            if (string.IsNullOrEmpty(key)) continue;
            return new TranscriptionService(
                ProviderFactory.Create(kind, key, _settings.ModelFor(kind)),
                builder.SystemInstruction(_settings.Fidelity));
        }
        return null;
    }

    private void Save()
    {
        if (_outcome is not { } outcome) return;

        using var dialog = new SaveFileDialog
        {
            FileName = Path.GetFileNameWithoutExtension(outcome.SourcePath) + ".txt",
            Filter = "Text (*.txt)|*.txt",
        };
        if (dialog.ShowDialog() != DialogResult.OK) return;

        File.WriteAllText(dialog.FileName, outcome.Delivered);
        // The verbatim transcript goes beside the derived one rather than being replaced by it.
        if (outcome.Mode is not TranscriptMode.VerbatimMode && outcome.Delivered != outcome.Verbatim)
        {
            File.WriteAllText(
                Path.ChangeExtension(dialog.FileName, ".verbatim.txt"), outcome.Verbatim);
            _status.Text = "Saved, with the verbatim transcript beside it.";
        }
        else
        {
            _status.Text = "Saved.";
        }
    }

    private void RefreshNote()
    {
        var mode = TranscriptMode.All[Math.Max(_mode.SelectedIndex, 0)];
        _note.Text = mode.NeedsSecondPass && _settings.Provider.IsSpeechRecognition()
            ? $"{_settings.Provider} only transcribes, so a model backend will write the result in "
                + "a second request. Add a key for one on the General tab if there is none."
            : $"{AudioDecoder.SupportedFormats}. Long recordings are split on silence and sent "
                + "in parallel; the transcript is stored in History like a dictation.";
    }

    private void RefreshResult()
    {
        var derived = _outcome is { } outcome
            && outcome.Mode is not TranscriptMode.VerbatimMode
            && outcome.Delivered != outcome.Verbatim;

        // The verbatim transcript is always kept, so it is always one click away — for a summary it
        // is the only way to see what was dropped.
        _toggle.Visible = derived;
        _toggle.Text = _showingVerbatim ? "Show the result" : "Show what was said";
        _result.Text = _outcome is null
            ? string.Empty
            : (_showingVerbatim ? _outcome.Verbatim : _outcome.Delivered);
    }

    private static string Describe(FileTranscriber.Progress progress) => progress switch
    {
        FileTranscriber.Progress.Decoding => "Reading the file…",
        FileTranscriber.Progress.Transcribing chunk =>
            chunk.Of > 1 ? $"Transcribing part {chunk.Done} of {chunk.Of}…" : "Transcribing…",
        FileTranscriber.Progress.Deriving deriving => deriving.Mode.ProgressLabel,
        _ => string.Empty,
    };

    private static string Summarise(FileTranscriber.Outcome outcome)
    {
        var parts = new List<string>();
        if (outcome.DurationSeconds > 0)
        {
            parts.Add(
                $"{PerformanceStats.FormatDuration(outcome.DurationSeconds)} of audio in "
                + PerformanceStats.FormatDuration(outcome.TotalSeconds));
        }
        if (outcome.ChunkCount > 1) parts.Add($"{outcome.ChunkCount} parts");
        if (outcome.SecondStageProvider is { } second) parts.Add($"{second} wrote the result");
        return string.Join(" · ", parts);
    }
}
