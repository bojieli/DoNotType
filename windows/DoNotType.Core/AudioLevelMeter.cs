namespace DoNotType.Core;

/// <summary>
/// Turns captured samples into the bars the recording pill draws.
/// </summary>
/// <remarks>
/// <para>
/// <b>Why this is not a multiplier.</b> The meter used to be <c>level * 6</c> clamped to 1 — a
/// linear scale, on a signal whose useful range spans 50 dB, and here it was fed the peak of half a
/// second rather than the energy of a frame, so it pinned even harder than the macOS version it was
/// ported from. Measured over the 20 ms frames of every speech fixture in `eval/audio/` in which
/// somebody is actually talking, that scale spent 4–77% of them flat against the top of the meter:
/// 77% on `port-number`, 59% on the shared `speech.wav`. It could report that audio was arriving
/// and nothing else, while at the other end it drew room tone at −58 dBFS as 0.01 of a bar.
/// </para>
/// <para>
/// Loudness is measured in decibels because that is how it is heard, so the scale is decibels, and
/// the span comes from the same measurements:
/// </para>
/// <list type="table">
/// <item><term>digital silence</term><description>−240 dBFS → 0.00</description></item>
/// <item><term>room tone</term><description>−58 dBFS → 0.04</description></item>
/// <item><term>quiet speech</term><description>−44 dBFS → 0.29</description></item>
/// <item><term>conversational speech</term><description>−21 dBFS → 0.72</description></item>
/// <item><term>loud speech</term><description>−14 dBFS → 0.85</description></item>
/// <item><term>the loudest frame in any fixture</term><description>−5 dBFS → 1.00</description></item>
/// </list>
/// <para>
/// Speech lands in the top third and moves visibly within it, silence is flat, and a full bar means
/// what a full bar should mean: the input is at the edge of clipping. Ported from
/// `Sources/DoNotTypeCore/AudioLevelMeter.swift`, constants and all, and held to the same numbers
/// by the same fixtures.
/// </para>
/// <para>
/// <b>Why frames rather than a smoothed value.</b> The pill draws a moving history, so each bar is
/// a moment rather than a running average, and the shape that walks across it is the envelope of
/// the speech. Smoothing would flatten exactly the detail that makes the meter read as somebody's
/// voice rather than as an animation playing next to it. Silence is a flat line that keeps
/// scrolling: the microphone is live and hearing nothing, which is a different report from a frozen
/// meter and the one somebody who is not being heard needs to see.
/// </para>
/// </remarks>
public sealed class AudioLevelMeter
{
    /// <param name="Level">0…1, ready to scale a bar height by.</param>
    /// <param name="IsClipping">
    /// Samples in here were clamped at the rail, so the recording is distorted before any backend
    /// sees it. Usually input gain set too high, which nothing else in the app would ever tell the
    /// user. Counted rather than inferred from the level: speech peaks run about 12 dB above its
    /// own energy, so by the time a frame's energy is near full scale its peaks have been flattened
    /// for a long while.
    /// </param>
    public readonly record struct Bar(double Level, bool IsClipping)
    {
        public static readonly Bar Silent = new(0, false);
    }

    /// <summary>An empty bar. Below room tone, so a quiet room reads as flat.</summary>
    public const double FloorDecibels = -60.0;

    /// <summary>
    /// A full bar. Just under the loudest frame measured in any fixture, so a voice recorded at a
    /// sensible level uses the top of the meter without living there.
    /// </summary>
    public const double CeilingDecibels = -6.0;

    /// <summary>
    /// A sample this loud is at the rail: 0.21 dB below full scale, which nothing undamaged has any
    /// reason to sit at.
    /// </summary>
    public const int RailAmplitude = 32_000;

    /// <summary>
    /// How many samples at the rail make a frame a clipped one — half a millisecond of staying
    /// there rather than passing through. Measured over the speech fixtures, the share of bars
    /// marked at ×1 / ×1.5 / ×2 playback gain: `real-brand` 0.6% / 10.5% / 24.0%, `real-acronym`
    /// 0.6% / 5.4% / 12.3%, everything else silent at its own gain. See the Swift original for the
    /// whole table.
    /// </summary>
    public const int RailSamplesPerFrame = 8;

    /// <summary>Twenty milliseconds resolves syllables without making the meter twitch.</summary>
    public const int FrameMilliseconds = 20;

    /// <summary>
    /// 60 ms a bar. Long enough that a full meter is a second and a half of speech rather than half
    /// a second of it, short enough to resolve individual syllables.
    /// </summary>
    public const int FramesPerBar = 3;

    private readonly int _frameLength;
    private double _frameEnergy;
    private int _frameSamples;
    private int _frameRailSamples;

    /// <summary>
    /// Bars peak-hold their frames: a transient that only exists for 20 ms is exactly the thing a
    /// meter must not average away, since it is what clips.
    /// </summary>
    private double _barPeak = double.NegativeInfinity;
    private bool _barClipped;
    private int _barFrames;

    /// <summary>Half a sample left over from the previous call. See <see cref="Append"/>.</summary>
    private int _carry = -1;

    public AudioLevelMeter(int sampleRate = 16_000) =>
        _frameLength = Math.Max(1, sampleRate * FrameMilliseconds / 1_000);

    /// <summary>The 0…1 height for one frame's level. Pure, so the table above can be asserted.</summary>
    public static double LevelFor(double decibels) =>
        Math.Clamp((decibels - FloorDecibels) / (CeilingDecibels - FloorDecibels), 0, 1);

    /// <summary>
    /// Feeds captured audio in and returns whatever bars it completed.
    /// </summary>
    /// <remarks>
    /// Partial frames — and a partial sample, since a driver is free to end a buffer between the
    /// two bytes of one — are carried across calls, because the caller hands over whatever the
    /// capture callback gave it and that is never a whole number of frames.
    /// </remarks>
    /// <param name="pcm">16 kHz mono 16-bit little-endian samples, without a WAV header.</param>
    public List<Bar> Append(ReadOnlySpan<byte> pcm)
    {
        var bars = new List<Bar>();
        var index = 0;

        while (index < pcm.Length)
        {
            short sample;
            if (_carry >= 0)
            {
                sample = (short)(_carry | (pcm[index] << 8));
                _carry = -1;
                index += 1;
            }
            else if (index + 1 < pcm.Length)
            {
                sample = (short)(pcm[index] | (pcm[index + 1] << 8));
                index += 2;
            }
            else
            {
                _carry = pcm[index];
                break;
            }

            var value = sample / 32_768.0;
            _frameEnergy += value * value;
            // Compared as an int: negating short.MinValue overflows.
            if (Math.Abs((int)sample) >= RailAmplitude) _frameRailSamples += 1;
            _frameSamples += 1;
            if (_frameSamples < _frameLength) continue;

            // The epsilon makes digital silence a number rather than negative infinity: −120 dBFS.
            var decibels = 10 * Math.Log10(_frameEnergy / _frameLength + 1e-12);
            var clipped = _frameRailSamples >= RailSamplesPerFrame;
            _frameEnergy = 0;
            _frameSamples = 0;
            _frameRailSamples = 0;

            _barPeak = Math.Max(_barPeak, decibels);
            _barClipped |= clipped;
            _barFrames += 1;
            if (_barFrames < FramesPerBar) continue;

            bars.Add(new Bar(LevelFor(_barPeak), _barClipped));
            _barPeak = double.NegativeInfinity;
            _barClipped = false;
            _barFrames = 0;
        }

        return bars;
    }
}
