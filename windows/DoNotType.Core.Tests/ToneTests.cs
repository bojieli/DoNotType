using DoNotType.Core;
using Xunit;

namespace DoNotType.Core.Tests;

/// <summary>
/// Checks the cues by listening to them rather than by hashing them.
/// </summary>
/// <remarks>
/// The same measurements the Swift suite runs, on this port's own output. That is the point: two
/// suites agreeing on 392 -> 523 and 392 -> 294 is what stops the desktops drifting apart, and a
/// stored copy of the bytes would not do it -- doubles rounded to 16 bits can differ in the last
/// place between platforms without anything being audibly wrong, while a change that made the two
/// cues indistinguishable to a listener could leave the hash intact.
/// </remarks>
public class ToneTests
{
    private const double SampleRate = 48_000.0;

    // The WAV, read back

    private static double[] Samples(byte[] wav)
    {
        var body = DataChunk(wav);
        var samples = new double[body.Length / 2];
        for (var index = 0; index < samples.Length; index++)
        {
            samples[index] = BitConverter.ToInt16(body, index * 2) / 32768.0;
        }
        return samples;
    }

    private static byte[] DataChunk(byte[] wav)
    {
        var cursor = 12;
        while (cursor + 8 <= wav.Length)
        {
            var size = BitConverter.ToInt32(wav, cursor + 4);
            if (wav[cursor] == 'd' && wav[cursor + 1] == 'a'
                && wav[cursor + 2] == 't' && wav[cursor + 3] == 'a')
            {
                var start = cursor + 8;
                return wav[start..Math.Min(start + size, wav.Length)];
            }
            cursor += 8 + size + (size % 2); // chunks are word-aligned
        }
        return [];
    }

    // Measuring a note

    /// <summary>The strongest frequency in a window, to the nearest hertz.</summary>
    /// <remarks>
    /// A Goertzel filter costs one pass per candidate and needs no FFT, which keeps this readable
    /// in all the languages that have to run it. Sweeping whole hertz across the range the cues
    /// occupy is precise enough to tell a fourth from a fifth several times over.
    /// </remarks>
    private static int DominantFrequency(double[] window, int from = 200, int to = 700)
    {
        var best = (Frequency: 0, Power: -1.0);
        for (var candidate = from; candidate <= to; candidate++)
        {
            var power = Goertzel(window, candidate);
            if (power > best.Power)
            {
                best = (candidate, power);
            }
        }
        return best.Frequency;
    }

    private static double Goertzel(double[] window, double frequency)
    {
        var coefficient = 2 * Math.Cos(2 * Math.PI * frequency / SampleRate);
        var previous = 0.0;
        var beforeThat = 0.0;
        foreach (var sample in window)
        {
            var current = sample + (coefficient * previous) - beforeThat;
            beforeThat = previous;
            previous = current;
        }
        return (previous * previous) + (beforeThat * beforeThat)
            - (coefficient * previous * beforeThat);
    }

    /// <summary>The first note alone, then the second once the first has largely decayed.</summary>
    private static (int First, int Second) Notes(byte[] wav)
    {
        var all = Samples(wav);
        var first = all[..(int)(0.12 * SampleRate)];
        var second = all[(int)(0.16 * SampleRate)..(int)(0.30 * SampleRate)];
        return (DominantFrequency(first), DominantFrequency(second));
    }

    // The contract

    /// <summary>G4 up a fourth to C5.</summary>
    [Fact]
    public void StartRisesAFourth()
    {
        var (first, second) = Notes(Tone.Start());
        Assert.InRange(first, 391, 393);
        Assert.InRange(second, 522, 524);
        Assert.True(second > first, "starting rises");
    }

    /// <summary>The same G4 down a fourth to D4.</summary>
    [Fact]
    public void StopFallsAFourth()
    {
        var (first, second) = Notes(Tone.Stop());
        Assert.InRange(first, 391, 393);
        Assert.InRange(second, 293, 295);
        Assert.True(second < first, "stopping falls");
    }

