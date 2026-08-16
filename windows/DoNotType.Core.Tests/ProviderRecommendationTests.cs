using DoNotType.Core;
using Xunit;

namespace DoNotType.Core.Tests;

/// <summary>
/// What the settings picker advises, and the invariants that keep the advice honest.
/// </summary>
/// <remarks>
/// The same recommendation is hand-written four times — Swift for macOS and iOS, this file's
/// subject for Windows, Kotlin for Android — and the failure mode of that arrangement is one
/// client quietly advising something the others do not. Matching tests exist in the other two
/// languages, for the same reason `FailureAdviceTests` does.
/// </remarks>
public sealed class ProviderRecommendationTests
{
    /// <summary>
    /// Two, and these two. The list is the product decision; everything below is a consequence.
    /// </summary>
    [Fact]
    public void TheRecommendedSetIsTheTwoEndsOfOneAxis()
    {
        Assert.Equal(new[] { ProviderKind.Gemini, ProviderKind.XAI }, ProviderFactory.Recommended);
        // The axis itself: one reads the screen, the other cannot. Two recommendations that
        // differed on nothing would be a coin toss dressed as advice.
        Assert.False(ProviderKind.Gemini.IsSpeechRecognition());
        Assert.True(ProviderKind.XAI.IsSpeechRecognition());
    }

    /// <summary>A picker that recommends everything recommends nothing.</summary>
    [Fact]
    public void OnlyTheRecommendedTwoCarryANote()
    {
        foreach (var kind in Enum.GetValues<ProviderKind>())
        {
            Assert.Equal(kind.IsRecommended(), kind.RecommendationNote().Length > 0);
        }
    }

    /// <summary>
    /// Order is the recommendation that survives a dropdown too short to show every row, and the
    /// form indexes into this list rather than casting, so a gap or a duplicate here would put the
    /// wrong backend in the settings file.
    /// </summary>
    [Fact]
    public void EveryBackendIsOfferedOnceAndTheRecommendedOnesComeFirst()
    {
        Assert.Equal(Enum.GetValues<ProviderKind>().Length, ProviderFactory.PickerOrder.Count);
        Assert.Equal(
            Enum.GetValues<ProviderKind>().OrderBy(k => k),
            ProviderFactory.PickerOrder.OrderBy(k => k));
        Assert.Equal(ProviderFactory.Recommended, ProviderFactory.PickerOrder.Take(2));
    }

    /// <summary>
    /// The default a fresh install gets has to be one we tell people to pick, or the settings
    /// window is arguing with the installer.
    /// </summary>
    [Fact]
    public void TheDefaultForNewInstallsIsRecommended()
    {
        Assert.True(ProviderFactory.DefaultForNewInstalls.IsRecommended());
    }

    /// <summary>
    /// Advice belongs on the row of a picker. Names that reach history rows, log lines and
    /// connection errors say what ran.
    /// </summary>
    [Fact]
    public void AdviceStaysOutOfTheNameUsedForRecords()
    {
        foreach (var kind in Enum.GetValues<ProviderKind>())
        {
            Assert.DoesNotContain("recommended", kind.DisplayName());
            Assert.StartsWith(kind.DisplayName(), kind.PickerLabel());
        }

        Assert.Equal("Gemini — recommended", ProviderKind.Gemini.PickerLabel());
        Assert.Equal("OpenRouter (gateway — prefer Gemini for Gemini models)", ProviderKind.OpenRouter.PickerLabel());
    }

    /// <summary>
    /// The claim each one is recommended for, in the words the other clients use. A number that
    /// moves in docs/EVALUATION.md has to move in four places, and this is the one that says so.
    /// </summary>
    [Fact]
    public void TheNotesMakeTheMeasuredClaimAndNotAVaguerOne()
    {
        Assert.Contains("reads the screen", ProviderKind.Gemini.RecommendationNote());
        Assert.Contains("44 of 48", ProviderKind.Gemini.RecommendationNote());
        Assert.Contains("cannot see the screen", ProviderKind.XAI.RecommendationNote());
        Assert.Contains("15 of 48", ProviderKind.XAI.RecommendationNote());
    }
}
