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
    /// <summary>Every fixture with somebody talking in it that this checkout actually has.</summary>
    /// <remarks>
    /// Filtered, because most of these are real recordings of a real person and `.gitignore`
    /// excludes `eval/audio/*.wav` from the repository. They are here on the machine they were
    /// recorded on and nowhere else, so a test that demands them passes locally and fails for
    /// everybody — which is exactly what it did, on every push for five commits.
    ///
    /// <para>`formats/speech.wav` is committed and always survives the filter, so this is never
    /// empty and never becomes a test that checks nothing. The Swift original reaches the same
    /// place by throwing `XCTSkip` per fixture; xUnit 2.9 has no runtime skip, so the list is
    /// narrowed instead of the assertion being waived.</para>
    /// </remarks>
    public static TheoryData<string> SpeechFixtures
    {
        get
        {
            var present = new TheoryData<string>();
            foreach (var name in SpeechRecordings.Where(name => TryFixture(FixturePath(name)) is not null))
            {
                present.Add(name);
            }
            return present;
        }
    }

    private static readonly string[] SpeechRecordings =
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

    private static string FixturePath(string name) => Path.Combine("eval", "audio", name);

    /// <summary>The fixture's bytes, or null when this checkout does not have that recording.</summary>
    private static byte[]? TryFixture(string relative)
    {
        var directory = AppContext.BaseDirectory;
        for (var depth = 0; depth < 8; depth++)
        {
            var candidate = Path.Combine(directory, relative);
            if (File.Exists(candidate)) return File.ReadAllBytes(candidate);
            directory = Path.Combine(directory, "..");
        }
        return null;
    }

    private static byte[] Fixture(string relative) =>
        TryFixture(relative)
        ?? throw new FileNotFoundException($"fixture {relative} not found from {AppContext.BaseDirectory}");

    /// <summary>The bars a whole recording would draw, in order.</summary>
    private static List<AudioLevelMeter.Bar> Bars(string name)
    {
        var wav = Fixture(FixturePath(name));
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
        Assert.Equal(level, AudioLevelMeter.LevelFor(decibels), 2);

    [Fact]
    public void TheScaleIsClampedAtBothEnds()
    {
        Assert.Equal(0, AudioLevelMeter.LevelFor(-120));
        Assert.Equal(0, AudioLevelMeter.LevelFor(AudioLevelMeter.FloorDecibels));
        Assert.Equal(1, AudioLevelMeter.LevelFor(AudioLevelMeter.CeilingDecibels));
        Assert.Equal(1, AudioLevelMeter.LevelFor(0));
    }

    // ---- Clipping --------------------------------------------------------------------------------

    private static byte[] Pcm(IEnumerable<short> samples)
    {
        var list = samples.ToList();
        var bytes = new byte[list.Count * 2];
        for (var index = 0; index < list.Count; index++)
        {
            bytes[index * 2] = (byte)(list[index] & 0xFF);
            bytes[(index * 2) + 1] = (byte)((list[index] >> 8) & 0xFF);
        }
        return bytes;
    }

    /// <summary>Audio clamped at the rail says so.</summary>
    [Fact]
    public void AudioAtTheRailClips()
    {
        var bars = new AudioLevelMeter().Append(Pcm(Enumerable.Repeat((short)32_100, 16_000)));
        Assert.NotEmpty(bars);
        Assert.All(bars, bar =>
        {
            Assert.True(bar.IsClipping);
            Assert.Equal(1, bar.Level);
        });
    }

    /// <summary>A full bar is not a clipped one: this tone uses the whole meter and touches nothing.</summary>
    [Fact]
    public void ALoudCleanToneFillsTheMeterWithoutClipping()
    {
        // −6 dBFS peak: half of full scale, which is loud and entirely undamaged.
        var tone = Enumerable.Range(0, 16_000)
            .Select(index => (short)(16_384 * Math.Sin(index * 2 * Math.PI * 220 / 16_000)));

        var bars = new AudioLevelMeter().Append(Pcm(tone));
        Assert.NotEmpty(bars);
        Assert.DoesNotContain(bars, bar => bar.IsClipping);
    }

    /// <summary>One sample landing on the rail is a peak, not a clipped waveform.</summary>
    [Fact]
    public void ASingleSampleAtTheRailIsNotClipping()
    {
        var frame = Enumerable.Repeat((short)1_000, 960).ToArray();  // one bar
        frame[100] = short.MaxValue;
        frame[400] = short.MinValue;
        Assert.DoesNotContain(new AudioLevelMeter().Append(Pcm(frame)), bar => bar.IsClipping);
    }

    /// <summary>
    /// The measurement the sample-counting rule replaced an energy threshold for. `real-brand` at
    /// twice its recorded gain clamps 1.5% of its samples — audible distortion, and the point at
    /// which somebody can still fix it by turning the gain down. An energy threshold of −3 dBFS
    /// marked 0.3% of frames, which at 60 ms a bar is one amber bar every twenty seconds.
    /// </summary>
    [Fact]
    public void TheOnsetOfClippingIsVisible()
    {
        var pcm = AudioChunker.PcmBody(Fixture(FixturePath(Path.Combine("formats", "speech.wav"))))!;
        var doubled = new short[pcm.Length / 2];
        for (var index = 0; index < doubled.Length; index++)
        {
            var sample = BitConverter.ToInt16(pcm, index * 2) * 2;
            doubled[index] = (short)Math.Clamp(sample, short.MinValue, short.MaxValue);
        }

        var bars = new AudioLevelMeter().Append(Pcm(doubled));
        var clipping = bars.Count(bar => bar.IsClipping) / (double)bars.Count;
        Assert.True(
            clipping > 0.10,
            $"only {clipping:P1} of bars report a recording clamping 1.5% of its samples");
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
    public void SpeechNeitherPinsTheMeterNorReadsAsClipping(string name)
    {
        var bars = Bars(name);
        var pinned = bars.Count(bar => bar.Level >= 0.999) / (double)bars.Count;
        Assert.True(pinned < 0.01, $"{name} spends {pinned:P0} of itself at full scale");

        // Three of these recordings do touch the rail here and there — they are normalised, and
        // `real-brand` marks 0.6% of its bars — but a voice recorded at a sane level must never
        // *read* as clipping, which is a claim about how often.
        var clipping = bars.Count(bar => bar.IsClipping) / (double)bars.Count;
        Assert.True(clipping < 0.01, $"{name} reports clipping on {clipping:P1} of its bars");
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
