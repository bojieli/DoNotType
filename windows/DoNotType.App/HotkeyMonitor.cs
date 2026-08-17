using System.Runtime.InteropServices;
using DoNotType.Core;

namespace DoNotType.App;

/// <summary>
/// Global push-to-talk key, via a low-level keyboard hook.
///
/// <c>RegisterHotKey</c> is the obvious API and the wrong one here: it reports presses but not
/// releases, so push-to-talk would never learn when to stop. <c>WH_KEYBOARD_LL</c> sees both
/// edges, at the cost of a hook that must never block — the callback does nothing but raise an
/// event and return.
/// </summary>
public sealed class HotkeyMonitor : IDisposable
{
    /// <summary>
    /// How holding the key relates to recording.
    ///
    /// <see cref="Automatic"/> is the default because it needs no decision from the user: a quick
    /// tap starts a recording that a second tap ends, and anything held past the threshold behaves
    /// as push-to-talk.
    /// </summary>
    public enum Mode
    {
        PushToTalk,
        HandsFree,
        Automatic,
    }

    public enum Trigger
    {
        RightControl,
        RightAlt,
        RightShift,
        CapsLock,
        F13,
    }

    /// <summary>A press shorter than this counts as a tap, and a tap leaves the recording on.</summary>
    /// <remarks>
    /// It is <see cref="AudioRecorder.MinimumDuration"/> exactly, and the two are the same number
    /// on purpose: a release may only end a recording the recorder would accept. While this was
    /// the shorter 250 ms it read as the more comfortable choice, but it opened a 250 ms window
    /// where a press was long enough to be called a hold and too short to survive
    /// <see cref="AudioRecorder.MinimumDuration"/>. A press landing in it stopped the recording and
    /// then threw it away, so the gesture that felt most like a tap was the one guaranteed to
    /// produce nothing. Nobody says anything in under half a second, so every press that used to
    /// send still sends; what changes is that a press between the two lengths now leaves the
    /// recording running with the overlay up saying so, instead of discarding it in silence.
    /// </remarks>
    public static readonly TimeSpan HoldThreshold = AudioRecorder.MinimumDuration;

    public Mode RecordingMode { get; set; } = Mode.Automatic;
    public Trigger Key { get; set; } = Trigger.RightControl;
    public CancelShortcut CancelKey { get; set; } = CancelShortcut.Escape;
    public FinishAndSendAction FinishAndSendKey { get; set; } = FinishAndSendAction.Disabled;

    /// <summary>
    /// A second key that dictates and then rewrites, or null when there is only one.
    /// </summary>
    /// <remarks>
    /// The whole design of the rewrite is that the choice is made *before* speaking, by which key
    /// you hold. Choosing afterwards would mean either a menu between speaking and the text
    /// appearing, or a setting somebody has to remember they changed — and the point of dictation
    /// is that the gap between thinking and text is short.
    /// </remarks>
    public Trigger? SecondaryKey { get; set; }

    /// <summary>Whether the press in flight came from <see cref="SecondaryKey"/>.</summary>
    public bool UsedSecondary { get; private set; }

    public event Action? Pressed;
    public event Action? Released;
    /// <summary>
    /// Reports the physical trigger state so automatic mode can show one exact finishing gesture.
    /// </summary>
    public event Action<bool>? HoldChanged;
    public event Action? Cancelled;
    public event Action<FinishAndSendAction>? FinishWithEnterRequested;
    /// <summary>An event subscriber failed while running inside the native keyboard callback.</summary>
    public event Action<string>? Faulted;

    /// <summary>Ctrl+Shift+Z — take the last insertion back out of the field.</summary>
    public event Action? UndoRequested;

    /// <summary>Ctrl+Alt+Z — swap a rewrite for the words that were actually said.</summary>
    public event Action? RevertToVerbatimRequested;

    /// <summary>Set by the owner so tap-toggle knows whether a tap should start or stop.</summary>
    public Func<bool> IsRecording { get; set; } = () => false;

    /// <summary>True during capture, recognition, and the optional rewrite.</summary>
    public Func<bool> IsDictationActive { get; set; } = () => false;

