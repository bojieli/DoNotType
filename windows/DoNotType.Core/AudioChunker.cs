namespace DoNotType.Core;

/// <summary>
/// Splits a long recording on silence so it can be transcribed in parallel.
/// </summary>
/// <remarks>
/// A port of <c>AudioChunker.swift</c>. A nine-minute dictation is roughly 17,000 audio tokens in
/// one request, and the user has already stopped talking and is waiting. Splitting on silence and
/// running the pieces concurrently turns that into roughly the cost of the slowest chunk.
///
/// Two rules make the seams survivable. Cuts land in silence, never mid-word. And every chunk is
/// sent with the <em>same</em> screen context, which is what keeps a name spelled consistently
/// across a boundary -- the alternative is chunk three spelling something differently from chunk
/// two for no reason the user can see.
/// </remarks>
public static class AudioChunker
{
    /// <summary>Below this, one request is faster than the coordination.</summary>
    public const double ThresholdSeconds = 90;

    private const int SampleRate = 16_000;
    private const int BytesPerSample = 2;
    private const int BytesPerSecond = SampleRate * BytesPerSample;

    public readonly record struct Chunk(int Index, byte[] Data, double StartSeconds, double DurationSeconds);

    /// <summary>Splits 16-bit PCM WAV data, or returns one chunk when it is short enough.</summary>
    /// <param name="targetSeconds">
    /// Preferred chunk length. Cuts are placed at the quietest point in a window around it rather
    /// than exactly on it.
    /// </param>
    /// <param name="windowSeconds">How far either side of the target to search for silence.</param>
    public static IReadOnlyList<Chunk> Split(
        byte[] wav, double targetSeconds = 60, double windowSeconds = 15)
    {
        var body = PcmBody(wav);
        if (body is null)
        {
            return [new Chunk(0, wav, 0, 0)];
        }

        var duration = body.Length / (double)BytesPerSecond;
        if (duration <= ThresholdSeconds)
        {
            return [new Chunk(0, wav, 0, duration)];
        }

        var chunks = new List<Chunk>();
        var targetBytes = (int)(targetSeconds * BytesPerSecond);
        var windowBytes = (int)(windowSeconds * BytesPerSecond);
        var start = 0;

        while (start < body.Length)
        {
            // A final piece shorter than the search window is folded into this one rather than left
            // as a two-second fragment that transcribes badly on its own.
            if (body.Length - start <= targetBytes + windowBytes)
            {
                chunks.Add(MakeChunk(chunks.Count, body, start, body.Length));
                break;
            }

            var cut = QuietestCut(body, start + targetBytes, windowBytes);
            chunks.Add(MakeChunk(chunks.Count, body, start, cut));
            start = cut;
        }
        return chunks;
    }

    private static Chunk MakeChunk(int index, byte[] body, int from, int to)
    {
        var samples = body[from..to];
        return new Chunk(
            index,
            WrapInWavContainer(samples),
            from / (double)BytesPerSecond,
            samples.Length / (double)BytesPerSecond);
    }

    /// <summary>Finds the middle of the quietest 100 ms inside the search window.</summary>
    /// <remarks>
    /// Quietest rather than "first below a threshold": an absolute threshold tuned for a quiet room
    /// finds no silence at all on a train, and would then cut mid-word. The <em>middle</em> rather
    /// than the start, so both neighbours keep a little silence -- a chunk whose audio begins on
    /// the first sample of a word tends to lose that word's opening consonant.
    /// </remarks>
    internal static int QuietestCut(byte[] body, int centre, int window)
    {
        var probe = Math.Max(BytesPerSample, BytesPerSecond / 10); // 100 ms
        var low = Math.Max(0, centre - window);
        var high = Math.Min(body.Length - probe, centre + window);
        if (low >= high)
        {
            return Math.Min(centre, body.Length);
        }

        var quietest = centre;
        var quietestEnergy = double.MaxValue;
        // Coarse stride: energy every 20 ms rather than at every offset. The cut only has to land
        // somewhere quiet, not at the single quietest byte.
        var stride = Math.Max(BytesPerSample, BytesPerSecond / 50);

        for (var position = low; position < high; position += stride)
        {
            var energy = MeanEnergy(body, position, probe);
            if (energy < quietestEnergy)
            {
                quietestEnergy = energy;
                quietest = position;
            }
        }

        // Align to a sample boundary; a cut mid-sample produces a click.
        var middle = Math.Min(quietest + probe / 2, body.Length);
        return middle - (middle % BytesPerSample);
    }

    private static double MeanEnergy(byte[] body, int offset, int length)
    {
        var total = 0.0;
        var count = 0;
        var end = Math.Min(offset + length, body.Length - 1);

        for (var index = offset; index < end; index += 2)
        {
            var sample = (short)(body[index] | (body[index + 1] << 8));
            total += (double)sample * sample;
            count++;
        }
        return count == 0 ? double.MaxValue : total / count;
    }

    /// <summary>Locates the <c>data</c> chunk, so a WAV carrying extra metadata still works.</summary>
    internal static byte[]? PcmBody(byte[] wav)
    {
        if (wav.Length <= 44 || wav[0] != 'R' || wav[1] != 'I' || wav[2] != 'F' || wav[3] != 'F')
        {
            return null;
        }

        var cursor = 12;
        while (cursor + 8 <= wav.Length)
        {
            var size = wav[cursor + 4] | (wav[cursor + 5] << 8)
                | (wav[cursor + 6] << 16) | (wav[cursor + 7] << 24);

            if (wav[cursor] == 'd' && wav[cursor + 1] == 'a'
                && wav[cursor + 2] == 't' && wav[cursor + 3] == 'a')
            {
                var start = cursor + 8;
                var end = Math.Min(start + size, wav.Length);
                return start < end ? wav[start..end] : null;
            }
            cursor += 8 + size + (size % 2); // chunks are word-aligned
        }
        return null;
    }

    internal static byte[] WrapInWavContainer(byte[] pcm)
    {
        using var stream = new MemoryStream(44 + pcm.Length);
        using var writer = new BinaryWriter(stream);

        writer.Write("RIFF"u8);
        writer.Write(36 + pcm.Length);
        writer.Write("WAVE"u8);
        writer.Write("fmt "u8);
        writer.Write(16);
        writer.Write((short)1); // PCM
        writer.Write((short)1); // mono
        writer.Write(SampleRate);
        writer.Write(BytesPerSecond);
        writer.Write((short)BytesPerSample);
        writer.Write((short)16);
        writer.Write("data"u8);
        writer.Write(pcm.Length);
        writer.Write(pcm);
        writer.Flush();
        return stream.ToArray();
    }

    /// <summary>Joins transcribed chunks.</summary>
    /// <remarks>
    /// Chunks are cut in silence, so a plain join with a space is right -- inserting punctuation
    /// would be inventing content, and the fidelity rules forbid that as firmly at a seam as
    /// anywhere else.
    /// </remarks>
    public static string Stitch(IEnumerable<string> pieces) =>
        string.Join(" ", pieces.Select(piece => piece.Trim()).Where(piece => piece.Length > 0));
}
