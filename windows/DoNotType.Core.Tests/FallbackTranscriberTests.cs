using System.Diagnostics;
using DoNotType.Core;
using Xunit;

namespace DoNotType.Core.Tests;

/// <summary>
/// The C# port of <c>FallbackTranscriber</c> has to behave like the Swift and Kotlin ones. A hedge
/// that fires at a different moment on one platform means that app has a different latency profile
/// from the one the evaluation describes.
/// </summary>
public class FallbackTranscriberTests
{
    private static Func<CancellationToken, Task<TranscriptionResult>> Backend(
        int delayMs, string text, Exception? failure = null) =>
        async token =>
        {
            await Task.Delay(delayMs, token);
            if (failure is not null) throw failure;
            return new TranscriptionResult(new Transcript(text, "en"), new TokenUsage(), text);
        };

    /// <summary>The common case: the primary answers normally, so the hedge never fires.</summary>
    [Fact]
    public async Task AFastPrimaryIsNeverSecondGuessed()
    {
        var outcome = await new FallbackTranscriber(
            Backend(10, "primary"), "primary", "p-model",
            Backend(10, "secondary"), "secondary", "s-model",
            TimeSpan.FromSeconds(30)).TranscribeAsync();

        Assert.Equal("primary", outcome.Result.Transcript.Text);
        Assert.False(outcome.Attribution.WasFallback);
        Assert.Equal("primary", outcome.Attribution.Provider);
    }

    /// <summary>The case this exists for: the primary stalls, the hedge fires.</summary>
    [Fact]
    public async Task AStalledPrimaryIsOvertakenByTheHedge()
    {
        var outcome = await new FallbackTranscriber(
            Backend(5000, "primary"), "primary", "p-model",
            Backend(20, "secondary"), "secondary", "s-model",
            TimeSpan.FromMilliseconds(20)).TranscribeAsync();

        Assert.Equal("secondary", outcome.Result.Transcript.Text);
        Assert.True(outcome.Attribution.WasFallback, "the caller has to be able to say so");
        Assert.Equal("secondary", outcome.Attribution.Provider);
    }

    /// <summary>
    /// Nothing left to wait for: a failing primary hands over immediately.
    ///
    /// <para>The elapsed time is the claim here, not which transcript came back — "secondary"
    /// arrives either way, just eight seconds later. This case passed against a Swift port that
    /// always slept the full delay, because only the transcript was ever checked. This port has
    /// always hedged on failure; the assertion is what stops it from quietly regressing to
    /// match.</para>
    /// </summary>
    [Fact]
    public async Task AFailingPrimaryFallsBackWithoutWaitingOutTheDelay()
    {
        var clock = Stopwatch.StartNew();
        var outcome = await new FallbackTranscriber(
            Backend(5, "", new ProviderException("boom")), "primary", "p-model",
            Backend(10, "secondary"), "secondary", "s-model",
            TimeSpan.FromSeconds(8)).TranscribeAsync();
        clock.Stop();

        Assert.Equal("secondary", outcome.Result.Transcript.Text);
        Assert.True(outcome.Attribution.WasFallback);
        Assert.True(
            clock.Elapsed < TimeSpan.FromSeconds(1),
            $"the hedge waited out its delay after the primary had already failed ({clock.Elapsed})");
    }

    /// <summary>The primary's error explains the user's configuration, so it is the one shown.</summary>
    [Fact]
    public async Task WhenBothFailThePrimaryErrorSurfaces()
    {
        var error = await Assert.ThrowsAsync<ProviderException>(() =>
            new FallbackTranscriber(
                Backend(5, "", new ProviderException("primary failed")), "primary", "p-model",
                Backend(5, "", new ProviderException("secondary failed")), "secondary", "s-model",
                TimeSpan.FromMilliseconds(1)).TranscribeAsync());

        Assert.Equal("primary failed", error.Message);
    }

    /// <summary>No secondary is the default, and must behave as before this type existed.</summary>
    [Fact]
    public async Task WithoutASecondaryItIsATransparentPassThrough()
    {
        var outcome = await new FallbackTranscriber(
            Backend(5, "primary"), "primary", "p-model").TranscribeAsync();

        Assert.Equal("primary", outcome.Result.Transcript.Text);
        Assert.False(outcome.Attribution.WasFallback);
    }
}
