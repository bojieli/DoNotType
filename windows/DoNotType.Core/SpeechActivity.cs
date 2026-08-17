using System.Buffers.Binary;
using System.Reflection;
using Microsoft.ML.OnnxRuntime;
using Microsoft.ML.OnnxRuntime.Tensors;

namespace DoNotType.Core;

/// <summary>Whether a recording contains speech worth sending to a recogniser.</summary>
/// <remarks>
/// This runs the official Silero VAD v6.2.1 ONNX model. Its recurrent state and 64-sample context
/// are carried across the upstream 512-sample windows, then the upstream 0.5/0.35 hysteresis,
/// 100 ms end silence and 250 ms minimum speech duration finalise segments. It replaces the local
/// noise-floor heuristic, which rejected continuous speech when a recording contained no quiet
/// section from which to infer a floor.
/// </remarks>
public static class SpeechActivity
{
    public sealed record Reading(
        int SpeechMilliseconds,
        double MaximumProbability,
        double MeanProbability,
        double DurationSeconds)
    {
        public bool HasSpeech => SpeechMilliseconds > 0;

        public string Summary =>
            $"silero speech={SpeechMilliseconds}ms max={MaximumProbability:F3} "
            + $"mean={MeanProbability:F3} of {DurationSeconds:F2}s";
    }

    public const int SampleRate = 16_000;
    public const int WindowSamples = 512;
    public const float Threshold = 0.5f;
    public const float NegativeThreshold = 0.35f;
    public const int MinimumSpeechMilliseconds = 250;
    public const int MinimumSilenceMilliseconds = 100;

    private static readonly Lazy<InferenceSession> Model = new(
        CreateSession, LazyThreadSafetyMode.ExecutionAndPublication);

    /// <param name="pcm">16 kHz mono 16-bit little-endian samples, without a WAV header.</param>
    public static Reading Measure(ReadOnlySpan<byte> pcm, int sampleRate = SampleRate)
    {
        if (sampleRate != SampleRate)
        {
            throw new ArgumentException(
                $"Silero VAD expected {SampleRate} Hz audio, not {sampleRate} Hz.",
                nameof(sampleRate));
        }

        var sampleCount = pcm.Length / 2;
        var duration = sampleCount / (double)sampleRate;
        if (sampleCount == 0) return new Reading(0, 0, 0, duration);

        var probabilities = Probabilities(pcm, sampleCount);
        var speechSamples = FinalisedSpeechSamples(probabilities, sampleCount);
        return new Reading(
            (int)Math.Round(speechSamples * 1_000d / sampleRate),
            probabilities.Count == 0 ? 0 : probabilities.Max(),
            probabilities.Count == 0 ? 0 : probabilities.Average(value => (double)value),
            duration);
    }

    /// <param name="wav">A 16 kHz mono 16-bit PCM WAV, header and all.</param>
    public static Reading MeasureWav(byte[] wav)
    {
        var body = AudioChunker.PcmBody(wav)
            ?? throw new ArgumentException("The recording is not a 16 kHz mono PCM WAV.", nameof(wav));
        return Measure(body);
    }

    private static List<float> Probabilities(ReadOnlySpan<byte> pcm, int sampleCount)
    {
        var state = new float[2 * 128];
        var context = new float[64];
        var probabilities = new List<float>((sampleCount + WindowSamples - 1) / WindowSamples);

        for (var offset = 0; offset < sampleCount; offset += WindowSamples)
        {
            var input = new float[64 + WindowSamples];
            Array.Copy(context, input, context.Length);
            var count = Math.Min(WindowSamples, sampleCount - offset);
            for (var index = 0; index < count; index++)
            {
                input[64 + index] = BinaryPrimitives.ReadInt16LittleEndian(
                    pcm[((offset + index) * 2)..]) / 32_768f;
            }

            var values = new List<NamedOnnxValue>
            {
                NamedOnnxValue.CreateFromTensor(
                    "input", new DenseTensor<float>(input, [1, 576])),
                NamedOnnxValue.CreateFromTensor(
                    "state", new DenseTensor<float>(state, [2, 1, 128])),
                NamedOnnxValue.CreateFromTensor(
                    "sr", new DenseTensor<long>(new long[] { SampleRate }, Array.Empty<int>())),
            };

            using var outputs = Model.Value.Run(values);
            var output = outputs.First(value => value.Name == "output").AsTensor<float>();
            var nextState = outputs.First(value => value.Name == "stateN").AsTensor<float>();
            probabilities.Add(output[0, 0]);
            state = [.. nextState];
            Array.Copy(input, input.Length - context.Length, context, 0, context.Length);
        }
        return probabilities;
    }

    /// <summary>
    /// The part of upstream get_speech_timestamps that decides whether final speech exists.
    /// Timestamp padding and maximum-segment splitting cannot change that yes/no decision.
    /// </summary>
    private static int FinalisedSpeechSamples(
        IReadOnlyList<float> probabilities, int audioLengthSamples)
    {
        var minimumSpeechSamples = SampleRate * MinimumSpeechMilliseconds / 1_000;
        var minimumSilenceSamples = SampleRate * MinimumSilenceMilliseconds / 1_000;
        int? speechStart = null;
        int? possibleEnd = null;
        var total = 0;

        for (var index = 0; index < probabilities.Count; index++)
        {
            var probability = probabilities[index];
            var current = WindowSamples * index;

            if (probability >= Threshold)
            {
                possibleEnd = null;
                speechStart ??= current;
                continue;
            }

            if (probability >= NegativeThreshold || speechStart is not { } start) continue;
            possibleEnd ??= current;
            if (possibleEnd is not { } end || current - end < minimumSilenceSamples) continue;

            if (end - start > minimumSpeechSamples) total += end - start;
            speechStart = null;
            possibleEnd = null;
        }

        if (speechStart is { } tailStart && audioLengthSamples - tailStart > minimumSpeechSamples)
        {
            total += audioLengthSamples - tailStart;
        }
        return total;
    }

    private static InferenceSession CreateSession()
    {
        const string resource = "DoNotType.Core.silero_vad.onnx";
        using var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream(resource)
            ?? throw new InvalidOperationException($"Embedded Silero model '{resource}' is missing.");
        using var memory = new MemoryStream();
        stream.CopyTo(memory);

        using var options = new SessionOptions
        {
            InterOpNumThreads = 1,
            IntraOpNumThreads = 1,
            EnableCpuMemArena = true,
        };
        return new InferenceSession(memory.ToArray(), options);
    }
}
