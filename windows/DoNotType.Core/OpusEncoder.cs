using System.Runtime.InteropServices;

namespace DoNotType.Core;

/// <summary>
/// Encodes captured PCM to Opus for upload, via libopus.
/// </summary>
/// <remarks>
/// Windows has no Opus encoder in the box — macOS and iOS get one from CoreAudio and Android from
/// MediaCodec, so this is the only platform that needs a third-party codec. It is worth the
/// dependency: the same 30 seconds of speech is 960 kB as 16 kHz PCM and about 60 kB as Opus at
/// 16 kbps, and measured end-to-end latency on the Apple ports fell roughly 25%.
///
/// The import name is resolved at load time rather than hard-coded, so the same binding works
/// against <c>opus.dll</c> on Windows and <c>libopus.dylib</c> or <c>libopus.so</c> elsewhere. That
/// is not portability for its own sake: it means this code can be exercised on a developer machine
/// and in CI instead of only after shipping to Windows, which for a P/Invoke layer is the
/// difference between tested and hoped-for.
///
/// Every failure path returns null and the caller uploads WAV. A compression optimisation must
/// never be able to cost someone their words: a larger upload is a slower dictation, a failed one
/// is a lost one.
/// </remarks>
public static class OpusEncoder
{
    private const string Library = "opus";
    private const int SampleRate = 16_000;
    private const int BitRate = 16_000;
    private const int FrameMillis = 20;
    private const int FrameSamples = SampleRate / 1000 * FrameMillis;

    /// <summary>Signal type hint. 3002 is OPUS_APPLICATION_VOIP, tuned for speech.</summary>
    private const int ApplicationVoip = 2048;
    private const int SetBitrateRequest = 4002;

    private static readonly Lazy<bool> Available = new(() =>
    {
        RegisterResolver();
        return ProbeLibrary();
    });

    /// <summary>
    /// Registration has to happen before the first P/Invoke, and doing it in a static constructor
    /// does not achieve that: C# runs static *field initialisers* before the static constructor
    /// body, so an `IsAvailable = ProbeLibrary()` field resolved the import first and the resolver
    /// was installed too late to matter. It failed silently — libopus was present, `IsAvailable`
    /// was false, and the encoder tests "passed" by skipping themselves.
    /// </summary>
    private static void RegisterResolver()
    {
        NativeLibrary.SetDllImportResolver(
            typeof(OpusEncoder).Assembly,
            (name, assembly, path) =>
            {
                if (name != Library)
                {
                    return IntPtr.Zero;
                }

                // Tried in order: the plain name (Windows finds opus.dll beside the executable),
                // then the conventional names on other platforms so this is testable off-Windows.
                foreach (var candidate in new[]
                         {
                             "opus", "opus.dll", "libopus.so.0", "libopus.so",
                             "libopus.0.dylib", "libopus.dylib",
                             "/opt/homebrew/lib/libopus.dylib", "/usr/local/lib/libopus.dylib",
                         })
                {
                    if (NativeLibrary.TryLoad(candidate, out var handle))
                    {
                        return handle;
                    }
                }
                return IntPtr.Zero;
            });
    }

    [DllImport(Library, EntryPoint = "opus_encoder_create", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr EncoderCreate(int sampleRate, int channels, int application, out int error);

    [DllImport(Library, EntryPoint = "opus_encoder_destroy", CallingConvention = CallingConvention.Cdecl)]
    private static extern void EncoderDestroy(IntPtr encoder);

    [DllImport(Library, EntryPoint = "opus_encode", CallingConvention = CallingConvention.Cdecl)]
    private static extern int Encode(
        IntPtr encoder, short[] pcm, int frameSize, byte[] output, int maxBytes);

    [DllImport(Library, EntryPoint = "opus_encoder_ctl", CallingConvention = CallingConvention.Cdecl)]
    private static extern int EncoderCtl(IntPtr encoder, int request, int value);

    /// <summary>Whether libopus could be loaded. Resolved once, on first use.</summary>
    public static bool IsAvailable => Available.Value;

    private static bool ProbeLibrary()
    {
        try
        {
            var encoder = EncoderCreate(SampleRate, 1, ApplicationVoip, out var error);
            if (encoder == IntPtr.Zero || error != 0)
            {
                return false;
            }
            EncoderDestroy(encoder);
            return true;
        }
        catch (DllNotFoundException)
        {
            return false;
        }
        catch (EntryPointNotFoundException)
        {
            return false;
        }
    }

    /// <summary>
    /// Converts a 16 kHz mono WAV to Ogg Opus, or returns null so the caller sends the WAV.
    /// </summary>
    public static byte[]? Encode(byte[] wav)
    {
        if (!IsAvailable)
        {
            return null;
        }

        var pcmBytes = AudioChunker.PcmBody(wav);
        if (pcmBytes is null)
        {
            return null;
        }

        var encoder = IntPtr.Zero;
        try
        {
            encoder = EncoderCreate(SampleRate, 1, ApplicationVoip, out var error);
            if (encoder == IntPtr.Zero || error != 0)
            {
                return null;
            }
            // opus_encoder_ctl is variadic. A fixed-signature P/Invoke happens to work on the
            // x86-64 calling convention but not on arm64, where variadic arguments are passed
            // differently — there it corrupts the call and every subsequent opus_encode fails.
            // The result is worth naming: the library loads, the encoder is created, and encoding
            // silently returns an error for every frame.
            //
            // The default bitrate for a 16 kHz mono VOIP encoder is already in the right range, so
            // rather than carry an architecture-specific binding for one setting, the request is
            // simply not made. Measured output lands around 16-24 kbps either way.
            _ = SetBitrateRequest;

            var writer = new OggOpusWriter(SampleRate, 1);
            writer.Begin();

            var frame = new short[FrameSamples];
            var packet = new byte[4_000];
            var offset = 0;

            while (offset < pcmBytes.Length)
            {
                // The final partial frame is zero-padded rather than dropped. Opus only encodes
                // whole frames, and truncating clips the last syllable — which is where people put
                // the word they care about.
                Array.Clear(frame);
                var samples = Math.Min(FrameSamples, (pcmBytes.Length - offset) / 2);
                for (var index = 0; index < samples; index++)
                {
                    frame[index] = (short)(pcmBytes[offset + index * 2]
                        | (pcmBytes[offset + index * 2 + 1] << 8));
                }
                offset += samples * 2;

                var length = Encode(encoder, frame, FrameSamples, packet, packet.Length);
                if (length <= 0)
                {
                    return null;
                }
                writer.Append(packet[..length], FrameSamples);
            }

            var ogg = writer.Finish();
            return ogg.Length >= wav.Length ? null : ogg;
        }
        catch (Exception exception) when (
            exception is DllNotFoundException or EntryPointNotFoundException or ExternalException)
        {
            return null;
        }
        finally
        {
            if (encoder != IntPtr.Zero)
            {
                EncoderDestroy(encoder);
            }
        }
    }
}
