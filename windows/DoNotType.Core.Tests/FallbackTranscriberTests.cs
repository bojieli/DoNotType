using System.Diagnostics;
using DoNotType.Core;
using Xunit;

namespace DoNotType.Core.Tests;

/// <summary>
/// The C# port of <c>FallbackTranscriber</c> has to behave like the Swift and Kotlin ones. A hedge
/// that fires at a different moment on one platform means that app has a different latency profile
/// from the one the evaluation describes.
/// </summary>
public class FallbackTranscriberTests : IDisposable
{
    /// <summary>
    /// The two spellings the hedge can log, repeated verbatim in each platform's test suite
    /// rather than shared from one file, per <c>docs/PARITY.md</c>.
    /// </summary>
    private const string StalledMessage = "primary stalled; starting the fallback";

    private const string FailedMessage = "primary failed; starting the fallback";

    private readonly MemoryLogSink _sink = new();

    public FallbackTranscriberTests() => LogRouter.Install([_sink], LogLevel.Trace);

    public void Dispose() => LogRouter.Install([], LogLevel.Off);

    /// <summary>The line that announced the handover, the first thing the category logs.</summary>
    private LogEvent? HandoverLine => _sink.Events.FirstOrDefault(e => e.Category == "fallback");

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

    /// <summary>
    /// A stall and a failure are different problems, so the log has to name which one happened.
    ///
    /// <para>"The primary is slow" and "the primary is broken" want opposite responses from
    /// whoever reads the log. This port logged neither until now — the hedge fired silently on
    /// Windows, so the one platform whose users cannot read a macOS log got no line at all.</para>
    /// </summary>
    [Fact]
    public async Task AStalledPrimaryIsLoggedAsAStall()
    {
        await new FallbackTranscriber(
            Backend(30_000, "primary"), "primary", "p-model",
            Backend(10, "secondary"), "secondary", "s-model",
            TimeSpan.FromMilliseconds(20)).TranscribeAsync();

        Assert.Equal(StalledMessage, HandoverLine?.Message);
        Assert.Equal("primary", HandoverLine?.Fields["primary"]);
        Assert.Equal("secondary", HandoverLine?.Fields["fallback"]);
        Assert.Equal("20", HandoverLine?.Fields["afterMs"]);
    }

    /// <summary>
    /// The delay is deliberately absent: nothing waited it out, so reporting it would describe a
    /// wait that never happened.
    /// </summary>
    [Fact]
    public async Task AFailedPrimaryIsLoggedAsAFailureAndReportsNoDelay()
    {
        await new FallbackTranscriber(
            Backend(5, "", new ProviderException("boom")), "primary", "p-model",
            Backend(10, "secondary"), "secondary", "s-model",
            TimeSpan.FromSeconds(8)).TranscribeAsync();

        Assert.Equal(FailedMessage, HandoverLine?.Message);
        Assert.Equal("primary", HandoverLine?.Fields["primary"]);
        Assert.Equal("secondary", HandoverLine?.Fields["fallback"]);
        Assert.False(HandoverLine?.Fields.ContainsKey("afterMs"));
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
