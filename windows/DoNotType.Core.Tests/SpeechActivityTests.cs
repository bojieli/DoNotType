using DoNotType.Core;
using Xunit;

namespace DoNotType.Core.Tests;

/// <summary>
/// Silero itself is asserted against the shared recordings. Mocking probabilities would only test
/// our small state machine and miss a wrong tensor shape, sample normalisation or packaged model.
/// </summary>
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

    // ---- Nothing that is not speech gets through --------------------------------------------

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
        Assert.True(reading.MaximumProbability < 0.2, reading.Summary);
    }

    [Theory]
    [InlineData("click")]
    [InlineData("mouse-click-quiet-room")]
    public void KeyboardAndMouseClicksAreNotSentences(string name)
    {
        var reading = SpeechActivity.MeasureWav(Silence(name));
        Assert.False(reading.HasSpeech, $"{name} — {reading.Summary}");
        Assert.True(reading.MaximumProbability < 0.2, reading.Summary);
    }

    // ---- Everything that is speech gets through --------------------------------------------

    [Fact]
    public void AOneWordAnswerIsStillASentence()
    {
        var reading = SpeechActivity.MeasureWav(
            Fixture(Path.Combine("eval", "audio", "short-word.wav")));
        Assert.True(reading.HasSpeech, reading.Summary);
        Assert.True(reading.MaximumProbability > 0.9, reading.Summary);
        Assert.True(
            reading.SpeechMilliseconds >= SpeechActivity.MinimumSpeechMilliseconds,
            reading.Summary);
    }

    [Fact]
    public void RealSpeechIsAlwaysSent()
    {
        var reading = SpeechActivity.Measure(SpeechPcm());
        Assert.True(reading.HasSpeech, reading.Summary);
        Assert.True(reading.MaximumProbability > 0.9, reading.Summary);
    }

    [Theory]
    [InlineData(12)]
    [InlineData(20)]
    [InlineData(32)]
    [InlineData(40)]
    [InlineData(46)]
    [InlineData(52)]
    public void QuietSpeechIsStillSpeech(int attenuation)
    {
        var reading = SpeechActivity.Measure(Attenuated(SpeechPcm(), attenuation));
        Assert.True(reading.HasSpeech, $"speech at -{attenuation} dB — {reading.Summary}");
    }

    /// <summary>
    /// Emulates the narrow dynamic range of the real continuous-speech recordings the old
    /// recording-relative noise floor rejected.
    /// </summary>
    [Fact]
    public void ContinuousGainControlledSpeechNeedsNoQuietFloor()
    {
        var reading = SpeechActivity.Measure(Companded(SpeechPcm()));
        Assert.True(reading.HasSpeech, reading.Summary);
        Assert.True(reading.MaximumProbability > 0.9, reading.Summary);
    }

    // ---- Shape and diagnostics ---------------------------------------------------------------

    [Fact]
    public void EmptyAndInvalidRecordingsAreNotSpeech()
    {
        Assert.False(SpeechActivity.Measure([]).HasSpeech);
        Assert.Throws<ArgumentException>(() => SpeechActivity.MeasureWav([]));
    }

    [Fact]
    public void AFragmentShorterThanTheMinimumIsNotSpeech()
    {
        Assert.False(SpeechActivity.Measure(new byte[16_000 / 100 * 2]).HasSpeech);
    }

    [Fact]
    public void SummaryNamesTheDetectorAndCarriesProbabilities()
    {
        var summary = SpeechActivity.Measure(SpeechPcm()).Summary;
        Assert.Contains("silero", summary);
        Assert.Contains("speech=", summary);
        Assert.Contains("max=", summary);
        Assert.Contains("mean=", summary);
    }

    private static byte[] Attenuated(byte[] pcm, double decibels)
    {
        var factor = Math.Pow(10, -decibels / 20);
        return MapSamples(pcm, sample => sample * factor);
    }

    private static byte[] Companded(byte[] pcm) => MapSamples(pcm, sample =>
    {
        var magnitude = Math.Pow(Math.Abs(sample) / 32_768d, 0.2) * 12_000;
        return sample < 0 ? -magnitude : magnitude;
    });

    private static byte[] MapSamples(byte[] pcm, Func<short, double> transform)
    {
        var output = new byte[pcm.Length];
        for (var index = 0; index < pcm.Length / 2; index++)
        {
            var sample = BitConverter.ToInt16(pcm, index * 2);
            var mapped = (short)Math.Clamp(Math.Round(transform(sample)), short.MinValue, short.MaxValue);
            BitConverter.TryWriteBytes(output.AsSpan(index * 2, 2), mapped);
        }
        return output;
    }
}
