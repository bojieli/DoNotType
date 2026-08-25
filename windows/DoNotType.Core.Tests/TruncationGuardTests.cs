using DoNotType.Core;
using Xunit;

namespace DoNotType.Core.Tests;

/// <summary>
/// The thresholds, pinned against the measurements that chose them.
/// </summary>
/// <remarks>
/// Every number is from 2026-08-25: 350 real dictations for the legitimate floor, and one
/// 90-second Mandarin recording that <c>gemini-3.5-flash</c> truncated on 6 runs in 10 for the
/// failure. Mirrors <c>TruncationGuardTests</c> in Swift and Kotlin — if a constant moves, all
/// three say what it was traded against.
/// </remarks>
public class TruncationGuardTests
{
    private static string Chars(int count) => new('字', count);

    /// <summary>The observed failure: ~100 characters where ~310 belonged, 49 s of speech.</summary>
    [Fact]
    public void TheMeasuredTruncationIsCaught()
    {
        var verdict = TruncationGuard.Inspect(Chars(98), 49);
        Assert.True(verdict.IsSuspect);
        Assert.Equal(98, verdict.Characters);
    }

    [Theory]
    [InlineData(309)]
    [InlineData(381)]
    public void ACompleteTranscriptOfTheSameRecordingIsKept(int characters)
    {
        Assert.False(TruncationGuard.Inspect(Chars(characters), 49).IsSuspect);
    }

    /// <summary>
    /// The lowest rate any of 350 real dictations reached was 4.92 characters a second of speech.
    /// The floor has to sit below that with room, or the guard fires on ordinary dictation.
    /// </summary>
    [Fact]
    public void TheSlowestRealDictationMeasuredIsNotFlagged()
    {
        Assert.False(TruncationGuard.Inspect(Chars(109), 22.2).IsSuspect);
        Assert.True(TruncationGuard.MinimumCharactersPerSecond < 4.92);
    }

    [Theory]
    [InlineData(3)]
    [InlineData(19.9)]
    public void AShortClipIsNeverJudged(double speechSeconds)
    {
        Assert.False(TruncationGuard.Inspect("hi", speechSeconds).IsSuspect);
    }

    [Fact]
    public void UnknownSpeechLengthIsNotSuspicious()
    {
        Assert.False(TruncationGuard.Inspect("short", null).IsSuspect);
    }

    /// <summary>An empty transcript is the [NO_SPEECH] path's business, not this one.</summary>
    [Fact]
    public void AnEmptyTranscriptIsLeftToTheOtherGuard()
    {
        Assert.False(TruncationGuard.Inspect("", 60).IsSuspect);
        Assert.False(TruncationGuard.Inspect("   ", 60).IsSuspect);
    }

    [Fact]
    public void TheCheapScreenAdmitsTheFailureAndSkipsOrdinaryTranscripts()
    {
        Assert.True(TruncationGuard.WarrantsInspection(Chars(98), 90));
        Assert.False(TruncationGuard.WarrantsInspection(new string('x', 681), 90));
        Assert.False(TruncationGuard.WarrantsInspection("anything", null));
    }

    [Fact]
    public void TheSummaryShowsItsArithmetic()
    {
        var summary = TruncationGuard.Inspect(Chars(98), 49).Summary;
        Assert.Contains("98", summary);
        Assert.Contains("2.00", summary);
        Assert.Contains("3.50", summary);
    }
}