    private readonly Interop.LowLevelKeyboardProc _callback;
    private IntPtr _hook;
    public bool IsHeld { get; private set; }
    /// <summary>The press's own event time, not the moment the hook got to it. See HandleRelease.</summary>
    private uint _pressedAt;
    private bool _startedByTap;
    /// <summary>Consumes key-up even though key-down cancellation may already have returned idle.</summary>
    private bool _isCancellingWithEscape;
    /// <summary>Consumes key-up after key-down has already moved recording to transcription.</summary>
    private bool _isFinishingWithEnter;

    private static readonly Log HotkeyLog = new("hotkey");

    public HotkeyMonitor()
    {
        // Kept in a field: a delegate passed to SetWindowsHookEx must outlive the call, and a
        // collected one crashes the process from native code.
        _callback = HookCallback;
    }

    public static uint VirtualKey(Trigger trigger) => trigger switch
    {
        Trigger.RightControl => 0xA3,  // VK_RCONTROL
        Trigger.RightAlt => 0xA5,      // VK_RMENU
        Trigger.RightShift => 0xA1,    // VK_RSHIFT
        Trigger.CapsLock => 0x14,      // VK_CAPITAL
        _ => 0x7C,                     // VK_F13
    };

    public static string Label(Trigger trigger) => trigger switch
    {
        Trigger.RightControl => "Right Ctrl",
        Trigger.RightAlt => "Right Alt",
        Trigger.RightShift => "Right Shift",
        Trigger.CapsLock => "Caps Lock",
        _ => "F13",
    };

    public bool Start()
    {
        if (_hook != IntPtr.Zero) return true;
        _hook = Interop.SetWindowsHookExW(
            Interop.WH_KEYBOARD_LL, _callback, Interop.GetModuleHandleW(null), 0);
        return _hook != IntPtr.Zero;
    }

    public void Stop()
    {
        if (_hook == IntPtr.Zero) return;
        Interop.UnhookWindowsHookEx(_hook);
        _hook = IntPtr.Zero;
    }

    public void Dispose() => Stop();

