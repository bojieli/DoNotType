namespace DoNotType.Core;

/// <summary>
/// Whether a recording contains anything worth sending.
/// </summary>
/// <remarks>
/// <para>
/// A speech model handed silence does not reliably return silence. Asked to transcribe three
/// seconds of room tone it will often produce a plausible sentence — the well-documented case is a
/// stock phrase like "Thank you." or a subtitle credit — and a dictation tool that types that into
/// somebody's document has invented words they never said. That is the single failure this project
/// exists to prevent, so a rule in PROMPT.md is not enough on its own:
/// </para>
/// <list type="bullet">
/// <item>
/// <b>Rule 7 only reaches model providers.</b> Deepgram, xAI and Mistral Voxtral are speech
/// recognition endpoints with no system instruction, so the rule that says "silent or
/// unintelligible audio returns an empty transcript" is never sent to them. Whisper-family
/// recognisers are exactly the ones most documented for this behaviour.
/// </item>
/// <item><b>An instruction is a request, not a guarantee</b>, even where it is delivered.</item>
/// </list>
/// <para>
/// A backend cannot hallucinate audio it never received. So the audio is checked here, before the
/// request, and that check is the only defence that holds for every backend.
/// </para>
/// <para>
/// It decides on <em>modulation</em> rather than loudness: speech has syllables, pauses and
/// plosives, so its frame energies vary; a fan, a hum or a mains buzz does not. Gating on volume
/// would discard somebody dictating in an open-plan office, a much worse failure than the one being
/// prevented. Ported from `Sources/DoNotTypeCore/SpeechActivity.swift`, thresholds and all — see
/// `eval/audio/silence/README.md` for the measurements they came from.
/// </para>
/// </remarks>
public static class SpeechActivity
{
    /// <param name="SpeechMilliseconds">
    /// How much audio sat clearly above the recording's own noise floor.
    /// </param>
    /// <param name="NoiseFloorDecibels">The recording's own floor, in dBFS. Roughly the room.</param>
    /// <param name="PeakDecibels">The loudest 20 ms in the recording, in dBFS.</param>
    public sealed record Reading(
        int SpeechMilliseconds,
        double NoiseFloorDecibels,
        double PeakDecibels,
        double DurationSeconds)
    {
        public bool HasSpeech => SpeechMilliseconds >= MinimumSpeechMilliseconds;

        /// <summary>
        /// For the log, where a user who disagrees with the decision has to be able to see why.
        /// </summary>
        public string Summary =>
            $"speech={SpeechMilliseconds}ms floor={NoiseFloorDecibels:F1}dB "
            + $"peak={PeakDecibels:F1}dB of {DurationSeconds:F2}s";
    }

    /// <summary>Below this, nothing is sent. See the measurements in the README.</summary>
    public const int MinimumSpeechMilliseconds = 200;

    /// <summary>
    /// How far above the recording's own floor a frame has to sit to count as speech. Roughly the
    /// difference between a room and somebody talking in it; steady noise never reaches it,
    /// whatever its absolute level.
    /// </summary>
    private const double MarginDecibels = 8.0;

    /// <summary>
    /// A floor below which nothing counts, however far above the noise it is. Guards the
    /// degenerate case where a single dithered sample in digital silence is infinitely above the
    /// floor, and is set low enough that real speech never reaches it.
    /// </summary>
    private const double AbsoluteFloorDecibels = -65.0;

    private const int FrameMilliseconds = 20;

    /// <param name="pcm">16 kHz mono 16-bit little-endian samples, without a WAV header.</param>
    public static Reading Measure(ReadOnlySpan<byte> pcm, int sampleRate = 16_000)
    {
        var frameSamples = sampleRate * FrameMilliseconds / 1_000;
        var sampleCount = pcm.Length / 2;
        var duration = sampleCount / (double)sampleRate;

        if (sampleCount < frameSamples) return new Reading(0, -120, -120, duration);

        var levels = new List<double>(sampleCount / frameSamples);
        for (var start = 0; start + frameSamples <= sampleCount; start += frameSamples)
        {
            double energy = 0;
            for (var index = start; index < start + frameSamples; index++)
            {
                double value = BitConverter.ToInt16(pcm[(index * 2)..(index * 2 + 2)]);
                energy += value * value;
            }
            var mean = energy / frameSamples;
            // dBFS, with a floor so digital silence is a number rather than negative infinity.
            levels.Add(10 * Math.Log10(mean / (32_768.0 * 32_768.0) + 1e-12));
        }

        if (levels.Count == 0) return new Reading(0, -120, -120, duration);

        // The tenth percentile rather than the minimum: one anomalously quiet frame should not
        // define the room, and speech contains real pauses that sit at the floor.
        var sorted = levels.Order().ToList();
        var floor = sorted[Math.Min(sorted.Count - 1, sorted.Count / 10)];
        var peak = sorted[^1];

        var speaking = levels.Count(
            level => level > floor + MarginDecibels && level > AbsoluteFloorDecibels);
        return new Reading(speaking * FrameMilliseconds, floor, peak, duration);
    }

    /// <param name="wav">A 16 kHz mono 16-bit WAV, header and all.</param>
    public static Reading MeasureWav(byte[] wav)
    {
        var body = AudioChunker.PcmBody(wav);
        return body is null ? new Reading(0, -120, -120, 0) : Measure(body);
    }
}
