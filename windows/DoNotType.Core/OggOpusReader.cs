using System.Runtime.InteropServices;
using System.Text;

namespace DoNotType.Core;

/// <summary>
/// Reads an Ogg Opus file back into 16 kHz mono PCM.
/// </summary>
/// <remarks>
/// <para>
/// The mirror of <see cref="OggOpusWriter"/>, and the reason it exists here rather than being left
/// to the platform: Windows has no Opus decoder in the box. macOS and iOS get one from CoreAudio
/// and Android from MediaCodec, so this is the one platform that has to demux and decode Opus
/// itself — the same asymmetry that already makes <see cref="OpusEncoder"/> the only libopus
/// dependency in the project. libopus is already required for the encode side, so the decode side
/// costs a second binding and this file, not a new dependency.
/// </para>
/// <para>
/// Two details of the format are load-bearing and easy to get silently wrong. <b>Pre-skip</b>: the
/// encoder's first samples are priming and must be discarded, or every transcript starts with a
/// click and drifts against the timestamps. <b>The 48 kHz clock</b>: Opus always decodes at 48 kHz
/// regardless of what went in, so the output is resampled down to the 16 kHz the rest of the
/// pipeline assumes rather than trusted to arrive at it.
/// </para>
/// <para>
/// Packets spanning pages are joined before decoding. A 255-byte lacing value means "continues in
/// the next segment", which is the case a naive reader drops — and dropping it loses audio in the
/// middle of a recording rather than failing outright, which is the worse failure.
/// </para>
/// </remarks>
public static class OggOpusReader
{
    private const string Library = "opus";

    /// <summary>Opus decodes at 48 kHz whatever was encoded. Not a choice; a property of the codec.</summary>
    private const int DecodeRate = 48_000;

    /// <summary>Longest packet Opus defines: 120 ms at 48 kHz.</summary>
    private const int MaxFrameSamples = DecodeRate / 1000 * 120;

    private static readonly Log Log = new("opus");

    /// <summary>True when the bytes are an Ogg stream carrying Opus.</summary>
    public static bool IsOggOpus(ReadOnlySpan<byte> data) =>
        data.Length > 36
        && data[0] == 'O' && data[1] == 'g' && data[2] == 'g' && data[3] == 'S'
        && FindOpusHead(data);

    private static bool FindOpusHead(ReadOnlySpan<byte> data)
    {
        // The identification header is the first packet of the first page, so it sits a short way
        // in — no need to walk the whole file to answer "is this Opus rather than Vorbis?".
        var limit = Math.Min(data.Length - 8, 512);
        for (var i = 0; i < limit; i++)
        {
            if (data.Slice(i, 8).SequenceEqual("OpusHead"u8)) return true;
        }
        return false;
    }

    /// <summary>
    /// Decodes to a 16 kHz mono WAV, or throws with a message naming what went wrong.
    /// </summary>
    public static byte[] DecodeToWav(byte[] ogg, string name)
    {
        if (!OpusEncoder.IsAvailable)
        {
            throw new AudioDecoder.DecodeException(
                $"{name} is Opus, and libopus could not be loaded. Put opus.dll beside the "
                + "executable — it is the same library the encoder needs, so a build that can "
                + "compress a dictation can also read one back.");
        }

        var stream = Demux(ogg, name);
        var decoder = DecoderCreate(DecodeRate, 1, out var error);
        if (decoder == IntPtr.Zero || error != 0)
        {
            throw new AudioDecoder.DecodeException($"{name}: opus_decoder_create failed ({error}).");
        }

        try
        {
            var pcm48 = new List<short>(capacity: 48_000 * 8);
            var frame = new short[MaxFrameSamples];
            var skip = stream.PreSkip;

            foreach (var packet in stream.Packets)
            {
                if (packet.Length == 0) continue;

                int decoded;
                unsafe
                {
                    fixed (byte* input = packet)
                    fixed (short* output = frame)
                    {
                        decoded = Decode(decoder, input, packet.Length, output, MaxFrameSamples, 0);
                    }
                }
                if (decoded < 0)
                {
                    // One bad packet is a scratch in the file, not a reason to lose the recording.
                    Log.Warn(() => "skipped an undecodable Opus packet",
                        new Dictionary<string, string> { ["code"] = decoded.ToString() });
                    continue;
                }

                var start = 0;
                if (skip > 0)
                {
                    // Priming samples the encoder added; audible as a click and a timing shift if
                    // they survive.
                    var dropped = Math.Min(skip, decoded);
                    start = dropped;
                    skip -= dropped;
                }
                for (var i = start; i < decoded; i++) pcm48.Add(frame[i]);
            }

            if (pcm48.Count == 0)
            {
                throw new AudioDecoder.DecodeException($"{name} decoded to no audio at all.");
            }

            var pcm16 = Resample(pcm48);
            Log.Debug(() => "decoded Ogg Opus", new Dictionary<string, string>
            {
                ["file"] = name,
                ["packets"] = stream.Packets.Count.ToString(),
                ["seconds"] = (pcm16.Length / (double)AudioDecoder.SampleRate).ToString("F1"),
            });

            var bytes = new byte[pcm16.Length * 2];
            Buffer.BlockCopy(pcm16, 0, bytes, 0, bytes.Length);
            return AudioChunker.WrapInWavContainer(bytes);
        }
        finally
        {
            DecoderDestroy(decoder);
        }
    }

