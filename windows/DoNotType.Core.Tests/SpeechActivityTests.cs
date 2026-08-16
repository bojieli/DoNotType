using DoNotType.Core;
using Xunit;

namespace DoNotType.Core.Tests;

/// <summary>
/// The gate that stops silence reaching a model, against the same fixtures the Swift and Kotlin
/// suites use — so all four clients are held to the same numbers.
/// </summary>
/// <remarks>See `eval/audio/silence/README.md` for what each recording is and why.</remarks>
public sealed class SpeechActivityTests
{
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

    private static byte[] Silence(string name) =>
        Fixture(Path.Combine("eval", "audio", "silence", $"{name}.wav"));

    private static byte[] SpeechPcm() =>
        AudioChunker.PcmBody(Fixture(Path.Combine("eval", "audio", "formats", "speech.wav")))!;

    // ---- Nothing that is not speech gets through -------------------------------------------------

    /// <summary>
    /// The whole point. Each of these, handed to a model, is an invitation to invent a sentence.
    /// </summary>
    [Theory]
    [InlineData("digital-silence")]
    [InlineData("room-tone")]
    [InlineData("steady-noise")]
    [InlineData("hum")]
    [InlineData("too-short")]
    public void NothingWithoutSpeechIsEverSent(string name)
    {
        var reading = SpeechActivity.MeasureWav(Silence(name));
        Assert.False(reading.HasSpeech, $"{name} would have been sent — {reading.Summary}");
        Assert.Equal(0, reading.SpeechMilliseconds);
    }

    /// <summary>
    /// A hum is loud — louder than quiet speech — and still not speech. Gating on volume would
    /// send this and drop somebody talking softly, which is the wrong way round.
    /// </summary>
    [Fact]
    public void ALoudHumIsStillNotSpeech()
    {
        var hum = SpeechActivity.MeasureWav(Silence("hum"));
        var quiet = SpeechActivity.Measure(Attenuated(SpeechPcm(), 30));

        Assert.False(hum.HasSpeech, hum.Summary);
        Assert.True(quiet.HasSpeech, quiet.Summary);
        Assert.True(
            hum.PeakDecibels > quiet.NoiseFloorDecibels,
            "the hum really is the louder recording, which is what makes this test worth having");
    }

    /// <summary>
    /// One keyboard click has enormous dynamic range and lasts 20 ms. Duration is what separates it
    /// from speech, not level.
    /// </summary>
    [Fact]
    public void AKeyboardClickIsNotASentence()
    {
        var reading = SpeechActivity.MeasureWav(Silence("click"));
        Assert.False(reading.HasSpeech, reading.Summary);
        Assert.True(reading.SpeechMilliseconds < 100, reading.Summary);
    }

    /// <summary>
    /// The recording this gate was rebuilt around: one mouse click in a very quiet room. 380 ms
    /// above the floor is past the 200 ms threshold, and a −37 dB transient over a −63 dB floor is
    /// 26 dB of range — in a silent room any sound clears a relative margin. What it does not have
    /// is a voice's spectrum.
    /// </summary>
    [Fact]
    public void AMouseClickInAQuietRoomIsNotASentence()
    {
        var reading = SpeechActivity.MeasureWav(Silence("mouse-click-quiet-room"));
        Assert.True(
            reading.SpeechMilliseconds > SpeechActivity.MinimumSpeechMilliseconds,
            $"the premise is that duration alone lets it through — {reading.Summary}");
        Assert.False(reading.HasSpeech, reading.Summary);
    }

    // ---- Everything that is speech gets through --------------------------------------------------

    /// <summary>
    /// The constraint on the spectral test. "Yes." is a single 320 ms burst — the same duration and
    /// shape as the mouse click above, so any rule separating them by length or burst count would
    /// drop this.
    /// </summary>
    [Fact]
    public void AOneWordAnswerIsStillASentence()
    {
        var reading = SpeechActivity.MeasureWav(
            Fixture(Path.Combine("eval", "audio", "short-word.wav")));
        Assert.True(
            reading.SpeechMilliseconds < SpeechActivity.StrongSpeechMilliseconds,
            $"this must be short enough that the spectral test is what admits it — {reading.Summary}");
        Assert.True(reading.HasSpeech, reading.Summary);
    }