    private IntPtr HookCallback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        try
        {
            return HookCallbackCore(nCode, wParam, lParam);
        }
        catch (Exception error)
        {
            // A managed exception crossing a native hook delegate can terminate the process. It
            // also leaves the held-key flags latched, so reset them before reporting the failure.
            IsHeld = false;
            _isCancellingWithEscape = false;
            _isFinishingWithEnter = false;
            try
            {
                HotkeyLog.Error(
                    () => "keyboard hook callback failed",
                    new Dictionary<string, string>
                    {
                        ["type"] = error.GetType().Name,
                        ["detail"] = error.Message,
                    });
                Faulted?.Invoke("The dictation hotkey failed. Try again; details are in Logs.");
            }
            catch
            {
                // This catch is the final managed boundary before Windows regains control.
            }
            return Interop.CallNextHookEx(_hook, nCode, wParam, lParam);
        }
    }

    private IntPtr HookCallbackCore(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode < 0) return Interop.CallNextHookEx(_hook, nCode, wParam, lParam);

        var info = Marshal.PtrToStructure<Interop.KBDLLHOOKSTRUCT>(lParam);
        // Our own paste and submit keystrokes must never become recording controls, including if a
        // user starts the next recording while the previous paste is settling.
        if ((info.flags & Interop.LLKHF_INJECTED) != 0)
            return Interop.CallNextHookEx(_hook, nCode, wParam, lParam);
        var message = (int)wParam;
        var isDown = message is Interop.WM_KEYDOWN or Interop.WM_SYSKEYDOWN;
        var isUp = message is Interop.WM_KEYUP or Interop.WM_SYSKEYUP;

        if (info.vkCode == Interop.VK_RETURN)
        {
            if (isUp && _isFinishingWithEnter)
            {
                _isFinishingWithEnter = false;
                return (IntPtr)1;
            }
            if (isDown && _isFinishingWithEnter)
            {
                // Auto-repeat remains captured without finishing the same recording twice.
                return (IntPtr)1;
            }
            if (isDown && FinishAndSendActionPolicy.CapturesEnter(FinishAndSendKey, IsRecording()))
            {
                _isFinishingWithEnter = true;
                FinishWithEnterRequested?.Invoke(FinishAndSendKey);
                return (IntPtr)1;
            }
        }

        if (info.vkCode == 0x1B) // VK_ESCAPE
        {
            if (isUp && _isCancellingWithEscape)
            {
                _isCancellingWithEscape = false;
                return (IntPtr)1;
            }
            if (isDown && _isCancellingWithEscape)
            {
                // Auto-repeat stays captured, but only the first key-down raises cancellation.
                return (IntPtr)1;
            }
            if (isDown && CancelShortcutPolicy.CapturesEscape(CancelKey, IsDictationActive()))
            {
                _isCancellingWithEscape = true;
                Cancelled?.Invoke();
                return (IntPtr)1;
            }
        }

        var isSecondary = SecondaryKey is { } secondary && info.vkCode == VirtualKey(secondary);
        if (info.vkCode == VirtualKey(Key) || isSecondary)
        {
            if (isDown && !IsHeld)
            {
                IsHeld = true;
                HoldChanged?.Invoke(true);
                // Read once, at the press. Releasing a different key than the one held would
                // otherwise change what the finished recording becomes.
                UsedSecondary = isSecondary;
                HandlePress(info.time);
            }
            else if (isUp && IsHeld)
            {
                IsHeld = false;
                HoldChanged?.Invoke(false);
                HandleRelease(info.time);
            }
        }
        else if (isDown)
        {
            // Chords, checked against the modifiers held right now. GetAsyncKeyState rather than a
            // tracked flag: this hook does not see keys pressed before it was installed, and a
            // modifier held from before would otherwise read as up.
            var ctrl = (Interop.GetAsyncKeyState(Interop.VK_CONTROL) & 0x8000) != 0;
            var shift = (Interop.GetAsyncKeyState(Interop.VK_SHIFT) & 0x8000) != 0;
            var alt = (Interop.GetAsyncKeyState(Interop.VK_MENU) & 0x8000) != 0;

            if (ctrl && info.vkCode == Interop.VK_Z)
            {
                // Ctrl+Shift+Z takes the last insertion back; Ctrl+Alt+Z swaps a rewrite for what
                // was actually said. Deliberately not Ctrl+Z, which belongs to the app being typed
                // into and would be stolen from every text field on the system.
                if (shift) { UndoRequested?.Invoke(); }
                else if (alt) { RevertToVerbatimRequested?.Invoke(); }
            }
        }

        // Every event except an active, configured recording-only key is passed through unchanged.
        return Interop.CallNextHookEx(_hook, nCode, wParam, lParam);
    }

    private void HandlePress(uint stamp)
    {
        _pressedAt = stamp;
        switch (RecordingMode)
        {
            case Mode.PushToTalk:
                Pressed?.Invoke();
                break;
            case Mode.HandsFree:
                if (IsRecording()) Released?.Invoke(); else Pressed?.Invoke();
                break;
            default:
                // Start immediately either way: waiting to classify the gesture would clip the
                // first word off every push-to-talk dictation.
                if (IsRecording())
                {
                    _startedByTap = false;
                }
                else
                {
                    _startedByTap = true;
                    Pressed?.Invoke();
                }
                break;
        }
    }

    /// <summary>
    /// Ends the gesture, timed by the events' own clock rather than by when this hook got to them.
    /// </summary>
    /// <remarks>
    /// HandlePress calls straight into the recorder, and the first dictation of a run pays the
    /// audio stack's cold start there. That happens inside the hook, so the release message waits
    /// behind it. Timed with the wall clock at handling time, a 40 ms tap measured as a 300 ms hold
    /// and stopped the recording it had just started, which is how the macOS build lost the first
    /// press of every launch to a recording too short to send. KBDLLHOOKSTRUCT.time is stamped when
    /// the key physically moved, so it describes the gesture rather than how busy the hook was.
    /// Blocking here is worse than on macOS: Windows drops a hook that overruns LowLevelHooksTimeout.
    /// </remarks>
    private void HandleRelease(uint stamp)
    {
        // Unchecked because the tick count wraps roughly every 49 days, and the wrapped difference
        // is still the right one.
        var held = TimeSpan.FromMilliseconds(unchecked(stamp - _pressedAt));
        switch (RecordingMode)
        {
            case Mode.PushToTalk:
                Released?.Invoke();
                break;
            case Mode.HandsFree:
                break; // toggling already happened on press
            default:
                if (!_startedByTap) Released?.Invoke();
                else if (held >= HoldThreshold) Released?.Invoke();
                // Otherwise it was a tap: recording continues until the next press.
                break;
        }
    }
}
