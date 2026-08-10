namespace DoNotType.Core;

/// <summary>
/// Packages raw Opus packets into an Ogg stream.
/// </summary>
/// <remarks>
/// A port of <c>OggOpusWriter.swift</c>, checked byte-for-byte against the same reference stream
/// the Kotlin port passes (<c>eval/conformance/ogg-reference.bin</c>). The container is the part
/// most likely to be subtly wrong in a way that still produces a file decoders mostly accept — the
/// Swift version shipped two such bugs, one of which only surfaced as a message at the very end of
/// ffprobe's output.
///
/// Two mistakes worth not repeating, since both produced files that looked fine. Ending the stream
/// with an empty page to carry the end-of-stream flag is a zero-length Opus packet, which decoders
/// read past and then reject. And one packet per page costs 28 bytes of header per 20 ms frame —
/// 1.4 kB/s, nearly as much again as a 16 kbps stream.
/// </remarks>
public sealed class OggOpusWriter
{
    /// <summary>Opus reports timestamps at 48 kHz whatever the capture rate. A granule position in
    /// the wrong clock makes the file play at the wrong speed, or be rejected outright.</summary>
    public const int OpusClockRate = 48_000;

    /// <summary>50 × 20 ms per page. Larger pages save nothing measurable and delay nothing, since
    /// the whole file is written before any of it is sent.</summary>
    private const int PacketsPerPage = 50;

    private readonly int _sampleRate;
    private readonly int _channels;
    private readonly int _preSkip;
    private readonly uint _serial;

    private readonly MemoryStream _output = new();
    private readonly List<byte[]> _pending = [];
    private uint _sequence;
    private long _granule;
    private long _pendingGranule;

    public OggOpusWriter(
        int sampleRate = 16_000, int channels = 1, int preSkip = 312, uint serial = 0x646E7401)
    {
        _sampleRate = sampleRate;
        _channels = channels;
        _preSkip = preSkip;
        _serial = serial;
    }

    /// <summary>Writes the two mandatory headers. Must be called before any audio.</summary>
    public void Begin()
    {
        WritePage([OpusHead()], headerType: 0x02, granule: 0);
        WritePage([OpusTags()], headerType: 0x00, granule: 0);
    }

    /// <summary>Appends one encoded Opus packet.</summary>
    /// <param name="frameCount">
    /// Decoded samples the packet represents at the source rate. Converted to the 48 kHz Opus clock
    /// internally, because that is what a granule position must be expressed in.
    /// </param>
    public void Append(byte[] packet, int frameCount)
    {
        _granule += (long)frameCount * OpusClockRate / Math.Max(_sampleRate, 1);
        _pending.Add(packet);
        _pendingGranule = _granule;

        if (_pending.Count >= PacketsPerPage)
        {
            FlushPending(endOfStream: false);
        }
    }

    /// <summary>Finishes the stream and returns the complete file.</summary>
    public byte[] Finish()
    {
        FlushPending(endOfStream: true);
        return _output.ToArray();
    }

    private void FlushPending(bool endOfStream)
    {
        if (_pending.Count == 0)
        {
            return;
        }
        WritePage(_pending.ToArray(), endOfStream ? (byte)0x04 : (byte)0x00, _pendingGranule);
        _pending.Clear();
    }

    private byte[] OpusHead()
    {
        using var stream = new MemoryStream();
        using var writer = new BinaryWriter(stream);
        writer.Write("OpusHead"u8);
        writer.Write((byte)1); // version
        writer.Write((byte)_channels);
        writer.Write((ushort)_preSkip);
        writer.Write((uint)_sampleRate); // informational only
        writer.Write((ushort)0); // output gain
        writer.Write((byte)0); // channel mapping family
        writer.Flush();
        return stream.ToArray();
    }

    private static byte[] OpusTags()
    {
        var vendor = "DoNotType"u8.ToArray();
        using var stream = new MemoryStream();
        using var writer = new BinaryWriter(stream);
        writer.Write("OpusTags"u8);
        writer.Write((uint)vendor.Length);
        writer.Write(vendor);
        writer.Write((uint)0); // no user comments
        writer.Flush();
        return stream.ToArray();
    }

    /// <summary>Builds one Ogg page.</summary>
    /// <remarks>
    /// Packets larger than 255×255 bytes would have to span pages. A 20 ms Opus frame at any sane
    /// bitrate is a few hundred bytes, so the case cannot arise and is not handled — silently
    /// truncating would be worse than not supporting it.
    /// </remarks>
    private void WritePage(byte[][] payloads, byte headerType, long granule)
    {
        var segments = new List<byte>();
        var body = new List<byte>();

        foreach (var payload in payloads)
        {
            var remaining = payload.Length;
            while (remaining >= 255)
            {
                segments.Add(255);
                remaining -= 255;
            }
            segments.Add((byte)remaining);
            body.AddRange(payload);
        }

        using var stream = new MemoryStream();
        using (var writer = new BinaryWriter(stream, System.Text.Encoding.UTF8, leaveOpen: true))
        {
            writer.Write("OggS"u8);
            writer.Write((byte)0); // stream structure version
            writer.Write(headerType);
            writer.Write(granule);
            writer.Write(_serial);
            writer.Write(_sequence);
            writer.Write((uint)0); // CRC placeholder
            writer.Write((byte)segments.Count);
            writer.Write(segments.ToArray());
            writer.Write(body.ToArray());
        }

        _sequence++;

        // The checksum covers the whole page with its own field zeroed, then replaces it — which is
        // why it cannot be written above.
        var page = stream.ToArray();
        var checksum = Crc32(page);
        page[22] = (byte)(checksum & 0xFF);
        page[23] = (byte)((checksum >> 8) & 0xFF);
        page[24] = (byte)((checksum >> 16) & 0xFF);
        page[25] = (byte)((checksum >> 24) & 0xFF);

        _output.Write(page, 0, page.Length);
    }

    /// <summary>
    /// Ogg's CRC-32: polynomial 0x04C11DB7, no reflection, zero seed — <em>not</em> zip's CRC-32,
    /// which produces a wrong-but-plausible value that decoders reject.
    /// </summary>
    public static uint Crc32(ReadOnlySpan<byte> data)
    {
        uint crc = 0;
        foreach (var value in data)
        {
            crc ^= (uint)value << 24;
            for (var bit = 0; bit < 8; bit++)
            {
                crc = (crc & 0x80000000) != 0 ? (crc << 1) ^ 0x04C11DB7 : crc << 1;
            }
        }
        return crc;
    }
}
