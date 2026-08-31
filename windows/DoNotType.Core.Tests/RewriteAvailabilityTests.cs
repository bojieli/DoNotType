using DoNotType.Core;
using Xunit;

namespace DoNotType.Core.Tests;

/// <summary>
/// The one rule four clients used to answer four ways. Mirrors the Swift case for case.
/// </summary>
public class RewriteAvailabilityTests
{
    private static RewriteAvailability Resolve(ProviderKind provider, params ProviderKind[] keyed) =>
        RewriteAvailability.Resolve(provider, keyed.Contains);

    /// <summary>
    /// The regression this rule exists for.
    /// </summary>
    /// <remarks>
    /// A fresh install has no key. Asking whether the backend is a recogniser passes only while the
    /// default is one; the moment the default became a model, the control appeared on an install
    /// that cannot transcribe at all, let alone rewrite. The question was never "what kind of
    /// backend is this", it was "can anything run".
    /// </remarks>
    [Fact]
    public void AFreshInstallWithNoKeyCannotRewriteWhicheverBackendIsSelected()
    {
        foreach (var provider in Enum.GetValues<ProviderKind>())
        {
            Assert.IsType<RewriteAvailability.NoKey>(Resolve(provider));
        }
    }

    [Fact]
    public void AModelBackendWithAKeyCanRewrite()
    {
        foreach (var provider in Enum.GetValues<ProviderKind>().Where(p => !p.IsSpeechRecognition()))
        {
            Assert.True(Resolve(provider, provider).IsAvailable, provider.ToString());
        }
    }

    [Fact]
    public void ARecogniserWithNoTextEndpointNeedsAnotherBackend()
    {
        var recognisers = Enum.GetValues<ProviderKind>()
            .Where(p => p.IsSpeechRecognition() && !p.SupportsTextGeneration())
            .ToList();
        Assert.NotEmpty(recognisers);

        foreach (var provider in recognisers)
        {
            var alone = Assert.IsType<RewriteAvailability.BackendCannotRewrite>(
                Resolve(provider, provider));
            Assert.Equal(provider, alone.Kind);
            Assert.True(Resolve(provider, provider, ProviderKind.Gemini).IsAvailable);
        }
    }

    /// <summary>
    /// A greyed-out control that does not say why is barely better than a missing one, and a
    /// missing one is how this feature came to look absent.
    /// </summary>
    [Fact]
    public void EveryUnavailableCaseExplainsItselfAndSaysWhatToDo()
    {
        RewriteAvailability[] unavailable =
        [
            new RewriteAvailability.NoKey(SecondStageJob.Rewriting),
            new RewriteAvailability.BackendCannotRewrite(
                ProviderKind.Deepgram, SecondStageJob.Rewriting),
            new RewriteAvailability.NoKey(SecondStageJob.Translating),
            new RewriteAvailability.BackendCannotRewrite(
                ProviderKind.Deepgram, SecondStageJob.Translating),
        ];
        foreach (var state in unavailable)
        {
            Assert.NotEmpty(state.Reason);
            Assert.Contains("Add a", state.Reason);
        }
        Assert.Empty(new RewriteAvailability.Available().Reason);
        Assert.Contains("Settings", new RewriteAvailability.NoTargetLanguage().Reason);
    }

    /// <summary>
    /// The sentence is already about what the backend cannot do, so the name must not repeat it.
    /// DisplayName carries "(transcription only)" for the picker and would read as a stutter.
    /// </summary>
    [Fact]
    public void TheReasonNamesTheBackendWithoutRepeatingItself()
    {
        var reason = new RewriteAvailability.BackendCannotRewrite(
            ProviderKind.Deepgram, SecondStageJob.Rewriting).Reason;
        Assert.Contains("Deepgram", reason);
        Assert.DoesNotContain("transcription only", reason);
    }

    /// <summary>
    /// The strings are hand-ported and must stay word-identical across the four clients, so they
    /// are asserted literally rather than by shape -- see docs/PARITY.md.
    /// </summary>
    [Fact]
    public void TheWordingMatchesTheOtherClients()
    {
        Assert.Equal(
            "Add an API key first — without one nothing can run, rewriting included.",
            new RewriteAvailability.NoKey(SecondStageJob.Rewriting).Reason);
        Assert.Equal(
            "Deepgram only transcribes audio and cannot rewrite text. Add a key for a backend "
            + "that can, and rewriting will use it.",
            new RewriteAvailability.BackendCannotRewrite(
                ProviderKind.Deepgram, SecondStageJob.Rewriting).Reason);
    }

    /// <summary>
    /// The phones grew a third mode, and the two backend-shaped sentences have to name the job the
    /// user actually chose: "cannot rewrite text" sends someone who asked for a translation to look
    /// for the wrong setting. Windows has no mode chip -- a desktop chooses by which key it holds --
    /// but it ships the same rule and the same wording.
    /// </summary>
    [Fact]
    public void TheTranslationWordingMatchesTheOtherClients()
    {
        Assert.Equal(
            "Add an API key first — without one nothing can run, translating included.",
            new RewriteAvailability.NoKey(SecondStageJob.Translating).Reason);
        Assert.Equal(
            "Deepgram only transcribes audio and cannot translate text. Add a key for a backend "
            + "that can, and translating will use it.",
            new RewriteAvailability.BackendCannotRewrite(
                ProviderKind.Deepgram, SecondStageJob.Translating).Reason);
        Assert.Equal(
            "Set a target language in Settings first, and Translate will write in it.",
            new RewriteAvailability.NoTargetLanguage().Reason);
    }
}
