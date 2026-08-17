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

    public readonly record struct BoundaryPolicy(
        double MinimumSeconds = 45,
        double TargetSeconds = 60,
        double HorizonSeconds = 75,
        double MinimumPauseSeconds = 0.32,
        double PreferredPauseSeconds = 0.5);

    public static readonly BoundaryPolicy DefaultPolicy = new();

    /// <summary>Length of a decoded 16 kHz mono recording, from its header.</summary>
    public static double DurationSeconds(byte[] wav)
    {
        var body = PcmBody(wav);
        return body is null ? 0 : body.Length / (double)(AudioDecoder.SampleRate * 2);
    }

    public readonly record struct Chunk(int Index, byte[] Data, double StartSeconds, double DurationSeconds);

    /// <summary>Splits 16-bit PCM WAV data, or returns one chunk when it is short enough.</summary>
    /// <remarks>A cut is made only in an energy-qualified pause. No pause means no split.</remarks>
    public static IReadOnlyList<Chunk> Split(byte[] wav, BoundaryPolicy? policy = null)
    {
        var boundaries = policy ?? DefaultPolicy;
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
        var start = 0;

        while (start < body.Length)
        {
            if (body.Length - start <= boundaries.TargetSeconds * BytesPerSecond)
            {
                chunks.Add(MakeChunk(chunks.Count, body, start, body.Length));
                break;
            }

            var tail = body[start..];
            var relativeCut = BestBoundary(tail, boundaries);
            if (relativeCut is null)
            {
                chunks.Add(MakeChunk(chunks.Count, body, start, body.Length));
                break;
            }
            var cut = start + relativeCut.Value;
            if ((body.Length - cut) / (double)BytesPerSecond < boundaries.MinimumSeconds)
            {
                chunks.Add(MakeChunk(chunks.Count, body, start, body.Length));
                break;
            }
            chunks.Add(MakeChunk(chunks.Count, body, start, cut));
            start = cut;
        }
        return chunks;
    }

    /// <summary>Incremental pause segmenter used by live microphone capture.</summary>
    public sealed class StreamingSegmenter(BoundaryPolicy? policy = null)
    {
        private readonly BoundaryPolicy _policy = policy ?? DefaultPolicy;
        private readonly List<byte> _pending = [];
        private long _totalBytes;
        private long _startBytes;
        private int _nextIndex;
        private bool _emittedFirst;
        private int _bytesAtLastAnalysis;

        public IReadOnlyList<Chunk> Append(byte[] pcm)
        {
            if (pcm.Length == 0) return [];
            _pending.AddRange(pcm);
            _totalBytes += pcm.Length;
            var ready = new List<Chunk>();

            while (ShouldAnalyse())
            {
                var cut = BestBoundary([.. _pending], _policy);
                if (cut is null) break;
                var samples = _pending.GetRange(0, cut.Value).ToArray();
                ready.Add(Make(samples));
                _pending.RemoveRange(0, cut.Value);
                _startBytes += cut.Value;
                _emittedFirst = true;
                _bytesAtLastAnalysis = 0;
            }
            if (ready.Count == 0 && CanConsider()) _bytesAtLastAnalysis = _pending.Count;
            return ready;
        }

        public Chunk? Finish()
        {
            if (_pending.Count == 0) return null;
            var samples = _pending.ToArray();
            _pending.Clear();
            var chunk = Make(samples);
            _startBytes += samples.Length;
            return chunk;
        }

        private bool CanConsider() => !_emittedFirst
            ? _totalBytes / (double)BytesPerSecond > ThresholdSeconds
            : _pending.Count / (double)BytesPerSecond >= _policy.TargetSeconds;

        private bool ShouldAnalyse() => CanConsider()
            && (_bytesAtLastAnalysis == 0
                || _pending.Count - _bytesAtLastAnalysis >= BytesPerSecond / 5);

        private Chunk Make(byte[] samples) => new(
            _nextIndex++, WrapInWavContainer(samples), _startBytes / (double)BytesPerSecond,
            samples.Length / (double)BytesPerSecond);
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

    private readonly record struct PauseCandidate(
        int Cut, double Seconds, double Duration, double Depth);

    /// <summary>
    /// Returns the best energy-qualified pause, or null rather than cutting speech. This only
    /// chooses a split point; <see cref="SpeechActivity"/> uses Silero to decide whether to send it.
    /// </summary>
    internal static int? BestBoundary(byte[] body, BoundaryPolicy? policy = null)
    {
        var boundaries = policy ?? DefaultPolicy;
        const int frameMilliseconds = 20;
        const int frameBytes = BytesPerSecond * frameMilliseconds / 1000;
        var frameCount = body.Length / frameBytes;
        if (frameCount < 3) return null;

        var levels = new double[frameCount];
        for (var frame = 0; frame < frameCount; frame++)
        {
            double energy = 0;
            var from = frame * frameBytes;
            for (var index = from; index + 1 < from + frameBytes; index += 2)
            {
                var sample = (short)(body[index] | body[index + 1] << 8);
                energy += (double)sample * sample;
            }
            levels[frame] = 10 * Math.Log10(
                energy / (frameBytes / 2) / (32_768d * 32_768d) + 1e-12);
        }

        var sorted = levels.Order().ToArray();
        var floor = sorted[Math.Min(sorted.Length - 1, sorted.Length / 50)];
        var threshold = Math.Max(-65, floor + 8);
        var speaking = levels.Select(level => level > threshold).ToArray();
        var minimumFrames = Math.Max(
            1, (int)Math.Ceiling(boundaries.MinimumPauseSeconds * 1000 / frameMilliseconds));
        const int evidenceFrames = 5;
        const int evidenceWindow = 100;
        var candidates = new List<PauseCandidate>();

        for (var frame = 0; frame < speaking.Length;)
        {
            if (speaking[frame])
            {
                frame++;
                continue;
            }
            var runStart = frame;
            while (frame < speaking.Length && !speaking[frame]) frame++;
            var runEnd = frame;
            if (runEnd - runStart < minimumFrames) continue;

            var before = speaking[Math.Max(0, runStart - evidenceWindow)..runStart].Count(x => x);
            var after = speaking[runEnd..Math.Min(speaking.Length, runEnd + evidenceWindow)].Count(x => x);
            if (before < evidenceFrames || after < evidenceFrames) continue;

            var middle = runStart + (runEnd - runStart) / 2;
            var seconds = middle * frameBytes / (double)BytesPerSecond;
            if (seconds < boundaries.MinimumSeconds) continue;
            var gap = levels[runStart..runEnd].Average();
            candidates.Add(new PauseCandidate(
                middle * frameBytes, seconds, (runEnd - runStart) * 0.02,
                Math.Max(0, threshold - gap)));
        }

        var preferred = candidates.Where(candidate => candidate.Seconds <= boundaries.HorizonSeconds)
            .ToArray();
        if (preferred.Length > 0)
        {
            return preferred.MaxBy(candidate => BoundaryScore(candidate, boundaries)).Cut;
        }
        return candidates.Count == 0 ? null : candidates.MinBy(candidate => candidate.Seconds).Cut;
    }

    private static double BoundaryScore(PauseCandidate candidate, BoundaryPolicy policy) =>
        (candidate.Duration >= policy.PreferredPauseSeconds ? 3 : 0)
        + Math.Min(2, candidate.Duration) * 4
        + Math.Min(20, candidate.Depth) / 10
        - Math.Abs(candidate.Seconds - policy.TargetSeconds);

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
