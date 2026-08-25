using System.Runtime.InteropServices;
using System.Text;

namespace DoNotType.App;

/// <summary>
/// Win32 entry points. Grouped in one file so the P/Invoke surface is auditable at a glance.
/// </summary>
internal static partial class Interop
{
    // ---- Low-level keyboard hook -------------------------------------------------------------
    //
    // RegisterHotKey is the obvious choice and the wrong one: it reports presses, not releases,
    // so push-to-talk cannot know when to stop. WH_KEYBOARD_LL sees both edges.

    internal const int WH_KEYBOARD_LL = 13;
    internal const int WM_KEYDOWN = 0x0100;
    internal const int WM_KEYUP = 0x0101;
    internal const int WM_SYSKEYDOWN = 0x0104;
    internal const int WM_SYSKEYUP = 0x0105;
    internal const uint LLKHF_INJECTED = 0x00000010;

    internal delegate IntPtr LowLevelKeyboardProc(int nCode, IntPtr wParam, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    internal struct KBDLLHOOKSTRUCT
    {
        public uint vkCode;
        public uint scanCode;
        public uint flags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [LibraryImport("user32.dll", SetLastError = true)]
    internal static partial IntPtr SetWindowsHookExW(
        int idHook, LowLevelKeyboardProc lpfn, IntPtr hMod, uint dwThreadId);

    [LibraryImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    internal static partial bool UnhookWindowsHookEx(IntPtr hhk);

    [LibraryImport("user32.dll")]
    internal static partial IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);

    [LibraryImport("kernel32.dll", StringMarshalling = StringMarshalling.Utf16, SetLastError = true)]
    internal static partial IntPtr GetModuleHandleW(string? lpModuleName);

    // ---- Synthetic input ---------------------------------------------------------------------

    internal const uint INPUT_KEYBOARD = 1;
    internal const uint KEYEVENTF_KEYUP = 0x0002;
    internal const ushort VK_CONTROL = 0x11;
    internal const ushort VK_V = 0x56;
    internal const ushort VK_BACK = 0x08;
    internal const ushort VK_Z = 0x5A;
    internal const ushort VK_SHIFT = 0x10;
    internal const ushort VK_MENU = 0x12;
    internal const ushort VK_RETURN = 0x0D;

    [StructLayout(LayoutKind.Sequential)]
    internal struct INPUT
    {
        public uint type;
        public InputUnion u;
    }

    [StructLayout(LayoutKind.Explicit)]
    internal struct InputUnion
    {
        [FieldOffset(0)] public KEYBDINPUT ki;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct KEYBDINPUT
    {
        public ushort wVk;
        public ushort wScan;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [LibraryImport("user32.dll", SetLastError = true)]
    internal static partial uint SendInput(uint nInputs, [In] INPUT[] pInputs, int cbSize);

    // ---- Foreground window -------------------------------------------------------------------

    [LibraryImport("user32.dll")]
    internal static partial IntPtr GetForegroundWindow();

    [LibraryImport("user32.dll", StringMarshalling = StringMarshalling.Utf16)]
    internal static partial int GetWindowTextW(IntPtr hWnd, [Out] char[] lpString, int nMaxCount);

    [LibraryImport("user32.dll", SetLastError = true)]
    internal static partial uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    internal static string ForegroundWindowTitle()
    {
        var buffer = new char[512];
        var length = GetWindowTextW(GetForegroundWindow(), buffer, buffer.Length);
        return length > 0 ? new string(buffer, 0, length) : string.Empty;
    }

    // ---- Per-monitor DPI ---------------------------------------------------------------------
    //
    // The scale of a monitor the app is not currently on. Control.DeviceDpi answers for the
    // monitor a window is already displayed on, which is the wrong question for the recording
    // overlay: it is hidden between dictations and re-shown wherever the cursor now is, so it has
    // to be sized for a screen it has not moved to yet.

    internal const int MONITOR_DEFAULTTONEAREST = 2;
    /// <summary>MDT_EFFECTIVE_DPI: the scale the user chose, which is what the UI is drawn at.</summary>
    internal const int MDT_EFFECTIVE_DPI = 0;

    [StructLayout(LayoutKind.Sequential)]
    internal struct POINT
    {
        public int x;
        public int y;
    }

    [LibraryImport("user32.dll")]
    internal static partial IntPtr MonitorFromPoint(POINT pt, int dwFlags);

    /// <summary>Returns an HRESULT; S_OK is 0.</summary>
    [LibraryImport("shcore.dll")]
    internal static partial int GetDpiForMonitor(
        IntPtr hmonitor, int dpiType, out uint dpiX, out uint dpiY);

    /// <summary>
    /// Dots per inch of the monitor under <paramref name="point"/>, in physical screen
    /// coordinates. Falls back to 96 — an unscaled display — rather than throwing, because a
    /// wrongly sized pill is worth strictly less than a dictation that fails to start.
    /// </summary>
    internal static uint MonitorDpiAt(Point point)
    {
        var monitor = MonitorFromPoint(
            new POINT { x = point.X, y = point.Y }, MONITOR_DEFAULTTONEAREST);
        return GetDpiForMonitor(monitor, MDT_EFFECTIVE_DPI, out var dpiX, out _) == 0 ? dpiX : 96;
    }

    // ---- Audio capture (winmm) ---------------------------------------------------------------
    //
    // waveIn rather than WASAPI or NAudio: 16 kHz mono PCM is exactly what waveIn does natively,
    // and a dictation tool should not pull in a dependency to record a mono stream.

    internal const int WAVE_MAPPER = -1;

    [LibraryImport("user32.dll")]
    internal static partial short GetAsyncKeyState(int vKey);

    [LibraryImport("winmm.dll")]
    internal static partial uint waveInGetNumDevs();

    /// <summary>
    /// WAVEINCAPS, for the device name. Only the name and the id are used; the format bitmask is
    /// not consulted because the recorder asks for 16 kHz mono and lets the driver refuse.
    /// </summary>
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    internal struct WAVEINCAPS
    {
        internal ushort wMid;
        internal ushort wPid;
        internal uint vDriverVersion;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        internal string szPname;
        internal uint dwFormats;
        internal ushort wChannels;
        internal ushort wReserved1;
    }

    [DllImport("winmm.dll", CharSet = CharSet.Unicode, EntryPoint = "waveInGetDevCapsW")]
    internal static extern int waveInGetDevCaps(IntPtr deviceId, out WAVEINCAPS caps, int size);
    internal const int WAVE_FORMAT_PCM = 1;

    [StructLayout(LayoutKind.Sequential)]
    internal struct WAVEFORMATEX
    {
        public ushort wFormatTag;
        public ushort nChannels;
        public uint nSamplesPerSec;
        public uint nAvgBytesPerSec;
        public ushort nBlockAlign;
        public ushort wBitsPerSample;
        public ushort cbSize;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct WAVEHDR
    {
        public IntPtr lpData;
        public uint dwBufferLength;
        public uint dwBytesRecorded;
        public IntPtr dwUser;
        public uint dwFlags;
        public uint dwLoops;
        public IntPtr lpNext;
        public IntPtr reserved;
    }

    [LibraryImport("winmm.dll", EntryPoint = "waveInOpen")]
    internal static partial int waveInOpenEvent(
        out IntPtr phwi, int uDeviceID, ref WAVEFORMATEX pwfx,
        IntPtr eventHandle, IntPtr dwInstance, uint fdwOpen);

    [LibraryImport("winmm.dll")]
    internal static partial int waveInPrepareHeader(IntPtr hwi, IntPtr pwh, int cbwh);

    [LibraryImport("winmm.dll")]
    internal static partial int waveInUnprepareHeader(IntPtr hwi, IntPtr pwh, int cbwh);

    [LibraryImport("winmm.dll")]
    internal static partial int waveInAddBuffer(IntPtr hwi, IntPtr pwh, int cbwh);

    [LibraryImport("winmm.dll")]
    internal static partial int waveInStart(IntPtr hwi);

    [LibraryImport("winmm.dll")]
    internal static partial int waveInStop(IntPtr hwi);

    [LibraryImport("winmm.dll")]
    internal static partial int waveInReset(IntPtr hwi);

    [LibraryImport("winmm.dll")]
    internal static partial int waveInClose(IntPtr hwi);
}