    private sealed record Stream(List<byte[]> Packets, int PreSkip, int Channels);

    /// <summary>
    /// Walks the Ogg pages and reassembles Opus packets, dropping the two header packets.
    /// </summary>
    private static Stream Demux(byte[] ogg, string name)
    {
        var packets = new List<byte[]>();
        var preSkip = 0;
        var channels = 1;
        var partial = new List<byte>();
        var offset = 0;
        var sawHead = false;
        var headersSeen = 0;

        while (offset + 27 <= ogg.Length)
        {
            if (ogg[offset] != 'O' || ogg[offset + 1] != 'g'
                || ogg[offset + 2] != 'g' || ogg[offset + 3] != 'S')
            {
                throw new AudioDecoder.DecodeException(
                    $"{name} is not a well-formed Ogg stream — no page header where one was "
                    + "expected. It may be truncated.");
            }

            int segmentCount = ogg[offset + 26];
            var lacingStart = offset + 27;
            if (lacingStart + segmentCount > ogg.Length) break;

            var body = lacingStart + segmentCount;
            var cursor = body;

            for (var segment = 0; segment < segmentCount; segment++)
            {
                int length = ogg[lacingStart + segment];
                if (cursor + length > ogg.Length) break;

                partial.AddRange(new ReadOnlySpan<byte>(ogg, cursor, length).ToArray());
                cursor += length;

                // Anything short of 255 ends the packet; exactly 255 means it continues.
                if (length == 255) continue;

                var packet = partial.ToArray();
                partial.Clear();
                if (packet.Length == 0) continue;

                // The two mandatory headers carry configuration rather than audio.
                if (!sawHead && packet.Length >= 19
                    && packet.AsSpan(0, 8).SequenceEqual("OpusHead"u8))
                {
                    channels = packet[9];
                    preSkip = packet[10] | (packet[11] << 8);
                    sawHead = true;
                    headersSeen++;
                    continue;
                }
                if (headersSeen == 1 && packet.Length >= 8
                    && packet.AsSpan(0, 8).SequenceEqual("OpusTags"u8))
                {
                    headersSeen++;
                    continue;
                }
                packets.Add(packet);
            }
            offset = cursor;
        }

        if (!sawHead)
        {
            throw new AudioDecoder.DecodeException(
                $"{name} is an Ogg file, but the stream inside it is not Opus. Only Opus is "
                + "supported here; convert Vorbis to WAV first.");
        }
        return new Stream(packets, preSkip, channels);
    }

    /// <summary>
    /// 48 kHz to 16 kHz. An exact 3:1 ratio, so this is an average of each group of three rather
    /// than an interpolation — cheaper, and it rejects the high frequencies that would otherwise
    /// alias down into the speech band.
    /// </summary>
    private static short[] Resample(List<short> samples)
    {
        var output = new short[samples.Count / 3];
        for (var i = 0; i < output.Length; i++)
        {
            var total = samples[i * 3] + samples[i * 3 + 1] + samples[i * 3 + 2];
            output[i] = (short)Math.Clamp(total / 3, short.MinValue, short.MaxValue);
        }
        return output;
    }

    [DllImport(Library, EntryPoint = "opus_decoder_create", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr DecoderCreate(int sampleRate, int channels, out int error);

    [DllImport(Library, EntryPoint = "opus_decoder_destroy", CallingConvention = CallingConvention.Cdecl)]
    private static extern void DecoderDestroy(IntPtr decoder);

    [DllImport(Library, EntryPoint = "opus_decode", CallingConvention = CallingConvention.Cdecl)]
    private static extern unsafe int Decode(
        IntPtr decoder, byte* data, int length, short* pcm, int frameSize, int decodeFec);
}
