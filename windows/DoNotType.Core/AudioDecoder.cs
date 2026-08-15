namespace DoNotType.Core;

/// <summary>
/// Turns a recording into the 16 kHz mono WAV the rest of the pipeline assumes.
/// </summary>
/// <remarks>
/// <para>
/// Live dictation never needed this: <c>AudioRecorder</c> captures at 16 kHz mono through waveIn and
/// hands over PCM already in the right shape. Transcribing a <em>file</em> is different -- what
/// people have on disk is a 44.1 kHz stereo recording out of some other tool, and every one of those
/// breaks something downstream:
/// </para>
/// <list type="bullet">
/// <item><see cref="AudioChunker"/> reads a 16 kHz mono PCM body, so anything else is one
/// unsplittable chunk however long it is.</item>
/// <item>Duration is read from the header, so the history row records a zero-length dictation.</item>
/// <item><see cref="OpusEncoder"/> takes 16 kHz mono PCM in, so the upload is not compressed.</item>
/// </list>
/// <para>
/// Three routes, because .NET has no single decoder and the platform's own are split across two
/// APIs. WAV is read here in managed code, so it works anywhere and is testable anywhere. Opus goes
/// through <see cref="OggOpusReader"/> and libopus, which this project already depends on for the
/// encode side. Everything else -- MP3, M4A/AAC, WMA -- goes to Media Foundation, which is the only
/// one of the three that cannot run off Windows.
/// </para>
/// </remarks>
public static class AudioDecoder
{
    /// <summary>What the models are given regardless. They downsample to this anyway.</summary>
    public const int SampleRate = 16_000;

    private static readonly Log Log = new("audio");

    public sealed class DecodeException(string message) : Exception(message);

    /// <summary>Extensions worth offering in a file dialog.</summary>
    public static IReadOnlyList<string> OpenableExtensions { get; } =
        [".wav", ".wave", ".mp3", ".m4a", ".aac", ".mp4", ".opus", ".ogg", ".wma", ".flac"];

    /// <summary>What to tell someone whose file did not open, in one place.</summary>
    public const string SupportedFormats = "WAV, MP3, M4A/AAC, Opus, and anything else Windows plays";

    /// <summary>Loads a recording as something the pipeline can chunk, time and compress.</summary>
    public static byte[] Load(string path)
    {
        // Said plainly, because what comes back otherwise describes the symptom rather than the
        // cause: a folder dragged onto the window and a file that finished copying as zero bytes
        // both reached the decoder and came out as an unexplained HRESULT.
        if (Directory.Exists(path))
        {
            throw new DecodeException($"{path} is a folder, not a recording.");
        }
        if (!File.Exists(path)) throw new DecodeException($"No such file: {path}");
        if (new FileInfo(path).Length == 0)
        {
            throw new DecodeException($"{Path.GetFileName(path)} is empty.");
        }

        var name = Path.GetFileName(path);
        var started = DateTimeOffset.Now;
        var bytes = File.ReadAllBytes(path);

        // Sniffed rather than trusted to the extension: a `.wav` that is really an MP3 is a thing
        // recorders do, and the container is the fact that matters.
        if (OggOpusReader.IsOggOpus(bytes)) return OggOpusReader.DecodeToWav(bytes, name);

        if (!LooksLikeWav(bytes))
        {
            if (!MediaFoundationDecoder.IsAvailable)
            {
                throw new DecodeException(
                    $"{name} is not WAV, and only Windows has the system decoder for the rest. "
                    + "Convert it first (ffmpeg -i in.m4a -ar 16000 -ac 1 out.wav).");
            }
            return MediaFoundationDecoder.DecodeToWav(path, name);
        }

        if (IsAlreadyTarget(bytes))
        {
            // A re-encode here would be a lossy round trip that changes nothing.
            Log.Debug(() => "recording already in target format", new Dictionary<string, string>
            {
                ["file"] = name,
                ["bytes"] = bytes.Length.ToString(),
            });
            return bytes;
        }

        var wav = Convert(bytes, name);
        Log.Info(() => "decoded recording", new Dictionary<string, string>
        {
            ["file"] = name,
            ["via"] = "managed wav",
            ["bytes"] = wav.Length.ToString(),
            ["ms"] = ((long)(DateTimeOffset.Now - started).TotalMilliseconds).ToString(),
        });
        return wav;
    }

