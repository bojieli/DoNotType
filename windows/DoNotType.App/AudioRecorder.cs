using System.Runtime.InteropServices;

namespace DoNotType.App;

/// <summary>
/// Microphone capture at 16 kHz mono, via waveIn.
///
/// 16 kHz because the model downsamples to it regardless; anything richer is upload paid for and
/// discarded. waveIn rather than WASAPI or a NuGet wrapper because that is precisely the format
/// waveIn produces natively, and a dictation tool should not take a dependency to record mono PCM.
/// </summary>
public sealed class AudioRecorder : IDisposable
{
    public const int SampleRate = 16_000;
    /// <summary>Below this it was a stray key press rather than speech.</summary>
    public static readonly TimeSpan MinimumDuration = TimeSpan.FromMilliseconds(500);

    private const int BufferCount = 4;
    private const int BufferBytes = SampleRate; // ~0.5 s of 16-bit mono

    private readonly Lock _gate = new();
    private readonly List<byte> _pcm = [];
    private readonly Interop.WaveInProc _callback;

    private IntPtr _handle;
    private GCHandle[] _pinned = [];
    private Interop.WAVEHDR[] _headers = [];
    private DateTime _startedAt;

    public bool IsRecording { get; private set; }

    /// <summary>Recent peak amplitude, 0..1, so the overlay can show the mic is live.</summary>
    public float Level { get; private set; }

    public AudioRecorder() => _callback = OnWaveIn;

    /// <summary>
    /// Windows has no permission prompt for the microphone; access is a Settings privacy toggle,
    /// and denial surfaces here as a failure to open the device.
    /// </summary>
    public void Start()
    {
        lock (_gate)
        {
            if (IsRecording) return;
            _pcm.Clear();
            Level = 0;

            var format = new Interop.WAVEFORMATEX
            {
                wFormatTag = Interop.WAVE_FORMAT_PCM,
                nChannels = 1,
                nSamplesPerSec = SampleRate,
                nAvgBytesPerSec = SampleRate * 2,
                nBlockAlign = 2,
                wBitsPerSample = 16,
                cbSize = 0,
            };

            const uint CALLBACK_FUNCTION = 0x00030000;
            var result = Interop.waveInOpen(
                out _handle, Interop.WAVE_MAPPER, ref format, _callback, IntPtr.Zero,
                CALLBACK_FUNCTION);
            if (result != 0)
            {
                throw new InvalidOperationException(
                    "Could not open the microphone. Check Settings › Privacy & security › "
                    + "Microphone, and that a recording device is connected.");
            }

            _pinned = new GCHandle[BufferCount];
            _headers = new Interop.WAVEHDR[BufferCount];
            for (var i = 0; i < BufferCount; i++)
            {
                var buffer = new byte[BufferBytes];
                _pinned[i] = GCHandle.Alloc(buffer, GCHandleType.Pinned);
                _headers[i] = new Interop.WAVEHDR
                {
                    lpData = _pinned[i].AddrOfPinnedObject(),
                    dwBufferLength = BufferBytes,
                };
                Interop.waveInPrepareHeader(_handle, ref _headers[i], Marshal.SizeOf<Interop.WAVEHDR>());
                Interop.waveInAddBuffer(_handle, ref _headers[i], Marshal.SizeOf<Interop.WAVEHDR>());
            }

            Interop.waveInStart(_handle);
            IsRecording = true;
            _startedAt = DateTime.UtcNow;
        }
    }

    /// <summary>Stops and returns a complete WAV, or null when it was too short to be speech.</summary>
    public byte[]? Stop()
    {
        lock (_gate)
        {
            if (!IsRecording) return null;
            var elapsed = DateTime.UtcNow - _startedAt;
            Teardown();

            if (elapsed < MinimumDuration || _pcm.Count == 0) return null;
            return WrapInWavContainer([.. _pcm]);
        }
    }

    public void Cancel()
    {
        lock (_gate)
        {
            Teardown();
            _pcm.Clear();
        }
    }

    public void Dispose() => Cancel();

    private void Teardown()
    {
        if (!IsRecording) return;
        IsRecording = false;
        Level = 0;

        Interop.waveInStop(_handle);
        Interop.waveInReset(_handle);

        for (var i = 0; i < _headers.Length; i++)
        {
            Interop.waveInUnprepareHeader(_handle, ref _headers[i], Marshal.SizeOf<Interop.WAVEHDR>());
            if (_pinned[i].IsAllocated) _pinned[i].Free();
        }
        _pinned = [];
        _headers = [];

        Interop.waveInClose(_handle);
        _handle = IntPtr.Zero;
    }

    private void OnWaveIn(
        IntPtr hwi, uint uMsg, IntPtr dwInstance, ref Interop.WAVEHDR header, IntPtr dwParam2)
    {
        if (uMsg != Interop.MM_WIM_DATA) return;

        lock (_gate)
        {
            if (!IsRecording) return;

            var recorded = (int)header.dwBytesRecorded;
            if (recorded > 0)
            {
                var chunk = new byte[recorded];
                Marshal.Copy(header.lpData, chunk, 0, recorded);
                _pcm.AddRange(chunk);
                Level = Peak(chunk);
            }
            // Requeue so capture continues; the driver hands the buffer back each time it fills.
            Interop.waveInAddBuffer(hwi, ref header, Marshal.SizeOf<Interop.WAVEHDR>());
        }
    }

    private static float Peak(byte[] buffer)
    {
        var peak = 0;
        for (var i = 0; i + 1 < buffer.Length; i += 2)
        {
            var sample = Math.Abs((short)(buffer[i] | (buffer[i + 1] << 8)));
            if (sample > peak) peak = sample;
        }
        return peak / 32768f;
    }

    /// <summary>44-byte canonical RIFF header, PCM 16-bit mono.</summary>
    internal static byte[] WrapInWavContainer(byte[] pcm)
    {
        using var stream = new MemoryStream(44 + pcm.Length);
        using var writer = new BinaryWriter(stream);

        writer.Write("RIFF"u8.ToArray());
        writer.Write(36 + pcm.Length);
        writer.Write("WAVE"u8.ToArray());
        writer.Write("fmt "u8.ToArray());
        writer.Write(16);                        // PCM chunk size
        writer.Write((short)1);                  // format: PCM
        writer.Write((short)1);                  // channels: mono
        writer.Write(SampleRate);
        writer.Write(SampleRate * 2);            // byte rate
        writer.Write((short)2);                  // block align
        writer.Write((short)16);                 // bits per sample
        writer.Write("data"u8.ToArray());
        writer.Write(pcm.Length);
        writer.Write(pcm);
        writer.Flush();
        return stream.ToArray();
    }
}
