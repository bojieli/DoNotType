using System.Diagnostics;
using DoNotType.Core;
using Xunit;

namespace DoNotType.Core.Tests;

/// <summary>
/// The C# port of <c>StallHedge</c> has to behave like the Swift and Kotlin ones. A duplicate that
/// fires at a different moment on one platform means that app has a different latency profile — and
/// a different bill — from the one the evaluation describes.
/// </summary>
public class StallHedgeTests
{
    // The floor. Nothing shorter than 32 seconds of audio can produce a deadline below it, which is
    // every ordinary dictation.
    [Theory]
    [InlineData(0)]
    [InlineData(3)]
    [InlineData(20)]
    public void ShortRecordingsGetTheEightSecondFloor(double audioSeconds) =>
        Assert.Equal(8, StallHedge.DeadlineFor(audioSeconds).TotalSeconds, 4);

    /// <summary>
    /// Both conditions have to hold, so at the crossover the floor is still what binds: a quarter of
    /// 32 seconds <em>is</em> eight, and a hair under it is less.
    /// </summary>
    [Fact]
    public void TheFloorBindsUntilAQuarterOfTheAudioOvertakesIt()
    {
        Assert.Equal(8, StallHedge.DeadlineFor(31.9).TotalSeconds, 4);
        Assert.Equal(8, StallHedge.DeadlineFor(32).TotalSeconds, 4);
        Assert.Equal(8.1, StallHedge.DeadlineFor(32.4).TotalSeconds, 4);
    }

    /// <summary>
    /// Past the crossover it is the audio that decides: eight seconds is a stall for a three-second
    /// clip and a perfectly good pace for a four-minute one.
    /// </summary>
    [Fact]
    public void LongRecordingsGetAQuarterOfTheirOwnLength()
    {
        Assert.Equal(15, StallHedge.DeadlineFor(60).TotalSeconds, 4);
        Assert.Equal(60, StallHedge.DeadlineFor(240).TotalSeconds, 4);
    }

    /// <summary>
    /// A compressed file's length is not readable without decoding it, and a missing duration must
    /// not disable the hedge — it falls back to the floor.
    /// </summary>
    [Fact]
    public void AnUnknownDurationGetsTheFloor() =>
        Assert.Equal(8, StallHedge.DeadlineFor(null).TotalSeconds, 4);

    /// <summary>The common case: the request answers normally, so no second one is ever sent.</summary>
    [Fact]
    public async Task AFastRequestIsNeverDuplicated()
    {
        var sent = 0;

        var value = await StallHedge.RaceAsync(TimeSpan.FromSeconds(30), async _ =>
        {
            Interlocked.Increment(ref sent);
            return await Task.FromResult("first");
        });

        Assert.Equal("first", value);
        Assert.Equal(1, sent);
    }

    /// <summary>
    /// The case this exists for: the first request is stuck in the tail and the second one lands.
    /// </summary>
    [Fact]
    public async Task AStalledRequestIsOvertakenByItsDuplicate()
    {
        var sent = 0;
        var hedged = false;

        var value = await StallHedge.RaceAsync(
            TimeSpan.FromMilliseconds(20),
            async token =>
            {
                var attempt = Interlocked.Increment(ref sent);
                // The first request stalls for effectively ever; the second answers straight away.
                if (attempt == 1) await Task.Delay(30_000, token);
                return $"attempt {attempt}";
            },
            () => hedged = true);

        Assert.Equal("attempt 2", value);
        Assert.True(hedged, "the caller has to be able to log that it spent a second request");
    }

    /// <summary>
    /// Not a timeout: the first request is not abandoned at the deadline. If it answers while the
    /// duplicate is still working, it is the one that wins.
    /// </summary>
    [Fact]
    public async Task TheFirstRequestStillWinsIfItAnswersAfterTheDeadline()
    {
        var sent = 0;

        var value = await StallHedge.RaceAsync(TimeSpan.FromMilliseconds(20), async token =>
        {
            var attempt = Interlocked.Increment(ref sent);
            if (attempt == 1) await Task.Delay(100, token);
            if (attempt == 2) await Task.Delay(30_000, token);
            return $"attempt {attempt}";
        });

        Assert.Equal("attempt 1", value);
    }

    /// <summary>
    /// A failure is the retry ladder's problem, not the hedge's, and its backoff will try again
    /// sooner than sitting out the rest of the deadline would.
    /// </summary>
    [Fact]
    public async Task AnEarlyFailureIsNotMadeToWaitOutTheDeadline()
    {
        var clock = Stopwatch.StartNew();

        var error = await Assert.ThrowsAsync<ProviderException>(() =>
            StallHedge.RaceAsync<string>(
                TimeSpan.FromSeconds(30), _ => throw new ProviderException("boom")));

        Assert.Equal("boom", error.Message);
        Assert.True(
            clock.Elapsed < TimeSpan.FromSeconds(5),
            "a failed request must not sit out a deadline meant for a running one");
    }

    /// <summary>
    /// Once the duplicate is in flight, the first one failing costs nothing: the words can still
    /// arrive from the request that is still running.
    /// </summary>
    [Fact]
    public async Task AFailureAfterTheHedgeWaitsForTheDuplicate()
    {
        var sent = 0;

        var value = await StallHedge.RaceAsync(TimeSpan.FromMilliseconds(20), async token =>
        {
            var attempt = Interlocked.Increment(ref sent);
            if (attempt == 1)
            {
                // Long enough that the duplicate has certainly started before this gives up.
                await Task.Delay(100, token);
                throw new ProviderException("unavailable");
            }
            await Task.Delay(200, token);
            return $"attempt {attempt}";
        });

        Assert.Equal("attempt 2", value);
    }

    /// <summary>
    /// When both fail the caller sees the <em>original</em> request's error even though the
    /// duplicate failed sooner: the duplicate was this class's idea, and the request the caller
    /// asked for is the one whose failure explains their configuration.
    /// </summary>
    [Fact]
    public async Task WhenBothFailTheOriginalRequestsErrorSurfaces()
    {
        var sent = 0;

        var error = await Assert.ThrowsAsync<ProviderException>(() =>
            StallHedge.RaceAsync<string>(TimeSpan.FromMilliseconds(20), async token =>
            {
                var attempt = Interlocked.Increment(ref sent);
                if (attempt == 1)
                {
                    await Task.Delay(100, token);
                    throw new ProviderException("no API key");
                }
                throw new ProviderException("boom");
            }));

        Assert.Equal("no API key", error.Message);
    }

    /// <summary>
    /// A deadline of zero or less disables hedging rather than duplicating everything instantly.
    /// </summary>
    [Fact]
    public async Task ANonPositiveDeadlineSendsOneRequest()
    {
        var sent = 0;

        var value = await StallHedge.RaceAsync(TimeSpan.Zero, async token =>
        {
            var attempt = Interlocked.Increment(ref sent);
            await Task.Delay(30, token);
            return $"attempt {attempt}";
        });

        Assert.Equal("attempt 1", value);
        Assert.Equal(1, sent);
    }
}
