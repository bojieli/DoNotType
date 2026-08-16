using DoNotType.Core;
using Xunit;

namespace DoNotType.Core.Tests;

/// <summary>
/// The bars in the recording pill, against the same fixtures the Swift suite uses — so both
/// clients are held to the same numbers rather than to the same description of them.
/// </summary>
/// <remarks>See `eval/audio/MANIFEST.md` for what each recording is.</remarks>
public sealed class AudioLevelMeterTests
{
    /// <summary>Every fixture with somebody talking in it.</summary>
    public static TheoryData<string> SpeechFixtures =>
        new()
        {
            "gemini-version.wav",
            "git-command.wav",
            "jargon-spelling.wav",
            "novel-codename.wav",
            "novel-name.wav",
            "novel-repo.wav",
            "person-name.wav",
            "port-number.wav",
            "real-acronym-chain.wav",
            "real-acronym.wav",
            "real-brand.wav",
            "real-codeswitch.wav",
            "real-jargon.wav",
            "real-mandarin.wav",
            "real-talk-gemini15.wav",
            Path.Combine("formats", "speech.wav"),
        };

    private static byte[] Fixture(string relative)
    {
        var directory = AppContext.BaseDirectory;
        for (var depth = 0; depth < 8; depth++)
        {
            var candidate = Path.Combine(directory, relative);
            if (File.Exists(candidate)) return File.ReadAllBytes(candidate);
            directory = Path.Combine(directory, "..");
        }
        throw new FileNotFoundException($"fixture {relative} not found from {AppContext.BaseDirectory}");
    }

    /// <summary>The bars a whole recording would draw, in order.</summary>
    private static List<AudioLevelMeter.Bar> Bars(string name)
    {
        var wav = Fixture(Path.Combine("eval", "audio", name));
        var body = AudioChunker.PcmBody(wav)
            ?? throw new InvalidOperationException($"{name} is not a WAV this test can read");
        return new AudioLevelMeter().Append(body);
    }

    private static double Percentile(IEnumerable<double> values, double fraction)
    {
        var sorted = values.Order().ToList();
        return sorted[Math.Min(sorted.Count - 1, (int)(sorted.Count * fraction))];
    }

    // ---- The scale -------------------------------------------------------------------------------

    /// <summary>The table in AudioLevelMeter's documentation, which is where the span came from.</summary>
    [Theory]
    [InlineData(-240, 0.00)]  // digital silence
    [InlineData(-58, 0.04)]  // room tone
    [InlineData(-44, 0.30)]  // quiet speech
    [InlineData(-21, 0.72)]  // conversational speech
    [InlineData(-14, 0.85)]  // loud speech
    [InlineData(-5, 1.00)]  // the loudest frame in any fixture
    public void TheScaleIsTheDocumentedTable(double decibels, double level) =>
        Assert.Equal(level, AudioLevelMeter.BarFor(decibels).Level, 2);

    [Fact]
    public void TheScaleIsClampedAtBothEnds()
    {
        Assert.Equal(0, AudioLevelMeter.BarFor(-120).Level);
        Assert.Equal(0, AudioLevelMeter.BarFor(AudioLevelMeter.FloorDecibels).Level);
        Assert.Equal(1, AudioLevelMeter.BarFor(AudioLevelMeter.CeilingDecibels).Level);
        Assert.Equal(1, AudioLevelMeter.BarFor(0).Level);
    }

    /// <summary>Full scale is where the recording is being damaged, and only there.</summary>
    [Fact]
    public void ClippingIsMarkedOnlyAtTheTop()
    {
        Assert.True(AudioLevelMeter.BarFor(0).IsClipping);
        Assert.True(AudioLevelMeter.BarFor(AudioLevelMeter.ClippingDecibels).IsClipping);
        Assert.False(AudioLevelMeter.BarFor(-4).IsClipping);
        // Loud speech is not clipping, or the warning would mean nothing.
        Assert.False(AudioLevelMeter.BarFor(-14).IsClipping);
    }

    [Fact]
    public void FullScaleAudioClips()
    {
        var loud = new byte[32_000];
        for (var index = 0; index + 1 < loud.Length; index += 2)
        {
            loud[index] = 0x00;
            loud[index + 1] = 0x7D;  // 32000, near full scale
        }

        var bars = new AudioLevelMeter().Append(loud);
        Assert.NotEmpty(bars);
        Assert.All(bars, bar =>
        {
            Assert.True(bar.IsClipping);
            Assert.Equal(1, bar.Level);
        });
    }

    // ---- What a voice looks like -----------------------------------------------------------------

