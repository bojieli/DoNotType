namespace DoNotType.Core;

/// <summary>
/// Runs a second backend when the first one is taking too long, and returns whichever answers.
/// Port of the macOS <c>FallbackTranscriber</c>.
///
/// <para>The first-party Gemini API is the most accurate backend measured and its latency is
/// <em>bimodal</em> rather than slow: six sequential requests for one three-second clip took 4.9,
/// 61.6, 50.5, 5.8, 5.9 and 30.2 seconds, with zero thought tokens throughout. A dictation tool
/// that usually answers in five seconds and sometimes in sixty is worse than one that always takes
/// six — the unpredictability is the problem, not the mean.</para>
///
/// <para>Three deliberate choices, the same on every platform. It <b>hedges rather than races</b>:
/// racing from the start would mean the fast backend nearly always wins, which is "use the fast
/// backend" at double the cost. It is <b>attributed, not silent</b>: the result names the backend
/// that answered and history records that rather than the one that was asked. It is <b>off by
/// default</b>, with the delay configurable, because that delay is the accuracy-against-latency
/// dial and the right value depends on which two backends are paired.</para>
/// </summary>
public sealed class FallbackTranscriber(
    Func<CancellationToken, Task<TranscriptionResult>> primary,
    string primaryName,
    string primaryModel,
    Func<CancellationToken, Task<TranscriptionResult>>? secondary = null,
    string secondaryName = "",
    string secondaryModel = "",
    TimeSpan? hedgeAfter = null)
{
    private readonly TimeSpan _hedgeAfter = hedgeAfter ?? TimeSpan.FromSeconds(8);

    private static readonly Log Log = new("fallback");

    /// <param name="WasFallback">True when the primary stalled or failed and the secondary answered first.</param>
    public readonly record struct Attribution(string Provider, string Model, bool WasFallback);

    public readonly record struct Outcome(TranscriptionResult Result, Attribution Attribution);

    /// <summary>
    /// First success wins. A primary that <em>fails</em> hands over immediately rather than burning
    /// the hedge delay — there is nothing left to wait for. If both fail the primary's error is
    /// thrown, because that is the backend the user chose and its error explains their setup.
    /// </summary>
    public async Task<Outcome> TranscribeAsync(CancellationToken cancellationToken = default)
    {
        if (secondary is null)
        {
            return new Outcome(
                await primary(cancellationToken).ConfigureAwait(false),
                new Attribution(primaryName, primaryModel, false));
        }

        using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        var primaryFailed = new TaskCompletionSource<Exception>(
            TaskCreationOptions.RunContinuationsAsynchronously);

        var primaryTask = RunAsync(
            primary, new Attribution(primaryName, primaryModel, false), primaryFailed, linked.Token);
        var secondaryTask = RunHedgeAsync(
            new Attribution(secondaryName, secondaryModel, true), primaryFailed, linked.Token);

        var pending = new List<Task<Outcome?>> { primaryTask, secondaryTask };
        while (pending.Count > 0)
        {
            var finished = await Task.WhenAny(pending).ConfigureAwait(false);
            pending.Remove(finished);

            var outcome = await finished.ConfigureAwait(false);
            if (outcome is not null)
            {
                await linked.CancelAsync().ConfigureAwait(false);
                return outcome.Value;
            }
        }

        await linked.CancelAsync().ConfigureAwait(false);
        throw primaryFailed.Task.IsCompletedSuccessfully
            ? primaryFailed.Task.Result
            : new ProviderException("Model returned no output.");
    }

    private static async Task<Outcome?> RunAsync(
        Func<CancellationToken, Task<TranscriptionResult>> backend,
        Attribution attribution,
        TaskCompletionSource<Exception> failed,
        CancellationToken cancellationToken)
    {
        try
        {
            return new Outcome(await backend(cancellationToken).ConfigureAwait(false), attribution);
        }
        catch (OperationCanceledException)
        {
            return null;
        }
        catch (Exception error)
        {
            failed.TrySetResult(error);
            return null;
        }
    }

    private async Task<Outcome?> RunHedgeAsync(
        Attribution attribution,
        TaskCompletionSource<Exception> primaryFailed,
        CancellationToken cancellationToken)
    {
        bool primaryHadFailed;
        try
        {
            // Wait out the hedge delay, but cut it short if the primary has already failed —
            // there is then nothing left to wait for.
            var delay = Task.Delay(_hedgeAfter, cancellationToken);
            var first = await Task.WhenAny(delay, primaryFailed.Task).ConfigureAwait(false);
            cancellationToken.ThrowIfCancellationRequested();
            primaryHadFailed = first == primaryFailed.Task;
        }
        catch (OperationCanceledException)
        {
            return null;
        }

        // Logged at info: this is the app spending a second request on the user's behalf, and a
        // fallback that fires on every dictation is a misconfigured delay rather than a working
        // feature. It should be visible without turning anything on.
        //
        // Which of the two started it is the difference between "the primary is slow" and "the
        // primary is broken", and those want opposite responses from whoever reads the log. Only
        // the stall waited, so only the stall reports a delay.
        if (primaryHadFailed)
        {
            Log.Info(() => "primary failed; starting the fallback", new Dictionary<string, string>
            {
                ["primary"] = primaryName,
                ["fallback"] = secondaryName,
            });
        }
        else
        {
            Log.Info(() => "primary stalled; starting the fallback", new Dictionary<string, string>
            {
                ["primary"] = primaryName,
                ["fallback"] = secondaryName,
                ["afterMs"] = ((long)_hedgeAfter.TotalMilliseconds).ToString(
                    System.Globalization.CultureInfo.InvariantCulture),
            });
        }

        return await RunAsync(secondary!, attribution, new TaskCompletionSource<Exception>(),
            cancellationToken).ConfigureAwait(false);
    }
}
