using System.Windows.Forms;
using DoNotType.Core;

namespace DoNotType.App;

/// <summary>
/// Tray application. Windows has no menu bar, so the notification area is the equivalent home for
/// a tool that lives in the background and is summoned by a key.
/// </summary>
internal static class Program
{
    [STAThread]
    private static void Main()
    {
        ApplicationConfiguration.Initialize();
        using var context = new TrayApplication();
        Application.Run(context);
        // The file sink appends through the filesystem; flushing on the way out means the last few
        // lines before a quit — usually the interesting ones — actually reach the disk.
        LogRouter.Flush();
    }
}

internal sealed class TrayApplication : ApplicationContext
{
    private readonly AppSettings _settings = AppSettings.Load();
    private readonly NotifyIcon _tray;
    private readonly DictationController _controller;
    private readonly RecordingOverlay _overlay = new();
    private readonly System.Windows.Forms.Timer _levelTimer = new() { Interval = 33 };

    private SettingsForm? _settingsForm;

    public TrayApplication()
    {
        // Before anything else can log, and before the first request can carry a key.
        _settings.StartLogging();

        MigrateLegacyPrompt();

        _controller = new DictationController(_settings);
        _controller.StateChanged += OnStateChanged;
        // Only when there is more than one part. A single-chunk dictation is the ordinary case, and
        // "part 1 of 1" underneath a label that already says Transcribing is noise.
        _controller.ChunkProgress += (done, total) => _overlay.BeginInvoke(() =>
        {
            var progress = total > 1 ? $"part {Math.Min(done + 1, total)} of {total}" : null;
            if (_controller.WillSubmit) progress = JoinHint(progress, "will send");
            _overlay.SetPhase(RecordingOverlay.Phase.Transcribing, progress);
        });
        _controller.HistoryChanged += () => BeginInvokeOnTray(RebuildMenu);
        _controller.DictionaryLearned += terms => BeginInvokeOnTray(() =>
        {
            RebuildMenu();
            var shown = string.Join(", ", terms.Select(term => $"“{term}”"));
            _overlay.Show(RecordingOverlay.Phase.Inserted, $"Learned {shown} — undo from tray");
            _ = HideOverlayAfter(TimeSpan.FromSeconds(3.5));
        });
        _controller.Undone += message => BeginInvokeOnTray(() =>
        {
            _overlay.Show(RecordingOverlay.Phase.Inserted, message);
            _ = HideOverlayAfter(TimeSpan.FromSeconds(1.4));
        });
        _controller.Inserted += insertion => BeginInvokeOnTray(() =>
        {
            var plural = insertion.Characters == 1 ? string.Empty : "s";
            var suffix = insertion.RewriteFailed ? " — not rewritten" : string.Empty;
            var message = insertion.Submission switch
            {
                DictationController.Submission.Sent =>
                    $"Inserted {insertion.Characters} character{plural} and sent",
                DictationController.Submission.SkippedFocusMoved =>
                    $"Inserted {insertion.Characters} character{plural} — not sent; focus moved",
                DictationController.Submission.SkippedUnavailable =>
                    $"Inserted {insertion.Characters} character{plural} — not sent; key unavailable",
                _ => $"Inserted {insertion.Characters} character{plural}",
            };
            _overlay.Show(
                RecordingOverlay.Phase.Inserted,
                message + suffix);
            // Longer when there is something to read, which a confirmation otherwise is not.
            var needsReading = insertion.RewriteFailed
                || insertion.Submission is DictationController.Submission.SkippedFocusMoved
                    or DictationController.Submission.SkippedUnavailable;
            _ = HideOverlayAfter(TimeSpan.FromSeconds(needsReading ? 3.5 : 1.6));
        });

        _tray = new NotifyIcon
        {
            Icon = AppIcon.Small,
            Visible = true,
            Text = "DoNotType",
        };
        _tray.DoubleClick += (_, _) => OpenSettings();
        RebuildMenu();

        _levelTimer.Tick += (_, _) => _overlay.AppendLevels(_controller.DrainLevels());

        StartUp();
    }

