using System.Runtime.InteropServices;
using DoNotType.Core;

namespace DoNotType.App;

/// <summary>
/// The microphones Windows will record from, and which one this app should use.
/// </summary>
/// <remarks>
/// Pinning matters because the system default follows whatever was plugged in last. Somebody who
/// dictates through a headset and then connects a monitor with a built-in microphone starts
/// recording from across the room without anything having changed on screen — and the first sign
/// is a transcript that is worse than usual, which reads as the model getting worse.
/// </remarks>
public static class AudioDevices
{
    /// <param name="Id">The waveIn device index, or -1 for whatever the system prefers.</param>
    public sealed record Device(int Id, string Name);

    /// <summary>Everything currently connected, with the system default first.</summary>
    public static IReadOnlyList<Device> Available()
    {
        var devices = new List<Device> { new(Interop.WAVE_MAPPER, "System default") };
        var count = Interop.waveInGetNumDevs();

        for (var index = 0; index < count; index++)
        {
            if (Interop.waveInGetDevCaps(
                    (IntPtr)index, out var caps, Marshal.SizeOf<Interop.WAVEINCAPS>()) != 0)
            {
                continue;
            }
            var name = caps.szPname;
            devices.Add(new Device(index, string.IsNullOrWhiteSpace(name) ? $"Device {index}" : name));
        }
        return devices;
    }

    /// <summary>
    /// The stored device if it is still connected, otherwise the system default.
    /// </summary>
    /// <remarks>
    /// Unplugging a pinned microphone must not stop dictation working. A saved index that no longer
    /// exists silently becomes the default rather than an error: the alternative is an app that
    /// refuses to record because of a device somebody removed weeks ago.
    /// </remarks>
    public static int Resolve(string? preferredName)
    {
        if (string.IsNullOrWhiteSpace(preferredName)) return Interop.WAVE_MAPPER;

        var match = Available().FirstOrDefault(
            device => string.Equals(device.Name, preferredName, StringComparison.OrdinalIgnoreCase));
        if (match is not null) return match.Id;

        new Log("audio").Info(
            () => "the pinned microphone is not connected; using the system default",
            new Dictionary<string, string> { ["pinned"] = preferredName });
        return Interop.WAVE_MAPPER;
    }
}

/// <summary>
/// The two tones that say a recording started and stopped.
/// </summary>
/// <remarks>
/// Worth having because the overlay is at the bottom of the screen and the user is looking at what
/// they are dictating into. A sound is the only feedback that reaches somebody who is not looking,
/// and "did it hear me" is the question the first second of a dictation has to answer.
/// </remarks>
public static class InteractionSounds
{
    public static bool Enabled { get; set; } = true;

    /// <summary>
    /// System sounds rather than shipped audio files: they respect the user's sound scheme,
    /// including a silent one, and they are already familiar as "something began" and "something
    /// finished" rather than being two more noises to learn.
    /// </summary>
    public static void PlayStart()
    {
        if (Enabled) System.Media.SystemSounds.Asterisk.Play();
    }

    public static void PlayStop()
    {
        if (Enabled) System.Media.SystemSounds.Beep.Play();
    }
}
