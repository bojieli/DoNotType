using System.Runtime.InteropServices;

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

    /// <summary>A press shorter than this counts as a tap.</summary>
    public static readonly TimeSpan HoldThreshold = TimeSpan.FromMilliseconds(250);

    public Mode RecordingMode { get; set; } = Mode.Automatic;
    public Trigger Key { get; set; } = Trigger.RightControl;

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
    public event Action? Cancelled;

    /// <summary>Ctrl+Shift+Z — take the last insertion back out of the field.</summary>
    public event Action? UndoRequested;

    /// <summary>Ctrl+Alt+Z — swap a rewrite for the words that were actually said.</summary>
    public event Action? RevertToVerbatimRequested;

    /// <summary>Ctrl+Alt+V — put the last transcript in again, for when it landed in the wrong window.</summary>
    public event Action? RepasteRequested;

    /// <summary>Set by the owner so tap-toggle knows whether a tap should start or stop.</summary>
    public Func<bool> IsRecording { get; set; } = () => false;

    private readonly Interop.LowLevelKeyboardProc _callback;
    private IntPtr _hook;
    private bool _isHeld;
    private DateTime _pressedAt;
    private bool _startedByTap;

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
        if (nCode < 0) return Interop.CallNextHookEx(_hook, nCode, wParam, lParam);

        var info = Marshal.PtrToStructure<Interop.KBDLLHOOKSTRUCT>(lParam);
        var message = (int)wParam;
        var isDown = message is Interop.WM_KEYDOWN or Interop.WM_SYSKEYDOWN;
        var isUp = message is Interop.WM_KEYUP or Interop.WM_SYSKEYUP;

        var isSecondary = SecondaryKey is { } secondary && info.vkCode == VirtualKey(secondary);
        if (info.vkCode == VirtualKey(Key) || isSecondary)
        {
            if (isDown && !_isHeld)
            {
                _isHeld = true;
                // Read once, at the press. Releasing a different key than the one held would
                // otherwise change what the finished recording becomes.
                UsedSecondary = isSecondary;
                HandlePress();
            }
            else if (isUp && _isHeld)
            {
                _isHeld = false;
                HandleRelease();
            }
        }
        else if (isDown && info.vkCode == 0x1B && IsRecording())
        {
            // Escape aborts a recording in flight without inserting anything.
            Cancelled?.Invoke();
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
            else if (ctrl && alt && info.vkCode == Interop.VK_V)
            {
                RepasteRequested?.Invoke();
            }
        }

        // Never swallow the key: the trigger keeps working as an ordinary modifier.
        return Interop.CallNextHookEx(_hook, nCode, wParam, lParam);
    }

    private void HandlePress()
    {
        _pressedAt = DateTime.UtcNow;
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

    private void HandleRelease()
    {
        var held = DateTime.UtcNow - _pressedAt;
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