    /// <summary>
    /// Splits a pre-split PROMPT.md override into part files, once, before the first dictation.
    /// </summary>
    /// <remarks>
    /// Logged rather than shown: nothing here is worth a modal at launch, and the parts it wrote
    /// are visible in the Prompt tab anyway. A failure means the user gets the shipped contract,
    /// which is what would have happened before.
    /// </remarks>
    private static void MigrateLegacyPrompt()
    {
        var bundled = PromptBuilder.FindPromptDirectory();
        if (bundled is null) return;

        try
        {
            var store = new PromptStore(HistoryStore.DefaultDirectory());
            if (store.MigrateLegacyPrompt(bundled) is not { } migration) return;

            new Log("prompt").Info(() => "split the single-file prompt", new Dictionary<string, string>
            {
                ["parts"] = migration.Migrated.Count == 0
                    ? "none — the copy matched the shipped contract"
                    : string.Join(", ", migration.Migrated.Select(p => p.RelativePath)),
                ["archived"] = migration.ArchivedAt,
            });
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            new Log("prompt").Warn(() => $"could not split the old prompt: {error.Message}");
        }
    }

    private void StartUp()
    {
        // Windows has no Accessibility permission to request — UI Automation works without one —
        // so the only gate is the microphone, and that surfaces when recording is attempted.
        if (!_controller.Start())
        {
            MessageBox.Show(
                "Could not install the global hotkey. Another tool may already own it, or the "
                + "app may need to run at the same privilege level as the window you dictate into.",
                "DoNotType", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }

        if (string.IsNullOrEmpty(_settings.ResolvedApiKey()))
        {
            OpenSettings();
            return;
        }

        // Anything that failed while the machine was offline goes out now.
        _ = _controller.RetryAllAsync();
    }

    private void OnStateChanged(DictationController.State state)
    {
        BeginInvokeOnTray(() =>
        {
            switch (state)
            {
                case DictationController.State.Recording:
                    _overlay.Show(RecordingOverlay.Phase.Recording, HintForMode());
                    _levelTimer.Start();
                    break;
                case DictationController.State.Transcribing:
                    _levelTimer.Stop();
                    _overlay.SetPhase(
                        RecordingOverlay.Phase.Transcribing,
                        _controller.WillSubmit ? "will send" : string.Empty);
                    break;
                case DictationController.State.Deriving:
                    // The style's own word — "Tightening…", "Making bullets…" — because somebody
                    // who held the second key is waiting for that specific thing.
                    _levelTimer.Stop();
                    _overlay.SetPhase(
                        RecordingOverlay.Phase.Deriving,
                        JoinHint(
                            TranscriptMode.Rewrite(_settings.SecondaryStyle).ProgressLabel,
                            _controller.WillSubmit ? "will send" : null));
                    break;
                case DictationController.State.Failed:
                    _levelTimer.Stop();
                    // Not truncated: the overlay grows to fit, because the advice is a sentence
                    // about what to do and half of one is worse than none. It also stays up longer
                    // than a confirmation does — there is something to read.
                    _overlay.SetPhase(
                        RecordingOverlay.Phase.Failed, _controller.LastError ?? "Failed");
                    _ = HideOverlayAfter(TimeSpan.FromSeconds(7));
                    break;
                default:
                    _levelTimer.Stop();
                    _overlay.Hide();
                    break;
            }
            RebuildMenu();
        });
    }

    private string HintForMode()
    {
        var ordinary = _settings.HotkeyMode switch
        {
            HotkeyMonitor.Mode.PushToTalk => "Release to send",
            HotkeyMonitor.Mode.HandsFree => "Tap again to send",
            _ => "Release or tap to send",
        };
        return _settings.FinishAndSendAction == FinishAndSendAction.Disabled
            ? ordinary : ordinary + " · Enter to send";
    }

    private static string JoinHint(string? first, string? second) =>
        string.Join(" · ", new[] { first, second }.Where(value => !string.IsNullOrEmpty(value)));

    private async Task HideOverlayAfter(TimeSpan delay)
    {
        await Task.Delay(delay).ConfigureAwait(true);
        if (_controller.Current != DictationController.State.Recording) _overlay.Hide();
    }

    private void RebuildMenu()
    {
        var menu = new ContextMenuStrip();

        var status = _controller.Current switch
        {
            DictationController.State.Recording => "Recording… release to transcribe",
            DictationController.State.Transcribing => "Transcribing…",
            DictationController.State.Deriving =>
                TranscriptMode.Rewrite(_settings.SecondaryStyle).ProgressLabel,
            DictationController.State.Failed => Truncate(_controller.LastError ?? "Failed", 60),
            _ => $"Hold {HotkeyMonitor.Label(_settings.Trigger)} to dictate",
        };
        menu.Items.Add(new ToolStripMenuItem(status) { Enabled = false });

        // A menu item cannot hold a response body, so the label is cut — but the whole failure has
        // to be reachable from somewhere, and the tray is where somebody looks after the overlay
        // has gone. This copies the status, the body and the exception type, uncut.
        var lastFailure = _controller.History.All()
            .FirstOrDefault(r => r.Status == DictationStatus.Failed);
        if (lastFailure is not null)
        {
            var copyError = new ToolStripMenuItem("Copy the last error");
            copyError.Click += (_, _) => Clipboard.SetText(
                $"{lastFailure.CreatedAt:O} [{lastFailure.Status}] "
                + $"{lastFailure.Model}: {lastFailure.ErrorMessage}"
                + (lastFailure.ErrorDetail is { } detail ? $"\n\n{detail}" : string.Empty));
            menu.Items.Add(copyError);
        }

        var retryable = _controller.History.Retryable().Count;
        if (retryable > 0)
        {
            menu.Items.Add(new ToolStripSeparator());
            var retry = new ToolStripMenuItem($"Retry {retryable} failed dictation" + (retryable == 1 ? "" : "s"));
            retry.Click += async (_, _) =>
            {
                await _controller.RetryAllAsync().ConfigureAwait(true);
                RebuildMenu();
            };
            menu.Items.Add(retry);
        }

        var latest = _controller.History.All().FirstOrDefault(r => r.Status == DictationStatus.Completed);
        if (latest is not null)
        {
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add(new ToolStripMenuItem(Truncate(latest.Text, 60)) { Enabled = false });
            var copy = new ToolStripMenuItem("Copy last transcript");
            copy.Click += (_, _) => Clipboard.SetText(latest.Text);
            menu.Items.Add(copy);
        }

        if (_controller.CanUndoDictionaryLearning)
        {
            menu.Items.Add(new ToolStripSeparator());
            var undoLearning = new ToolStripMenuItem("Undo last dictionary learning");
            undoLearning.Click += (_, _) =>
            {
                _controller.UndoLastDictionaryLearning();
                RebuildMenu();
                _overlay.Show(RecordingOverlay.Phase.Inserted, "Removed learned spelling");
                _ = HideOverlayAfter(TimeSpan.FromSeconds(1.6));
            };
            menu.Items.Add(undoLearning);
        }

        menu.Items.Add(new ToolStripSeparator());
        var settings = new ToolStripMenuItem("Settings…");
        settings.Click += (_, _) => OpenSettings();
        menu.Items.Add(settings);

        var quit = new ToolStripMenuItem("Quit DoNotType");
        quit.Click += (_, _) => ExitThread();
        menu.Items.Add(quit);

        _tray.ContextMenuStrip = menu;
    }

    private void OpenSettings()
    {
        if (_settingsForm is { IsDisposed: false })
        {
            _settingsForm.Activate();
            return;
        }
        _settingsForm = new SettingsForm(_settings, _controller);
        _settingsForm.FormClosed += (_, _) => _settingsForm = null;
        _settingsForm.Show();
    }

    /// <summary>
    /// The controller raises events from the hook and from background tasks; WinForms state must
    /// only be touched on the UI thread.
    /// </summary>
    private void BeginInvokeOnTray(Action action)
    {
        if (_overlay.IsHandleCreated && _overlay.InvokeRequired) _overlay.BeginInvoke(action);
        else action();
    }

    private static string Truncate(string value, int max) =>
        value.Length <= max ? value : value[..max] + "…";

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _levelTimer.Dispose();
            _tray.Visible = false;
            _tray.Dispose();
            _controller.Dispose();
            _overlay.Dispose();
        }
        base.Dispose(disposing);
    }
}
