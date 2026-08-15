using DoNotType.Core;
using Xunit;

namespace DoNotType.Core.Tests;

/// <summary>
/// What the inspector shows, case for case with
/// `android/app/src/test/kotlin/app/donottype/ContextInspectorTest.kt`.
/// </summary>
/// <remarks>
/// The claim it makes is strong — "this is what was sent" — so the test is that its output contains
/// the encoder's actual output, not that it contains something plausible.
/// </remarks>
public sealed class ContextReportTests
{
    private static ScreenContext Sample() => new()
    {
        AppName = "Mail",
        WindowTitle = "Re: the figure",
        VisibleText = "the quarterly number is 4240",
        TextBeforeCaret = "as discussed, ",
        SelectedText = "4240",
    };

    private static DictationRecord Record(ScreenContext? context) => new()
    {
        Text = "the number is 4240",
        Model = "gemini-3.6-flash",
        AppName = "Mail",
        Context = context,
    };

    /// <summary>
    /// Every part the encoder produced has to appear. Not "some text about the screen" — the exact
    /// strings that went into the request body, because that is what the view claims to be.
    /// </summary>
    [Fact]
    public void ItContainsWhatTheEncoderActuallyProduced()
    {
        var context = Sample();
        var report = ContextReport.Describe(Record(context));

        var parts = new ContextEncoder().Encode(context).OfType<InputPart.Text>().ToList();
        Assert.NotEmpty(parts);
        foreach (var part in parts)
        {
            Assert.Contains(part.Value, report);
        }
    }

    /// <summary>Including the header that tells the model not to transcribe the screen.</summary>
    [Fact]
    public void TheReferenceOnlyHeaderIsVisibleToo() =>
        Assert.Contains(ContextEncoder.Header, ContextReport.Describe(Record(Sample())));

    /// <summary>
    /// "Nothing was sent" and "something was sent and it was blank" are different facts, and the
    /// one on screen has to be the true one.
    /// </summary>
    [Fact]
    public void ADictationWithNoContextSaysSoRatherThanShowingAnEmptySection()
    {
        var report = ContextReport.Describe(Record(null));
        Assert.Contains("No context was sent", report);
        Assert.DoesNotContain("Part 1", report);
    }

    [Fact]
    public void ARewriteShowsBothVersions()
    {
        var record = Record(Sample());
        record.StyledText = "The number is 4,240.";
        record.Mode = "rewrite:formal";

        var report = ContextReport.Describe(record);
        Assert.Contains("What you said", report);
        Assert.Contains("the number is 4240", report);
        Assert.Contains("What was inserted", report);
        Assert.Contains("The number is 4,240.", report);
        Assert.Contains("rewrite:formal", report);
    }

    [Fact]
    public void AVerbatimDictationDoesNotClaimToHaveBeenRewritten() =>
        Assert.DoesNotContain("What was inserted", ContextReport.Describe(Record(Sample())));

    /// <summary>Whether the recording is still on disk is part of "what was sent".</summary>
    [Fact]
    public void ItSaysWhetherTheAudioWasKept()
    {
        Assert.Contains("Not retained", ContextReport.Describe(Record(Sample())));

        var kept = Record(Sample());
        kept.AudioFileName = "abc.wav";
        Assert.Contains("Retained so this dictation can be retried", ContextReport.Describe(kept));
    }

    /// <summary>
    /// The estimate is what the request cost, so it comes from the same encoder rather than from a
    /// character count in the view.
    /// </summary>
    [Fact]
    public void TheTokenEstimateMatchesTheEncoders()
    {
        var context = Sample();
        Assert.Contains(
            $"~{new ContextEncoder().EstimatedTokens(context)} context tokens",
            ContextReport.Describe(Record(context)));
    }
}