    /// <summary>
    /// Stated as a number so narrowing it has to be an argument rather than an edit.
    /// </summary>
    [Fact]
    public void TheVoiceBandSeparatesAClickFromAVoice()
    {
        var click = SpeechActivity.MeasureWav(Silence("mouse-click-quiet-room"));
        var word = SpeechActivity.MeasureWav(
            Fixture(Path.Combine("eval", "audio", "short-word.wav")));

        Assert.True(click.VoiceBandRatio < SpeechActivity.MinimumVoiceBandRatio, click.Summary);
        Assert.True(word.VoiceBandRatio > SpeechActivity.MinimumVoiceBandRatio, word.Summary);
        Assert.True(
            word.VoiceBandRatio - click.VoiceBandRatio > 0.08,
            "the threshold is only defensible while these are far apart");
    }

    /// <summary>
    /// The failure that would matter more than the one this prevents. A stray "Thank you." is
    /// annoying; dropping a sentence somebody said is unforgivable.
    /// </summary>
    [Fact]
    public void RealSpeechIsAlwaysSent()
    {
        var reading = SpeechActivity.Measure(SpeechPcm());
        Assert.True(reading.HasSpeech, reading.Summary);
        Assert.True(reading.SpeechMilliseconds > 800, reading.Summary);
    }

    /// <summary>Somebody dictating quietly, or a microphone with its gain low.</summary>
    [Theory]
    [InlineData(12)]
    [InlineData(20)]
    [InlineData(32)]
    [InlineData(40)]
    [InlineData(46)]
    public void QuietSpeechIsStillSpeech(int attenuation)
    {
        var reading = SpeechActivity.Measure(Attenuated(SpeechPcm(), attenuation));
        Assert.True(
            reading.HasSpeech,
            $"speech at −{attenuation} dB would have been dropped — {reading.Summary}");
    }

    /// <summary>
    /// The margin between the two, as a number, so a change to the threshold has to argue with it
    /// rather than quietly narrow it.
    /// </summary>
    [Fact]
    public void TheMarginBetweenSpeechAndNoiseIsWide()
    {
        var loudestNoise = new[] { "digital-silence", "room-tone", "steady-noise", "hum", "click" }
            .Max(name => SpeechActivity.MeasureWav(Silence(name)).SpeechMilliseconds);
        var quietestSpeech = SpeechActivity.Measure(Attenuated(SpeechPcm(), 46)).SpeechMilliseconds;

        Assert.True(loudestNoise <= 100, $"noise reached {loudestNoise} ms");
        Assert.True(quietestSpeech >= 400, $"quiet speech only reached {quietestSpeech} ms");
        Assert.True(
            quietestSpeech > loudestNoise * 4,
            "the threshold is only defensible while these are far apart");
    }

    // ---- Shape ------------------------------------------------------------------------------------

    [Fact]
    public void AnEmptyRecordingIsNotSpeech()
    {
        Assert.False(SpeechActivity.Measure([]).HasSpeech);
        Assert.False(SpeechActivity.MeasureWav([]).HasSpeech);
    }

    /// <summary>
    /// A recording shorter than one frame cannot be measured, and must not be assumed to be speech.
    /// </summary>
    [Fact]
    public void AFragmentShorterThanAFrameIsNotSpeech() =>
        Assert.False(SpeechActivity.Measure(new byte[16_000 / 100 * 2]).HasSpeech);

    private static byte[] Attenuated(byte[] pcm, double decibels)
    {
        var factor = Math.Pow(10, -decibels / 20);
        var output = new byte[pcm.Length];
        for (var index = 0; index < pcm.Length / 2; index++)
        {
            var sample = (short)Math.Clamp(
                Math.Round(BitConverter.ToInt16(pcm, index * 2) * factor), short.MinValue, short.MaxValue);
            BitConverter.GetBytes(sample).CopyTo(output, index * 2);
        }
        return output;
    }
}
