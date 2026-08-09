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
        _controller = new DictationController(_settings);
        _controller.StateChanged += OnStateChanged;
        _controller.HistoryChanged += () => BeginInvokeOnTray(RebuildMenu);

        _tray = new NotifyIcon
        {
            Icon = SystemIcons.Application,
            Visible = true,
            Text = "DoNotType",
        };
        _tray.DoubleClick += (_, _) => OpenSettings();
        RebuildMenu();

        _levelTimer.Tick += (_, _) => _overlay.UpdateLevel(_controller.Level);

        StartUp();
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
                    _overlay.SetPhase(RecordingOverlay.Phase.Transcribing, string.Empty);
                    break;
                case DictationController.State.Failed:
                    _levelTimer.Stop();
                    _overlay.SetPhase(
                        RecordingOverlay.Phase.Failed, Truncate(_controller.LastError ?? "Failed", 48));
                    _ = HideOverlayAfter(TimeSpan.FromSeconds(4));
                    break;
                default:
                    _levelTimer.Stop();
                    _overlay.Hide();
                    break;
            }
            RebuildMenu();
        });
    }

    private string HintForMode() => _settings.HotkeyMode switch
    {
        HotkeyMonitor.Mode.PushToTalk => "Release to send",
        HotkeyMonitor.Mode.HandsFree => "Tap again to send",
        _ => "Release or tap to send",
    };

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
            DictationController.State.Failed => Truncate(_controller.LastError ?? "Failed", 60),
            _ => $"Hold {HotkeyMonitor.Label(_settings.Trigger)} to dictate",
        };
        menu.Items.Add(new ToolStripMenuItem(status) { Enabled = false });

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