    /// <summary>A RIFF/WAVE container, whatever is inside it.</summary>
    internal static bool LooksLikeWav(ReadOnlySpan<byte> bytes) =>
        bytes.Length > 12
        && bytes[0] == 'R' && bytes[1] == 'I' && bytes[2] == 'F' && bytes[3] == 'F'
        && bytes[8] == 'W' && bytes[9] == 'A' && bytes[10] == 'V' && bytes[11] == 'E';

    /// <summary>True when the bytes are already 16 kHz mono 16-bit PCM WAV.</summary>
    public static bool IsAlreadyTarget(byte[] wav)
    {
        var format = ReadFormat(wav);
        return format is { SampleRate: SampleRate, Channels: 1, BitsPerSample: 16, IsFloat: false };
    }

    /// <summary>Downmixes to mono, resamples to 16 kHz, and rewrites the header.</summary>
    private static byte[] Convert(byte[] wav, string name)
    {
        var format = ReadFormat(wav)
            ?? throw new DecodeException(
                $"{name} is not a WAV this app can read -- no readable `fmt ` chunk. "
                + "Convert it to 16-bit PCM WAV and try again.");

        var body = ReadDataChunk(wav)
            ?? throw new DecodeException($"{name} has no audio data in it.");

        return AudioChunker.WrapInWavContainer(ToTargetPcm(body, format, name));
    }

    /// <summary>
    /// Any PCM, in any layout, as 16 kHz mono 16-bit.
    /// </summary>
    /// <remarks>
    /// Shared with <see cref="MediaFoundationDecoder"/>, which cannot ask Windows for this format
    /// directly: the Source Reader will insert a *decoder* to turn MP3 into PCM, but it will not
    /// insert a *resampler*, so asking for 16 kHz mono up front fails outright on a 44.1 kHz stereo
    /// file. It hands back whatever the decoder natively produces and this finishes the job — with
    /// the same code path the WAV reader uses, which is the one the sample-width tests cover.
    /// </remarks>
    internal static byte[] ToTargetPcm(ReadOnlySpan<byte> body, WavFormat format, string name)
    {
        var mono = ToMonoSamples(body, format, name);
        if (mono.Length == 0) throw new DecodeException($"{name} decoded to no audio at all.");

        var resampled = Resample(mono, format.SampleRate);
        var pcm = new byte[resampled.Length * 2];
        for (var i = 0; i < resampled.Length; i++)
        {
            var sample = (short)Math.Clamp(resampled[i], short.MinValue, short.MaxValue);
            pcm[i * 2] = (byte)(sample & 0xFF);
            pcm[i * 2 + 1] = (byte)((sample >> 8) & 0xFF);
        }
        return pcm;
    }

    /// <summary>Reads samples of whatever width the file uses and averages the channels.</summary>
    private static float[] ToMonoSamples(ReadOnlySpan<byte> body, WavFormat format, string name)
    {
        var bytesPerSample = format.BitsPerSample / 8;
        if (bytesPerSample == 0) throw new DecodeException($"{name} declares 0 bits per sample.");

        var frames = body.Length / (bytesPerSample * format.Channels);
        var mono = new float[frames];

        for (var frame = 0; frame < frames; frame++)
        {
            double total = 0;
            for (var channel = 0; channel < format.Channels; channel++)
            {
                var offset = (frame * format.Channels + channel) * bytesPerSample;
                total += ReadSample(body, offset, format);
            }
            // A phone or laptop recording in stereo is two copies of the same voice.
            mono[frame] = (float)(total / format.Channels);
        }
        return mono;
    }

