using DoNotType.Core;
using Xunit;

namespace DoNotType.Core.Tests;

/// <summary>
/// Mirrors Tests/DoNotTypeCoreTests/HallucinationGuardTests.swift. The numbers come from real
/// dictations the macOS app stored, not from invented examples.
/// </summary>
public class HallucinationGuardTests
{
    [Fact]
    public void TheExactMarkerIsRecognised()
    {
        Assert.True(HallucinationGuard.IsNoSpeechMarker("[NO_SPEECH]"));
    }

    [Theory]
    [InlineData("[NO_SPEECH].")]
    [InlineData(" [NO_SPEECH] ")]
    [InlineData("\"[NO_SPEECH]\"")]
    [InlineData("[no_speech]")]
    [InlineData("NO_SPEECH")]
    public void TheMarkerSurvivesTheDecorationModelsAddToIt(string variant)
    {
        Assert.True(HallucinationGuard.IsNoSpeechMarker(variant));
    }

    /// <summary>
    /// The strictness is the point: a loose match on the words would delete a real dictation of
    /// somebody saying them.
    /// </summary>
    [Theory]
    [InlineData("No speech was detected in the recording.")]
    [InlineData("there was no speech")]
    [InlineData("The [NO_SPEECH] token is what the model writes.")]
    public void SpeechAboutNoSpeechIsNotTheMarker(string real)
    {
        Assert.False(HallucinationGuard.IsNoSpeechMarker(real));
    }

    [Fact]
    public void TheMarkerBecomesAnEmptyTranscript()
    {
        var (transcript, verdict) = HallucinationGuard.Inspect(
            new Transcript("[NO_SPEECH]", "en"), 0.7);
        Assert.Equal("", transcript.Text);
        Assert.Equal(HallucinationGuard.Reason.NoSpeechMarker, verdict.Reason);
        Assert.Equal("en", transcript.Language);
    }

    /// <summary>876 characters from 0.68 seconds of room tone: 1288 characters a second.</summary>
    [Fact]
    public void TheMeasuredFabricationIsCaught()
    {
        Assert.True(HallucinationGuard.ExceedsPlausibleRate(new string('a', 876), 0.68));
    }

    /// <summary>Every real dictation measured through the app, at its recorded length.</summary>
    [Theory]
    [InlineData(27, 3.37)]
    [InlineData(72, 8.18)]
    [InlineData(100, 14.58)]
    [InlineData(221, 32.20)]
    [InlineData(244, 32.37)]
    [InlineData(30, 2.03)]
    public void RealDictationsAreKept(int characters, double seconds)
    {
        Assert.False(HallucinationGuard.ExceedsPlausibleRate(new string('a', characters), seconds));
    }

    /// <summary>A fast speaker is roughly 17 characters a second.</summary>
    [Fact]
    public void AFastSpeakerIsNotSuppressed()
    {
        Assert.False(HallucinationGuard.ExceedsPlausibleRate(new string('a', 170), 10));
    }

    /// <summary>
    /// The case that caught the first threshold: an ordinary sentence over two seconds of audio is
    /// 35 characters a second and entirely real.
    /// </summary>
    [Fact]
    public void AnOrdinarySentenceOverShortAudioIsKept()
    {
        const string sentence = "I said the version is three point five, and Kaelith owns the rollout.";
        Assert.True(sentence.Length > HallucinationGuard.MaximumCharactersPerSecond * 2);
        Assert.False(HallucinationGuard.ExceedsPlausibleRate(sentence, 2));
    }

    [Fact]
    public void AShortClipWithOneLongWordIsKept()
    {
        Assert.False(HallucinationGuard.ExceedsPlausibleRate("internationalisation", 1));
    }

    [Fact]
    public void UnknownDurationIsNeverSuspicious()
    {
        Assert.False(HallucinationGuard.ExceedsPlausibleRate(new string('a', 2000), 0));
    }

    [Fact]
    public void TheVerdictCarriesTheMeasurement()
    {
        var (transcript, verdict) = HallucinationGuard.Inspect(
            new Transcript(new string('a', 625), "en"), 0.76);
        Assert.Equal("", transcript.Text);
        Assert.Equal(HallucinationGuard.Reason.ImpossibleRate, verdict.Reason);
        Assert.Equal(625, verdict.Characters);
        Assert.Contains("822", verdict.Summary);
    }

    [Fact]
    public void AnOrdinaryTranscriptPassesThroughUntouched()
    {
        var original = new Transcript("Could you rebuild and reinstall the app?", "en");
        var (transcript, verdict) = HallucinationGuard.Inspect(original, 8.18);
        Assert.Equal(original, transcript);
        Assert.Equal(HallucinationGuard.Reason.Kept, verdict.Reason);
    }
}
