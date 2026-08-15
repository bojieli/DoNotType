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

    // ---- Audio capture (winmm) ---------------------------------------------------------------
    //
    // waveIn rather than WASAPI or NAudio: 16 kHz mono PCM is exactly what waveIn does natively,
    // and a dictation tool should not pull in a dependency to record a mono stream.

    internal const int WAVE_MAPPER = -1;

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
    internal const uint MM_WIM_DATA = 0x3C0;
    internal const uint WAVERR_STILLPLAYING = 33;

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

    internal delegate void WaveInProc(
        IntPtr hwi, uint uMsg, IntPtr dwInstance, ref WAVEHDR dwParam1, IntPtr dwParam2);

    [LibraryImport("winmm.dll")]
    internal static partial int waveInOpen(
        out IntPtr phwi, int uDeviceID, ref WAVEFORMATEX pwfx,
        WaveInProc dwCallback, IntPtr dwInstance, uint fdwOpen);

    [LibraryImport("winmm.dll")]
    internal static partial int waveInPrepareHeader(IntPtr hwi, ref WAVEHDR pwh, int cbwh);

    [LibraryImport("winmm.dll")]
    internal static partial int waveInUnprepareHeader(IntPtr hwi, ref WAVEHDR pwh, int cbwh);

    [LibraryImport("winmm.dll")]
    internal static partial int waveInAddBuffer(IntPtr hwi, ref WAVEHDR pwh, int cbwh);

    [LibraryImport("winmm.dll")]
    internal static partial int waveInStart(IntPtr hwi);

    [LibraryImport("winmm.dll")]
    internal static partial int waveInStop(IntPtr hwi);

    [LibraryImport("winmm.dll")]
    internal static partial int waveInReset(IntPtr hwi);

    [LibraryImport("winmm.dll")]
    internal static partial int waveInClose(IntPtr hwi);
}
