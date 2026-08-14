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
/// <strong>WAV only, and that is a real platform difference.</strong> macOS, iOS and Android each
/// have a system decoder this can lean on -- CoreAudio and MediaCodec -- and .NET has none: decoding
/// MP3 or M4A here means Media Foundation COM interop or a third-party package, and this project has
/// one native dependency on purpose. So Windows reads WAV of any sample rate, channel count and
/// common bit depth, and says plainly what to do about anything else. That is the honest version of
/// the gap; see docs/CLI.md.
/// </para>
/// </remarks>
public static class AudioDecoder
{
    /// <summary>What the models are given regardless. They downsample to this anyway.</summary>
    public const int SampleRate = 16_000;

    private static readonly Log Log = new("audio");

    public sealed class DecodeException(string message) : Exception(message);

    /// <summary>Extensions worth offering in a file dialog.</summary>
    public static IReadOnlyList<string> OpenableExtensions { get; } = [".wav", ".wave"];

    /// <summary>Loads a recording as something the pipeline can chunk, time and compress.</summary>
    public static byte[] Load(string path)
    {
        if (!File.Exists(path)) throw new DecodeException($"No such file: {path}");

        var extension = Path.GetExtension(path).ToLowerInvariant();
        if (extension is not (".wav" or ".wave"))
        {
            throw new DecodeException(
                $"{Path.GetFileName(path)} is {extension}, and the Windows build reads WAV only -- "
                + ".NET has no built-in decoder for compressed audio and this project keeps its "
                + "native dependencies to one. Convert it first (ffmpeg -i in.m4a -ar 16000 -ac 1 "
                + "out.wav), or transcribe it from the macOS, iOS or Android build, which use the "
                + "system decoder.");
        }

        var started = DateTimeOffset.Now;
        var bytes = File.ReadAllBytes(path);
        if (IsAlreadyTarget(bytes))
        {
            // A re-encode here would be a lossy round trip that changes nothing.
            Log.Debug(() => "recording already in target format", new Dictionary<string, string>
            {
                ["file"] = Path.GetFileName(path),
                ["bytes"] = bytes.Length.ToString(),
            });
            return bytes;
        }

        var wav = Convert(bytes, Path.GetFileName(path));
        Log.Info(() => "decoded recording", new Dictionary<string, string>
        {
            ["file"] = Path.GetFileName(path),
            ["bytes"] = wav.Length.ToString(),
            ["ms"] = ((long)(DateTimeOffset.Now - started).TotalMilliseconds).ToString(),
        });
        return wav;
    }

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
        return AudioChunker.WrapInWavContainer(pcm);
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