    /// <summary>Both cues open on the same note, which is what makes them a pair.</summary>
    [Fact]
    public void BothCuesShareAnAnchor()
    {
        Assert.Equal(Notes(Tone.Start()).First, Notes(Tone.Stop()).First);
    }

    /// <summary>A cue that outlasts what it reports is still sounding while you talk.</summary>
    [Fact]
    public void EachCueIsUnderHalfASecond()
    {
        foreach (var wav in new[] { Tone.Start(), Tone.Stop() })
        {
            Assert.Equal(0.44, Samples(wav).Length / SampleRate, 2);
        }
    }

    /// <summary>
    /// Quiet on purpose. The floor matters as much as the ceiling: a cue nobody can hear over a
    /// keyboard has failed in the direction that looks like nothing being wrong.
    /// </summary>
    [Fact]
    public void LevelSitsWellBelowFullScale()
    {
        foreach (var wav in new[] { Tone.Start(), Tone.Stop() })
        {
            var loudest = Samples(wav).Max(Math.Abs);
            Assert.InRange(loudest, 0.115, 0.125);
        }
    }

    /// <summary>
    /// <c>SoundPlayer</c> rejects anything it cannot parse, and does it at the point of playback
    /// rather than where the bytes were made.
    /// </summary>
    [Fact]
    public void HeaderIsMono16BitPcmAt48kHz()
    {
        foreach (var wav in new[] { Tone.Start(), Tone.Stop() })
        {
            Assert.Equal("RIFF", System.Text.Encoding.ASCII.GetString(wav, 0, 4));
            Assert.Equal("WAVE", System.Text.Encoding.ASCII.GetString(wav, 8, 4));
            Assert.Equal(1, BitConverter.ToInt16(wav, 20));         // PCM
            Assert.Equal(1, BitConverter.ToInt16(wav, 22));         // mono
            Assert.Equal(48_000, BitConverter.ToInt32(wav, 24));
            Assert.Equal(16, BitConverter.ToInt16(wav, 34));        // bits per sample
            Assert.Equal(wav.Length - 8, BitConverter.ToInt32(wav, 4));
        }
    }

    /// <summary>
    /// The onset is ramped for four milliseconds because a sine wave that starts at full amplitude
    /// is a step change in pressure, and a step is a click.
    /// </summary>
    [Fact]
    public void NoticeableOnsetClickIsRampedAway()
    {
        Assert.InRange(Math.Abs(Samples(Tone.Start())[0]), 0, 0.01);
    }

    /// <summary>
    /// The two desktops play the same cue, so the two ports have to agree sample for sample -- not
    /// merely land on the same notes. Rounding to 16 bits absorbs the last-place differences that
    /// <c>sin</c> and <c>exp</c> are allowed to have between platforms; anything larger is a port
    /// that has drifted. The reference is written by the Swift suite, which owns the original.
    /// </summary>
    [Fact]
    public void MatchesTheSwiftPortSampleForSample()
    {
        var directory = ReferenceDirectory();
        if (directory is null)
        {
            return; // eval/ not reachable from this working directory
        }

        foreach (var (name, wav) in new[] { ("start", Tone.Start()), ("stop", Tone.Stop()) })
        {
            var path = Path.Combine(directory!, $"tone-{name}.wav");
            Assert.True(File.Exists(path), $"missing reference {path}; regenerate with `swift run dnt-eval conformance --write`");

            var reference = Samples(File.ReadAllBytes(path));
            var ours = Samples(wav);
            Assert.Equal(reference.Length, ours.Length);
            for (var index = 0; index < reference.Length; index++)
            {
                // One part in 32768 -- a single step of the 16-bit grid.
                Assert.InRange(Math.Abs(ours[index] - reference[index]), 0, 1.0 / 32768);
            }
        }
    }

    private static string? ReferenceDirectory()
    {
        var directory = new DirectoryInfo(Directory.GetCurrentDirectory());
        for (var depth = 0; depth < 10 && directory is not null; depth++)
        {
            var candidate = Path.Combine(directory.FullName, "eval", "conformance", "tone-start.wav");
            if (File.Exists(candidate))
            {
                return Path.GetDirectoryName(candidate);
            }
            directory = directory.Parent;
        }
        return null;
    }
}
