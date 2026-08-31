using DoNotType.Core;
using Xunit;

namespace DoNotType.Core.Tests;

/// <summary>
/// The three modes a dictation can be started in, asserted in the same shape as
/// <c>Tests/DoNotTypeCoreTests/LiveModeTests.swift</c> and
/// <c>android/app/src/test/kotlin/app/donottype/core/LiveModeTest.kt</c>.
/// </summary>
/// <remarks>
/// The table is duplicated rather than shared on purpose: a fixture read from disk would be read
/// by whichever platform remembered to read it, and this is the file that says a phone and a
/// laptop are the same product -- see docs/PARITY.md.
///
/// On this client the picker is three hot keys rather than a chip, which is exactly why the rule
/// had to move here: Windows resolved the stage with a conditional of its own that read the target
/// language on every dictation, so setting one took the main key away from verbatim.
/// </remarks>
public sealed class LiveModeTests
{
    private static readonly Func<ProviderKind, bool> Unkeyed = _ => false;
    private static readonly Func<ProviderKind, bool> Keyed = _ => true;

    /// <summary>The persisted spelling is what a log line and a settings document carry.</summary>
    [Fact]
    public void TheSpellingsAreStableAndUnknownValuesFallBack()
    {
        Assert.Equal(
            new[] { "dictate", "rewrite", "translate" },
            Enum.GetValues<LiveMode>().Select(mode => mode.Id()));
        foreach (var mode in Enum.GetValues<LiveMode>())
        {
            Assert.Equal(mode, LiveModeExtensions.From(mode.Id()));
        }
        Assert.Equal(LiveModeExtensions.Default, LiveModeExtensions.From("nonsense"));
        Assert.Equal(LiveModeExtensions.Default, LiveModeExtensions.From(null));
        Assert.Equal(LiveMode.Dictate, LiveModeExtensions.Default);
    }

    /// <summary>Dictation is the product; a default anywhere else changes a fresh install.</summary>
    [Fact]
    public void TheDefaultIsAPlainDictationWhateverElseIsConfigured()
    {
        Assert.Equal(
            TranscriptMode.Verbatim,
            LiveModeExtensions.Default.Stage(RewriteStyle.Formal, "French"));
    }

    [Fact]
    public void EachModeAsksForItsOwnStage()
    {
        Assert.Equal(
            TranscriptMode.Verbatim, LiveMode.Dictate.Stage(RewriteStyle.Formal, "French"));
        Assert.Equal(
            TranscriptMode.Rewrite(RewriteStyle.Formal),
            LiveMode.Rewrite.Stage(RewriteStyle.Formal, "French"));
        Assert.Equal(
            TranscriptMode.Translate("French"),
            LiveMode.Translate.Stage(RewriteStyle.Formal, "French"));
    }

    /// <summary>
    /// The exclusivity the three keys exist to make visible. A target language used to override
    /// both of the other keys from Settings, so the main key delivered a translation.
    /// </summary>
    [Fact]
    public void TranslateAndRewriteCannotHappenAtOnce()
    {
        foreach (var mode in Enum.GetValues<LiveMode>())
        {
            var stage = mode.Stage(RewriteStyle.Formal, "French");
            Assert.False(
                stage is TranscriptMode.RewriteMode && stage is TranscriptMode.TranslateMode,
                $"{mode} asked for two second stages");
        }
    }

    /// <summary>A mode with nothing configured is a dictation, not an unspecified request.</summary>
    [Fact]
    public void AnUnconfiguredModeFallsBackToTheTranscript()
    {
        Assert.Equal(TranscriptMode.Verbatim, LiveMode.Translate.Stage(RewriteStyle.Formal, ""));
        Assert.Equal(TranscriptMode.Verbatim, LiveMode.Translate.Stage(RewriteStyle.Formal, "   "));
        Assert.Equal(
            TranscriptMode.Verbatim, LiveMode.Rewrite.Stage(RewriteStyle.Verbatim, "French"));
    }

    /// <summary>Dictation has no second stage, so nothing here can be missing.</summary>
    [Fact]
    public void APlainDictationIsAlwaysAvailable()
    {
        var availability = LiveMode.Dictate.Availability(ProviderKind.Gemini, "", Unkeyed);
        Assert.True(availability.IsAvailable);
        Assert.Empty(availability.Reason);
    }

    /// <summary>The two backend-shaped answers are worded for the job that was chosen.</summary>
    [Fact]
    public void TheReasonNamesTheJobTheUserAskedFor()
    {
        Assert.Equal(
            "Add an API key first — without one nothing can run, rewriting included.",
            LiveMode.Rewrite.Availability(ProviderKind.Gemini, "", Unkeyed).Reason);
        Assert.Equal(
            "Add an API key first — without one nothing can run, translating included.",
            LiveMode.Translate.Availability(ProviderKind.Gemini, "French", Unkeyed).Reason);
        Assert.Equal(
            "Deepgram only transcribes audio and cannot rewrite text. Add a key for a backend "
            + "that can, and rewriting will use it.",
            new RewriteAvailability.BackendCannotRewrite(
                ProviderKind.Deepgram, SecondStageJob.Rewriting).Reason);
        Assert.Equal(
            "Deepgram only transcribes audio and cannot translate text. Add a key for a backend "
            + "that can, and translating will use it.",
            new RewriteAvailability.BackendCannotRewrite(
                ProviderKind.Deepgram, SecondStageJob.Translating).Reason);
    }

    /// <summary>
    /// Translate with nothing to translate into: the one state the old arrangement could not
    /// represent, because a target language was the switch rather than the destination.
    /// </summary>
    [Fact]
    public void TranslateWithoutALanguageIsUnavailableForThatReasonAlone()
    {
        Assert.Equal(
            new RewriteAvailability.NoTargetLanguage(),
            LiveMode.Translate.Availability(ProviderKind.Gemini, "  ", Keyed));
        Assert.Equal(
            "Set a target language in Settings first, and Translate will write in it.",
            new RewriteAvailability.NoTargetLanguage().Reason);
        Assert.True(
            LiveMode.Translate.Availability(ProviderKind.Gemini, "French", Keyed).IsAvailable);
    }

    /// <summary>68dp on Android, 86pt on iOS. Both bars are laid out for these three words.</summary>
    [Fact]
    public void TheLabelsAreShortEnoughForTheChip()
    {
        foreach (var mode in Enum.GetValues<LiveMode>())
        {
            Assert.NotEmpty(mode.Label());
            Assert.True(mode.Label().Length <= 9, mode.Label());
        }
    }
}
