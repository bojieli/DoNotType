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
    /// The cue is <see cref="Tone"/>, in the core, because macOS plays the same one. All that
    /// belongs here is handing its bytes to Windows.
    /// </summary>
    /// <remarks>
    /// This used to be Asterisk and Beep. System sounds have a real argument in their favour --
    /// they respect the user's scheme, including a silent one -- but Asterisk and Beep are two
    /// unrelated single events, so which of them just played is a question of memory rather than
    /// hearing, and on a default install Beep is the sound Windows also makes when it refuses a
    /// click. The scheme is still respected where it counts: the toggle in Settings turns this off
    /// entirely.
    ///
    /// <c>SoundPlayer</c> reads the stream when told to, not when constructed, so both are loaded
    /// once up front rather than decoding a WAV on the hotkey path. It plays on a worker thread and
    /// so does not hold up the recording it is announcing.
    /// </remarks>
    private static readonly System.Media.SoundPlayer? StartPlayer = Load(Tone.Start());
    private static readonly System.Media.SoundPlayer? StopPlayer = Load(Tone.Stop());

    /// <summary>
    /// Nullable, and caught here rather than at the call: these are static fields, so anything
    /// thrown while preparing them becomes a <c>TypeInitializationException</c> on first use --
    /// which is the hotkey path. A machine with no audio device would then fail to dictate rather
    /// than fail to beep.
    /// </summary>
    private static System.Media.SoundPlayer? Load(byte[] wav)
    {
        try
        {
            var player = new System.Media.SoundPlayer(new MemoryStream(wav));
            player.Load();
            return player;
        }
        catch (Exception)
        {
            return null;
        }
    }

    public static void PlayStart()
    {
        if (Enabled) Play(StartPlayer);
    }

    public static void PlayStop()
    {
        if (Enabled) Play(StopPlayer);
    }

    /// <summary>
    /// A cue that cannot play is not worth taking a dictation down with it: an audio device that
    /// disappears mid-session throws here, and the recording it was announcing is the part the user
    /// actually asked for.
    /// </summary>
    private static void Play(System.Media.SoundPlayer? player)
    {
        if (player is null)
        {
            return;
        }

        try
        {
            player.Stop();
            player.Play();
        }
        catch (Exception)
        {
            // Nothing to say and nowhere useful to say it; silence is the failure mode already.
        }
    }
}
