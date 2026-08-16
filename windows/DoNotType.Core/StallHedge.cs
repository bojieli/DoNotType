using System.Diagnostics;

namespace DoNotType.Core;

/// <summary>
/// Sends a second identical request when the first one has stalled, and keeps whichever answers.
/// Port of the macOS <c>StallHedge</c>.
///
/// <para>Transcription latency is <em>bimodal</em> rather than slow. Six sequential requests for
/// one three-second clip took 4.9, 61.6, 50.5, 5.8, 5.9 and 30.2 seconds, with zero thought tokens
/// throughout — that is queueing, not model work. A dictation tool that usually answers in five
/// seconds and sometimes in sixty is worse than one that always takes six, and the fix for a draw
/// that landed in the tail is another draw.</para>
///
/// <para>A request counts as stalled once two conditions both hold: it has been running for at
/// least <see cref="FloorSeconds"/>, <em>and</em> for at least <see cref="AudioFraction"/> of the
/// recording's own length. The floor exists because eight seconds is a normal response for a short
/// clip and re-sending it would double the bill on requests that were never in trouble. The
/// share-of-audio term exists because "slow" is relative to how much speech was sent: eight seconds
/// is a stall for a three-second clip and a good pace for a four-minute one.</para>
///
/// <para>Three things it deliberately is not. <b>Not a timeout</b>: the first request is not
/// abandoned at the deadline — it keeps running, and if it answers first it wins. Cancelling it
/// would throw away a request that has already paid its queueing cost and might be one second from
/// returning, so the same two requests would cost the same money and take longer. <b>Not a race
/// from t=0</b>: a request answering normally is never second-guessed and never pays for a
/// duplicate. <b>Not a retry</b>: <see cref="TranscriptionService.TranscribeWithRetryAsync"/>
/// handles requests that <em>failed</em>, and a failure before the deadline is thrown straight away
/// rather than sitting out the rest of it, because that backoff will try again sooner.</para>
///
/// <para>Nor is it the provider fallback. <see cref="FallbackTranscriber"/> reaches for a
/// <em>different</em> backend on the same symptom and is off unless a second provider is
/// configured; this one re-asks the backend the user chose.</para>
/// </summary>
public static class StallHedge
{
    /// <summary>No request is called stalled before this, however short the recording.</summary>
    public const double FloorSeconds = 8;

    /// <summary>
    /// The share of the recording's own length a request may take before it counts as stalled.
    /// </summary>
    public const double AudioFraction = 0.25;

    /// <summary>
    /// How long a request gets before a second one is sent alongside it. Unknown durations — a
    /// compressed file whose length is not readable without decoding it — get the floor, which is
    /// the same answer as for any recording under 32 seconds.
    /// </summary>
    public static TimeSpan DeadlineFor(double? audioSeconds) =>
        TimeSpan.FromSeconds(Math.Max(FloorSeconds, (audioSeconds ?? 0) * AudioFraction));

    /// <summary>
    /// Runs <paramref name="attempt"/>, starting a second one if the first has not answered within
    /// the deadline.
    /// </summary>
    /// <remarks>
    /// First success wins and the loser is cancelled. If both fail, the <em>original</em> request's
    /// failure is the one thrown — not whichever failed first. The duplicate is this class's idea
    /// rather than the caller's, so its error is a worse explanation of what is wrong: the two can
    /// differ, and it is the request the caller asked for whose failure describes their setup.
    ///
    /// <para><paramref name="attempt"/> is called twice at most, so it must be safe to run
    /// concurrently with itself — which for an HTTP request it is, and for anything that writes to
    /// shared state it is not.</para>
    /// </remarks>
    public static async Task<T> RaceAsync<T>(
        TimeSpan deadline,
        Func<CancellationToken, Task<T>> attempt,
        Action? onHedge = null,
        CancellationToken cancellationToken = default)
    {
        if (deadline <= TimeSpan.Zero)
        {
            return await attempt(cancellationToken).ConfigureAwait(false);
        }

        using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        // Monotonic rather than wall-clock: the elapsed time below decides whether a second request
        // is in flight, and a clock that can step backwards would answer that wrongly.
        var clock = Stopwatch.StartNew();

        var original = RunAsync(attempt, linked.Token);
        var duplicate = RunAfterAsync(deadline, attempt, onHedge, linked.Token);

        var pending = new List<Task<Attempt<T>>> { original, duplicate };
        Exception? originalFailure = null;
        Exception? hedgeFailure = null;

        while (pending.Count > 0)
        {
            var finished = await Task.WhenAny(pending).ConfigureAwait(false);
            pending.Remove(finished);

            var outcome = await finished.ConfigureAwait(false);
            if (outcome.Failure is null)
            {
                await linked.CancelAsync().ConfigureAwait(false);
                return outcome.Value!;
            }

            if (finished != original)
            {
                hedgeFailure = outcome.Failure;
                continue;
            }

            originalFailure = outcome.Failure;
            // Before the deadline nothing else is running — the duplicate is still waiting out its
            // delay — so there is nothing to wait for and the caller gets its error now.
            if (clock.Elapsed < deadline)
            {
                await linked.CancelAsync().ConfigureAwait(false);
                throw originalFailure;
            }
        }

        await linked.CancelAsync().ConfigureAwait(false);
        throw originalFailure ?? hedgeFailure ?? new ProviderException("Model returned no output.");
    }

    /// <summary>One of the two requests, having either answered or failed.</summary>
    private readonly record struct Attempt<T>(T? Value, Exception? Failure);

    private static async Task<Attempt<T>> RunAsync<T>(
        Func<CancellationToken, Task<T>> attempt, CancellationToken cancellationToken)
    {
        try
        {
            return new Attempt<T>(await attempt(cancellationToken).ConfigureAwait(false), null);
        }
        catch (Exception error)
        {
            // Returned rather than thrown: the loser of this race is routinely cancelled, and a
            // task nobody awaits must not be left holding an exception.
            return new Attempt<T>(default, error);
        }
    }

    private static async Task<Attempt<T>> RunAfterAsync<T>(
        TimeSpan deadline,
        Func<CancellationToken, Task<T>> attempt,
        Action? onHedge,
        CancellationToken cancellationToken)
    {
        try
        {
            await Task.Delay(deadline, cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException error)
        {
            // Cancelled before it ever fired, which is what a request answering in time looks like:
            // no second request, and not even a pending timer left behind.
            return new Attempt<T>(default, error);
        }

        onHedge?.Invoke();
        return await RunAsync(attempt, cancellationToken).ConfigureAwait(false);
    }
}