    /// <summary>Everything a consumer-grade recorder produces, normalised to 16-bit scale.</summary>
    private static double ReadSample(ReadOnlySpan<byte> body, int offset, WavFormat format)
    {
        if (format.IsFloat)
        {
            return format.BitsPerSample switch
            {
                32 => BitConverter.ToSingle(body[offset..(offset + 4)]) * short.MaxValue,
                64 => BitConverter.ToDouble(body[offset..(offset + 8)]) * short.MaxValue,
                _ => 0,
            };
        }

        return format.BitsPerSample switch
        {
            // 8-bit WAV is unsigned, unlike every other width.
            8 => (body[offset] - 128) * 256,
            16 => BitConverter.ToInt16(body[offset..(offset + 2)]),
            24 => ((body[offset + 2] << 16 | body[offset + 1] << 8 | body[offset]) << 8 >> 8) / 256.0,
            32 => BitConverter.ToInt32(body[offset..(offset + 4)]) / 65_536.0,
            _ => 0,
        };
    }

    /// <summary>
    /// Linear resampling to 16 kHz. Good enough on purpose: the destination is a speech model that
    /// downsamples to this rate anyway, so a polyphase filter would be code defending a difference
    /// nothing downstream can hear.
    /// </summary>
    private static float[] Resample(float[] samples, int sourceRate)
    {
        if (sourceRate == SampleRate || samples.Length < 2) return samples;

        var step = (double)sourceRate / SampleRate;
        var count = (int)(samples.Length / step);
        var output = new float[Math.Max(count, 0)];

        for (var i = 0; i < output.Length; i++)
        {
            var position = i * step;
            var index = (int)position;
            if (index + 1 >= samples.Length)
            {
                output[i] = samples[^1];
                continue;
            }
            var fraction = position - index;
            output[i] = (float)(samples[index] * (1 - fraction) + samples[index + 1] * fraction);
        }
        return output;
    }

    internal sealed record WavFormat(int SampleRate, int Channels, int BitsPerSample, bool IsFloat);

    /// <summary>Reads the `fmt ` chunk, wherever it is. Not every WAV puts it first.</summary>
    internal static WavFormat? ReadFormat(byte[] wav)
    {
        if (wav.Length < 44) return null;
        if (wav[0] != 'R' || wav[1] != 'I' || wav[2] != 'F' || wav[3] != 'F') return null;

        var cursor = 12;
        while (cursor + 8 <= wav.Length)
        {
            var id = System.Text.Encoding.ASCII.GetString(wav, cursor, 4);
            var size = BitConverter.ToInt32(wav, cursor + 4);
            if (size < 0) return null;

            if (id == "fmt " && cursor + 8 + 16 <= wav.Length)
            {
                var tag = BitConverter.ToUInt16(wav, cursor + 8);
                var channels = BitConverter.ToUInt16(wav, cursor + 10);
                var rate = BitConverter.ToInt32(wav, cursor + 12);
                var bits = BitConverter.ToUInt16(wav, cursor + 22);
                // 0xFFFE is WAVE_FORMAT_EXTENSIBLE, whose real tag is in the extension block; 3 is
                // IEEE float, which is what a DAW export usually is.
                var isFloat = tag == 3;
                if (tag == 0xFFFE && cursor + 8 + 26 <= wav.Length)
                {
                    isFloat = BitConverter.ToUInt16(wav, cursor + 8 + 24) == 3;
                }
                return channels > 0 && rate > 0 ? new WavFormat(rate, channels, bits, isFloat) : null;
            }
            cursor += 8 + size + (size % 2); // chunks are word-aligned
        }
        return null;
    }

    /// <summary>The `data` chunk body, wherever it is.</summary>
    internal static byte[]? ReadDataChunk(byte[] wav)
    {
        if (wav.Length < 44) return null;
        var cursor = 12;
        while (cursor + 8 <= wav.Length)
        {
            var id = System.Text.Encoding.ASCII.GetString(wav, cursor, 4);
            var size = BitConverter.ToInt32(wav, cursor + 4);
            if (size < 0) return null;

            if (id == "data")
            {
                var start = cursor + 8;
                var end = Math.Min(start + size, wav.Length);
                return end > start ? wav[start..end] : null;
            }
            cursor += 8 + size + (size % 2);
        }
        return null;
    }
}
