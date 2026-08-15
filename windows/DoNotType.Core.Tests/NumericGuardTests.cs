using DoNotType.Core;
using Xunit;

namespace DoNotType.Core.Tests;

/// <summary>
/// The numeric guard, case for case with `Tests/DoNotTypeCoreTests/NumericGuardTests.swift`.
/// </summary>
/// <remarks>
/// Duplicated rather than shared on purpose, like the mode grammar: these are the cases the
/// evaluation suite actually produced, and the same utterance dictated on a laptop and a desktop
/// has to come out with the same numbers in it. A shared fixture would be read by whichever
/// platform remembered to read it.
/// </remarks>
public sealed class NumericGuardTests
{
    /// <summary>
    /// The exact failure the suite keeps producing: the screen's version number wins over the
    /// speaker's.
    /// </summary>
    [Fact]
    public void TheGroundedVersionNumberIsReplacedByTheSpokenOne()
    {
        var result = NumericGuard.Reconcile(
            "We should use Gemini 2.5 Flash for this.",
            "We should use Gemini 1.5 Flash for this.");

        Assert.Equal("We should use Gemini 1.5 Flash for this.", result.Text);
        Assert.Equal(["2.5"], result.Corrections.Select(c => c.Was));
        Assert.Equal(["1.5"], result.Corrections.Select(c => c.Became));
    }

    /// <summary>The measured code-switch regression, verbatim from the suite output.</summary>
    [Fact]
    public void TheCodeSwitchRegressionIsRepaired()
    {
        var result = NumericGuard.Reconcile("比如說這個是1024吧我印象里", "比如說這個是4240我印象裡");
        Assert.Equal("比如說這個是4240吧我印象里", result.Text);
    }

    /// <summary>
    /// Everything that is not a number must survive untouched — the grounded run is kept precisely
    /// because it spells names and jargon better.
    /// </summary>
    [Fact]
    public void WordsAreNeverTakenFromTheAudioOnlyRun()
    {
        var result = NumericGuard.Reconcile(
            "Deploy SwiftUI to Kubernetes on port 8080.",
            "Deploy swift UI to kubernetes on port 8080.");

        Assert.Equal("Deploy SwiftUI to Kubernetes on port 8080.", result.Text);
        Assert.Empty(result.Corrections);
    }

    [Fact]
    public void TranscriptsWithoutNumbersAreReturnedUnchanged()
    {
        var result = NumericGuard.Reconcile("Ship the pricing page", "ship the pricing page");
        Assert.Equal("Ship the pricing page", result.Text);
        Assert.False(result.SkippedForMismatch);
    }

    /// <summary>
    /// The safety rule. If the two runs disagree about how many numbers there are, one of them
    /// dropped or invented a figure, and aligning by index would move a value somewhere it was
    /// never spoken — a worse failure than the one being fixed.
    /// </summary>
    [Fact]
    public void MismatchedCountsLeaveTheTranscriptAlone()
    {
        var result = NumericGuard.Reconcile("Ports 80 and 443 are open.", "Port 443 is open.");

        Assert.Equal("Ports 80 and 443 are open.", result.Text);
        Assert.True(result.SkippedForMismatch);
        Assert.Empty(result.Corrections);
    }

    [Fact]
    public void MultipleNumbersAreReplacedPositionally()
    {
        var result = NumericGuard.Reconcile(
            "Scale from 2 to 16 replicas by 5 p.m.",
            "Scale from 2 to 12 replicas by 4 p.m.");

        Assert.Equal("Scale from 2 to 12 replicas by 4 p.m.", result.Text);
        Assert.Equal(2, result.Corrections.Count);
    }

    /// <summary>
    /// A trailing full stop is punctuation, not part of the number, or the sentence would lose it.
    /// </summary>
    [Fact]
    public void SentencePunctuationIsNotSwallowedIntoTheNumber()
    {
        Assert.Equal(["42"], NumericGuard.Numbers("It costs 42."));
        Assert.Equal(["3.5", "3"], NumericGuard.Numbers("Use 3.5, not 3."));
    }