    /// <summary>
    /// The failure the decibel scale exists to fix. The old meter pinned 4–77% of the speaking
    /// frames of these same fixtures flat against the ceiling, so it could say "sound is arriving"
    /// and nothing else. Measured, one bar in 333 in the loudest fixture reaches the top now, and
    /// none at all in the other fifteen.
    /// </summary>
    [Theory]
    [MemberData(nameof(SpeechFixtures))]
    public void SpeechBarelyEverPinsTheMeter(string name)
    {
        var bars = Bars(name);
        var pinned = bars.Count(bar => bar.Level >= 0.999) / (double)bars.Count;
        Assert.True(pinned < 0.01, $"{name} spends {pinned:P0} of itself at full scale");
        Assert.DoesNotContain(bars, bar => bar.IsClipping);
    }

    /// <summary>Speech lives in the top of the meter, so the bars read at a glance.</summary>
    [Theory]
    [MemberData(nameof(SpeechFixtures))]
    public void SpeechUsesTheTopOfTheMeter(string name)
    {
        var loudest = Percentile(Bars(name).Select(bar => bar.Level), 0.90);
        Assert.True(loudest > 0.6, $"{name} draws only {loudest:F2} of a bar when it is loud");
    }

    /// <summary>
    /// And moves inside it: a meter that is tall but static answers "is the mic on", not "how
    /// loud". Measured spread across these fixtures is 0.25–0.77 of the meter's height.
    /// </summary>
    [Theory]
    [MemberData(nameof(SpeechFixtures))]
    public void TheMeterMovesWithTheVoice(string name)
    {
        var levels = Bars(name).Select(bar => bar.Level).ToList();
        var spread = Percentile(levels, 0.90) - Percentile(levels, 0.10);
        Assert.True(spread > 0.20, $"{name} moves through only {spread:F2} of the meter");
    }

    /// <summary>
    /// A quiet room is flat. It is not empty — the meter reports level, and a room has one — but
    /// nothing in it should read as somebody speaking.
    /// </summary>
    [Theory]
    [InlineData("digital-silence")]
    [InlineData("room-tone")]
    [InlineData("too-short")]
    public void AQuietRoomIsFlat(string name)
    {
        var loudest = Bars(Path.Combine("silence", $"{name}.wav")).Max(bar => bar.Level);
        Assert.True(loudest < 0.10, $"{name} draws {loudest:F2} of a bar");
    }

    /// <summary>
    /// Steady noise is not flat, and should not be. `hum` and `steady-noise` sit at −34 dBFS, which
    /// is louder than quiet speech and reads as roughly half a bar. That is the honest answer to
    /// "how loud is the input", and it is why the decision about whether to send a recording is
    /// SpeechActivity's rather than this meter's: one measures volume, the other measures whether
    /// anybody spoke.
    /// </summary>
    [Theory]
    [InlineData("hum")]
    [InlineData("steady-noise")]
    public void SteadyNoiseIsShownAsTheVolumeItIs(string name)
    {
        var bars = Bars(Path.Combine("silence", $"{name}.wav"));
        Assert.True(bars.Max(bar => bar.Level) > 0.3, $"{name} should be visible");
        Assert.DoesNotContain(bars, bar => bar.IsClipping);
    }

    // ---- Framing ---------------------------------------------------------------------------------

    /// <summary>
    /// The capture callback hands over whatever size buffer it has, never a whole number of frames
    /// — and a driver may end one between the two bytes of a sample.
    /// </summary>
    [Fact]
    public void PartialFramesAndSamplesAreCarriedAcrossCalls()
    {
        var pcm = AudioChunker.PcmBody(Fixture(Path.Combine("eval", "audio", "formats", "speech.wav")))!;
        var expected = new AudioLevelMeter().Append(pcm);

        var chunked = new AudioLevelMeter();
        var actual = new List<AudioLevelMeter.Bar>();
        var offset = 0;
        // Odd sizes, so boundaries land mid-frame and mid-sample.
        int[] sizes = [7, 971, 4_099, 63];
        for (var index = 0; offset < pcm.Length; index++)
        {
            var size = Math.Min(sizes[index % sizes.Length], pcm.Length - offset);
            actual.AddRange(chunked.Append(pcm.AsSpan(offset, size)));
            offset += size;
        }

        Assert.NotEmpty(expected);
        Assert.Equal(expected, actual);
    }

    [Fact]
    public void AudioShorterThanOneBarDrawsNothingYet()
    {
        var meter = new AudioLevelMeter();
        // Two frames of a three-frame bar: 640 samples of 16 kHz audio, 1280 bytes.
        Assert.Empty(meter.Append(new byte[1_280]));
        Assert.Single(meter.Append(new byte[640]));
    }
}
