using System.Runtime.InteropServices;
using DoNotType.Core;

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

    /// <summary>
    /// Eight buffers of 100 ms, rather than four of half a second.
    /// </summary>
    /// <remarks>
    /// The total held in flight is roughly what it was — 800 ms against 2 s, still far more than a
    /// callback that copies a buffer and requeues it can fall behind by — but a buffer is now the
    /// unit in which the level meter learns anything. At half a second the meter could not be more
    /// current than half a second whatever the UI did, and it arrived in jumps of eight bars twice
    /// a second: a waveform delivered by parcel post. At 100 ms it keeps up with the voice.
    /// </remarks>
    private const int BufferCount = 8;
    private const int BufferBytes = SampleRate / 5; // 3200 bytes: 1600 samples, 100 ms

    private readonly Lock _gate = new();
    private readonly Lock _lifecycleGate = new();
    private readonly List<byte> _pcm = [];
    private readonly AutoResetEvent _bufferReady = new(false);

    private IntPtr _handle;
    private GCHandle[] _pinned = [];
    private IntPtr[] _headers = [];
    private int _preparedHeaders;
    private int _nextBuffer;
    private int _captureError;
    private string? _captureFailure;
    private DateTime _startedAt;
    private Thread? _captureThread;
    private volatile bool _workerShouldStop;
    private volatile bool _isRecording;
    private bool _disposed;

    private static readonly Log AudioLog = new("audio");

    public bool IsRecording => _isRecording;

    private AudioLevelMeter _meter = new(SampleRate);
    /// <summary>Bars the overlay has not drawn yet. See <see cref="DrainLevels"/>.</summary>
    private readonly List<AudioLevelMeter.Bar> _pendingBars = [];

    /// <summary>About seven seconds of bars.</summary>
    private const int MaximumPendingBars = 120;

    /// <summary>
    /// Hands the overlay the bars captured since it last asked, oldest first.
    /// </summary>
    /// <remarks>
    /// Drained rather than sampled. The old meter read a single "current level" thirty times a
    /// second from a capture buffer that only changed twice a second, so twenty-nine readings in
    /// thirty were a number it had already drawn. The levels are measured where the audio is, in
    /// 20 ms frames on the capture thread, and the UI collects them at whatever rate it redraws.
    /// </remarks>
    public IReadOnlyList<AudioLevelMeter.Bar> DrainLevels()
    {
        lock (_gate)
        {
            if (_pendingBars.Count == 0) return [];
            var bars = _pendingBars.ToArray();
            _pendingBars.Clear();
            return bars;
        }
    }

    /// <summary>
    /// Windows has no permission prompt for the microphone; access is a Settings privacy toggle,
    /// and denial surfaces here as a failure to open the device.
    /// </summary>
    /// <summary>
    /// The pinned microphone by name, or null to follow the system default.
    /// </summary>
    /// <remarks>
    /// By name rather than by index: waveIn indices are positional and shift when a device is
    /// unplugged, so a stored index can silently come to mean a different microphone. A name that
    /// no longer matches falls back to the default rather than recording from the wrong one.
    /// </remarks>
    public string? PreferredDeviceName { get; set; }

    /// <summary>The exact PCM appended to the recovery WAV, delivered in capture order.</summary>
    public Action<byte[]>? PcmCaptured { get; set; }

    /// <summary>Lets the owner abandon live mode while retaining this recorder's complete WAV.</summary>
    public Action<Exception>? PcmCaptureFailed { get; set; }

    public void Start()
    {
        lock (_lifecycleGate)
        {
            lock (_gate)
            {
                ObjectDisposedException.ThrowIf(_disposed, this);
                if (_isRecording) return;
                if (_handle != IntPtr.Zero)
                {
                    throw new InvalidOperationException(
                        "The previous microphone session has not finished shutting down.");
                }

                _pcm.Clear();
                _meter = new AudioLevelMeter(SampleRate);
                _pendingBars.Clear();
                _captureError = 0;
                _captureFailure = null;
                _preparedHeaders = 0;
                _nextBuffer = 0;
                _workerShouldStop = false;

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

                // Event mode keeps all real work out of waveInProc. Microsoft explicitly permits
                // only a tiny set of operations in that native callback and warns that calling a
                // wave function there can deadlock; the old recorder requeued every buffer there.
                // https://learn.microsoft.com/en-us/previous-versions/dd743849(v=vs.85)
                const uint CALLBACK_EVENT = 0x00050000;
                var result = Interop.waveInOpenEvent(
                    out _handle, AudioDevices.Resolve(PreferredDeviceName), ref format,
                    _bufferReady.SafeWaitHandle.DangerousGetHandle(), IntPtr.Zero, CALLBACK_EVENT);
                if (result != 0)
                {
                    _handle = IntPtr.Zero;
                    throw OpenFailure(result);
                }

                try
                {
                    AllocateAndQueueBuffers();
                    _startedAt = DateTime.UtcNow;
                    _isRecording = true;
                    EnsureSuccess(Interop.waveInStart(_handle), "start microphone capture");

                    _captureThread = new Thread(CaptureLoop)
                    {
                        IsBackground = true,
                        Name = "DoNotType microphone",
                    };
                    _captureThread.Start();
                }
                catch
                {
                    _isRecording = false;
                    _workerShouldStop = true;
                    Interop.waveInReset(_handle);
                    ReleaseNativeResources();
                    throw;
                }
            }
        }
    }

    /// <summary>Stops and returns a complete WAV, or null when it was too short to be speech.</summary>
    public byte[]? Stop()
    {
        lock (_lifecycleGate)
        {
            Thread? worker;
            TimeSpan elapsed;
            lock (_gate)
            {
                if (!_isRecording) return null;
                elapsed = DateTime.UtcNow - _startedAt;
                worker = BeginStop();
            }

            // No locks held while waiting: the worker may be finishing a buffer under _gate.
            worker?.Join();

            lock (_gate)
            {
                // waveInReset returns every queued buffer, including the partial tail that had not
                // reached 100 ms. Drain it after the worker exits so releasing the key never clips
                // the end of the last word.
                try
                {
                    if (_captureError == 0 && _captureFailure is null) DrainReturnedBuffers();
                }
                catch (Exception error)
                {
                    _captureFailure = error.GetType().Name;
                    AudioLog.Error(
                        () => "could not drain the final microphone buffers",
                        new Dictionary<string, string>
                        {
                            ["type"] = error.GetType().Name,
                            ["detail"] = error.Message,
                        });
                }
                finally
                {
                    ReleaseNativeResources();
                }
                ThrowIfCaptureFailed();

                if (elapsed < MinimumDuration || _pcm.Count == 0) return null;
                return WrapInWavContainer([.. _pcm]);
            }
        }
    }

    public void Cancel()
    {
        lock (_lifecycleGate)
        {
            CancelUnderLifecycleGate();
        }
    }

    public void Dispose()
    {
        lock (_lifecycleGate)
        {
            if (_disposed) return;
            CancelUnderLifecycleGate();
            _disposed = true;
            // If the driver refused to close, it may still retain this event handle. The process
            // is exiting and leaking it is safer than letting native code signal a recycled one.
            if (_handle == IntPtr.Zero) _bufferReady.Dispose();
        }
    }

    private void CancelUnderLifecycleGate()
    {
        Thread? worker;
        lock (_gate) worker = _handle == IntPtr.Zero ? null : BeginStop();
        worker?.Join();
        lock (_gate)
        {
            ReleaseNativeResources();
            _pcm.Clear();
        }
    }

    private void AllocateAndQueueBuffers()
    {
        var headerSize = Marshal.SizeOf<Interop.WAVEHDR>();
        _pinned = new GCHandle[BufferCount];
        _headers = new IntPtr[BufferCount];
        for (var i = 0; i < BufferCount; i++)
        {
            var buffer = new byte[BufferBytes];
            _pinned[i] = GCHandle.Alloc(buffer, GCHandleType.Pinned);
            var header = new Interop.WAVEHDR
            {
                lpData = _pinned[i].AddrOfPinnedObject(),
                dwBufferLength = BufferBytes,
                dwUser = (IntPtr)i,
            };
            _headers[i] = Marshal.AllocHGlobal(headerSize);
            Marshal.StructureToPtr(header, _headers[i], fDeleteOld: false);
            EnsureSuccess(
                Interop.waveInPrepareHeader(_handle, _headers[i], headerSize),
                "prepare a recording buffer");
            _preparedHeaders++;
            EnsureSuccess(
                Interop.waveInAddBuffer(_handle, _headers[i], headerSize),
                "queue a recording buffer");
        }
    }

    private Thread? BeginStop()
    {
        _isRecording = false;
        _workerShouldStop = true;
        _bufferReady.Set();

        RecordNativeFailure(Interop.waveInStop(_handle), "waveInStop");
        RecordNativeFailure(Interop.waveInReset(_handle), "waveInReset");
        var worker = _captureThread;
        _captureThread = null;
        return worker;
    }

    private void CaptureLoop()
    {
        try
        {
            while (true)
            {
                _bufferReady.WaitOne();
                if (_workerShouldStop) return;

                while (ProcessNextBuffer())
                {
                    if (_workerShouldStop) return;
                }
            }
        }
        catch (Exception error)
        {
            lock (_gate) _captureFailure = error.GetType().Name;
            try
            {
                AudioLog.Error(
                    () => "microphone worker failed",
                    new Dictionary<string, string>
                    {
                        ["type"] = error.GetType().Name,
                        ["detail"] = error.Message,
                    });
            }
            catch
            {
                // A diagnostics failure cannot be allowed to escape a background Thread.
            }
        }
    }

    private bool ProcessNextBuffer()
    {
        lock (_gate)
        {
            if (_workerShouldStop || !_isRecording || _headers.Length == 0) return false;
            var pointer = _headers[_nextBuffer];
            var header = Marshal.PtrToStructure<Interop.WAVEHDR>(pointer);
            if ((header.dwFlags & WHDR_DONE) == 0) return false;

            Append(header);
            var result = Interop.waveInAddBuffer(
                _handle, pointer, Marshal.SizeOf<Interop.WAVEHDR>());
            if (result != 0)
            {
                _captureError = result;
                return false;
            }
            _nextBuffer = (_nextBuffer + 1) % BufferCount;
            return true;
        }
    }

    private void DrainReturnedBuffers()
    {
        // Every header is queued during a healthy capture. After reset, walk the same ring order
        // the driver filled rather than scanning by index and scrambling buffers across the wrap.
        for (var count = 0; count < BufferCount; count++)
        {
            var header = Marshal.PtrToStructure<Interop.WAVEHDR>(_headers[_nextBuffer]);
            if ((header.dwFlags & WHDR_DONE) == 0) break;
            Append(header);
            _nextBuffer = (_nextBuffer + 1) % BufferCount;
        }
    }

    private void Append(Interop.WAVEHDR header)
    {
        var recorded = checked((int)header.dwBytesRecorded);
        if (recorded <= 0) return;
        if (recorded > header.dwBufferLength)
        {
            throw new InvalidDataException("The microphone driver returned an oversized buffer.");
        }

        var chunk = new byte[recorded];
        Marshal.Copy(header.lpData, chunk, 0, recorded);
        _pcm.AddRange(chunk);
        try
        {
            PcmCaptured?.Invoke(chunk);
        }
        catch (Exception error)
        {
            // Live streaming is an optimisation over this complete recovery WAV. Abandon live
            // mode and let the normal post-recording request preserve the user's words.
            AudioLog.Warn(
                () => "live audio consumer failed; continuing local capture",
                new Dictionary<string, string>
                {
                    ["type"] = error.GetType().Name,
                    ["detail"] = error.Message,
                });
            PcmCaptured = null;
            try
            {
                PcmCaptureFailed?.Invoke(error);
            }
            catch (Exception notificationError)
            {
                AudioLog.Warn(
                    () => "could not notify the live audio owner",
                    new Dictionary<string, string>
                    {
                        ["type"] = notificationError.GetType().Name,
                        ["detail"] = notificationError.Message,
                    });
            }
        }

        _pendingBars.AddRange(_meter.Append(chunk));
        if (_pendingBars.Count > MaximumPendingBars)
        {
            _pendingBars.RemoveRange(0, _pendingBars.Count - MaximumPendingBars);
        }
    }

    private void ReleaseNativeResources()
    {
        if (_handle == IntPtr.Zero)
        {
            ReleaseAllocations();
            return;
        }

        var headerSize = Marshal.SizeOf<Interop.WAVEHDR>();
        for (var i = 0; i < _preparedHeaders; i++)
        {
            RecordNativeFailure(
                Interop.waveInUnprepareHeader(_handle, _headers[i], headerSize),
                "waveInUnprepareHeader");
        }
        var close = Interop.waveInClose(_handle);
        RecordNativeFailure(close, "waveInClose");
        if (close != 0)
        {
            // The driver may still own the headers. Leaking this failed session is safer than
            // freeing memory that native code can write into; Start refuses to overlap it.
            return;
        }

        _handle = IntPtr.Zero;
        _preparedHeaders = 0;
        ReleaseAllocations();
    }

    private void ReleaseAllocations()
    {
        foreach (var header in _headers)
        {
            if (header != IntPtr.Zero) Marshal.FreeHGlobal(header);
        }
        _headers = [];
        foreach (var pinned in _pinned)
        {
            if (pinned.IsAllocated) pinned.Free();
        }
        _pinned = [];
    }

    private void RecordNativeFailure(int result, string operation)
    {
        if (result == 0) return;
        _captureError = result;
        AudioLog.Warn(
            () => $"{operation} failed",
            new Dictionary<string, string> { ["code"] = result.ToString() });
    }

    private void ThrowIfCaptureFailed()
    {
        if (_captureFailure is not null)
        {
            throw new MicrophoneUnavailableException(
                $"The microphone stopped unexpectedly ({_captureFailure}). Try again or choose "
                    + "another microphone in Settings.",
                canBeFixedInSettings: true);
        }
        if (_captureError != 0)
        {
            throw new MicrophoneUnavailableException(
                $"The microphone stopped while recording (waveIn returned {_captureError}). "
                    + "Try again or choose another microphone in Settings.",
                canBeFixedInSettings: true);
        }
    }

    private static MicrophoneUnavailableException OpenFailure(int result)
    {
        var reason = result switch
        {
            2 or 6 => "no recording device is connected",
            4 => "another application is using the microphone",
            _ => "Windows refused access to the microphone",
        };
        return new MicrophoneUnavailableException(
            $"Could not open the microphone: {reason} (waveInOpen returned {result}).",
            canBeFixedInSettings: result is not (2 or 6));
    }

    private static void EnsureSuccess(int result, string operation)
    {
        if (result == 0) return;
        throw new MicrophoneUnavailableException(
            $"Could not {operation} (waveIn returned {result}). Try another microphone in Settings.",
            canBeFixedInSettings: true);
    }

    private const uint WHDR_DONE = 0x00000001;

    /// <summary>Length of a recording this class produced, from its own 44-byte header.</summary>
    /// <remarks>
    /// Only valid for WAVs written here -- everything this app records is 16 kHz mono 16-bit, so
    /// there is nothing to parse. A general reader would have to scan for the <c>data</c> chunk,
    /// and there is no source of foreign WAVs on this platform.
    /// </remarks>
    public static double DurationSeconds(byte[] wav) =>
        Math.Max(0, wav.Length - 44) / (double)(SampleRate * 2);

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

/// <summary>
/// The microphone could not be opened, and whether Settings is where that gets fixed.
/// </summary>
/// <remarks>
/// Its own type so the caller can offer the privacy page rather than printing a sentence about
/// where it is. Windows has no permission prompt for the microphone — access is a toggle somebody
/// has to find — which makes "here is the toggle" the whole of the guidance.
/// </remarks>
public sealed class MicrophoneUnavailableException(string message, bool canBeFixedInSettings)
    : Exception(message)
{
    public bool CanBeFixedInSettings { get; } = canBeFixedInSettings;

    /// <summary>The privacy page for the microphone, which opens without elevation.</summary>
    public const string SettingsUri = "ms-settings:privacy-microphone";
}