    [Fact]
    public void SeparatorsInsideNumbersSurvive() =>
        Assert.Equal(
            ["1,024", "16:9", "2024-01"], NumericGuard.Numbers("1,024 at 16:9 over 2024-01"));

    [Fact]
    public void NumbersAttachedToWordsAreStillFound() =>
        Assert.Equal(["4", "2", "8080"], NumericGuard.Numbers("gpt-4o and v2 on port8080"));

    /// <summary>
    /// The guard must be a no-op when both runs agree, or it would be adding risk for nothing.
    /// </summary>
    [Fact]
    public void IdenticalTranscriptsAreUnchanged()
    {
        const string text = "Deploy 3 replicas on port 8080 at 9:30.";
        var result = NumericGuard.Reconcile(text, text);

        Assert.Equal(text, result.Text);
        Assert.Empty(result.Corrections);
        Assert.False(result.SkippedForMismatch);
    }

    /// <summary>
    /// An audio-only run that failed entirely must not be allowed to strip numbers from a good
    /// grounded transcript.
    /// </summary>
    [Fact]
    public void AnEmptyAudioOnlyRunCannotDamageTheTranscript()
    {
        var result = NumericGuard.Reconcile("Use port 8080.", "");
        Assert.Equal("Use port 8080.", result.Text);
        Assert.True(result.SkippedForMismatch);
    }

    // ---- When it fires --------------------------------------------------------------------------

    /// <summary>
    /// The trigger is digits near the caret, not digits anywhere on screen: measured substitution
    /// is 75% from the caret window against 30% from the visible text, and the visible text is ten
    /// times the budget and full of numbers that have nothing to do with the utterance.
    /// </summary>
    [Fact]
    public void OnlyTheCaretWindowCountsAsHighRisk()
    {
        Assert.True(NumericGuard.IsHighRisk(new ScreenContext { TextBeforeCaret = "version 2.5" }));
        Assert.True(NumericGuard.IsHighRisk(new ScreenContext { TextAfterCaret = "port 8080" }));
        Assert.True(NumericGuard.IsHighRisk(new ScreenContext { SelectedText = "1024" }));

        Assert.False(
            NumericGuard.IsHighRisk(new ScreenContext { VisibleText = "a sidebar showing 4240" }),
            "the visible text is not the trigger — see the measurements");
        Assert.False(NumericGuard.IsHighRisk(new ScreenContext { TextBeforeCaret = "no digits" }));
        Assert.False(NumericGuard.IsHighRisk(null));
    }

    [Theory]
    [InlineData(NumberCheckPolicy.Never, false)]
    [InlineData(NumberCheckPolicy.Always, true)]
    public void TheOuterPoliciesIgnoreTheContext(NumberCheckPolicy policy, bool expected)
    {
        Assert.Equal(expected, policy.Applies(new ScreenContext { TextBeforeCaret = "2.5" }));
        Assert.Equal(expected, policy.Applies(null));
    }

    [Fact]
    public void TheDefaultPolicyFiresOnlyWhereItWasMeasuredToHelp()
    {
        var policy = NumberCheckPolicy.WhenCaretHasNumbers;
        Assert.True(policy.Applies(new ScreenContext { TextBeforeCaret = "version 2.5" }));
        Assert.False(policy.Applies(new ScreenContext { VisibleText = "4240" }));
    }

    /// <summary>The stored spelling has to round-trip, or a saved setting silently resets.</summary>
    [Theory]
    [InlineData(NumberCheckPolicy.Never)]
    [InlineData(NumberCheckPolicy.WhenCaretHasNumbers)]
    [InlineData(NumberCheckPolicy.Always)]
    public void EveryPolicyRoundTripsThroughItsStoredSpelling(NumberCheckPolicy policy) =>
        Assert.Equal(policy, NumberCheckPolicyExtensions.Parse(policy.Id()));
}
