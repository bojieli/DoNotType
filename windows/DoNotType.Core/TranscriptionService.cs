using System.Net.Http.Headers;
using System.Text;
using System.Text.Json.Nodes;

namespace DoNotType.Core;

/// <summary>
/// One place where a recording becomes a transcript, whether it is the first attempt or the fourth.
///
/// Routing retries through the same function as first attempts means a retried dictation is not a
/// lesser one: same prompt, same model, same stored audio and context, so it produces what the
/// original request would have produced had the network held.
/// </summary>
public sealed class TranscriptionService(
    ITranscriptionProvider provider,
    string systemInstruction,
    ContextEncoder? encoder = null)
{
    private readonly ContextEncoder _encoder = encoder ?? new ContextEncoder();
    private static readonly Log Log = new("transcribe");

    public ITranscriptionProvider Provider { get; } = provider;

    /// <summary>
    /// Rewrites or summarises a finished transcript. Text in, text out -- no audio, no screen.
    /// </summary>
    /// <remarks>
    /// Deliberately a separate call rather than an instruction folded into transcription. The two
    /// are different jobs with different failure modes, and keeping them apart is what makes the
    /// verbatim transcript exist before anything is done to it.
    /// </remarks>
    public async Task<string> RewriteAsync(
        string transcript, string instruction, CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(transcript)) return transcript;

        var started = DateTimeOffset.Now;
        var result = await Provider.TranscribeAsync(
                instruction, [new InputPart.Text(transcript)], cancellationToken: cancellationToken)
            .ConfigureAwait(false);

        var rewritten = result.Transcript.Text.Trim();
        Log.Debug(() => "second stage", new Dictionary<string, string>
        {
            ["provider"] = Provider.Name,
            ["in"] = transcript.Length.ToString(),
            ["out"] = rewritten.Length.ToString(),
            ["ms"] = ((long)(DateTimeOffset.Now - started).TotalMilliseconds).ToString(),
        });

        // A second stage that comes back empty is a failure of the second stage, not of the
        // dictation: the words survive either way.
        if (rewritten.Length == 0)
        {
            Log.Warn(() => "second stage returned nothing; keeping the transcript",
                new Dictionary<string, string> { ["provider"] = Provider.Name });
            return transcript;
        }
        return rewritten;
    }

    /// <summary>
    /// Passed through to backends that have no system instruction to read it from. Model providers
    /// ignore it, having received the same setting baked into the prompt.
    /// </summary>
    public Fidelity Fidelity { get; init; } = Fidelity.Light;

    /// <summary>
    /// Whether to derive a keyterm list from the screen for recognition backends.
    ///
    /// Off by default, and that default is a position rather than caution about a new feature.
    /// Keyterm biasing is a vocabulary prior — the mechanism the README singles out as the thing
    /// that makes a dictation tool overrule clear audio — and it arrives without the "reference
    /// only" framing that makes the same information safe to give a model.
    /// </summary>
    public bool KeytermBiasing { get; init; }

    /// <summary>User-supplied spellings. This is independent of optional screen grounding.</summary>
    public IReadOnlyList<string> PersonalDictionary { get; init; } = [];

    /// <summary>
    /// Whether a request that has stalled is joined by a second identical one, the faster of the
    /// two winning. See <see cref="StallHedge"/> for what counts as stalled and why it is not a
    /// timeout.
    ///
    /// <para>On by default, because the tail it exists for is the single worst thing about
    /// dictating through a network. Off for measurement: a benchmark that reports the better of two
    /// draws is not reporting the backend's latency.</para>
    /// </summary>
    public bool HedgeStalledRequests { get; init; } = true;

    public async Task<TranscriptionResult> TranscribeAsync(
        byte[] wav,
        ScreenContext? context,
        CancellationToken cancellationToken = default,
        ConnectionPreference connection = ConnectionPreference.Pooled)
    {
        var parts = new List<InputPart>();
        IReadOnlyList<string> keyterms = [];

        if (Provider.Grounding is GroundingSupport.MultimodalGrounding
            && DoNotType.Core.PersonalDictionary.ReferenceBlock(PersonalDictionary) is { } reference)
        {
            parts.Add(new InputPart.Text(reference));
        }

        // Each backend is sent only what it can use. Encoding ten thousand characters of screen
        // text for an endpoint whose request body is raw audio would not merely be wasted — it
        // would put a "grounded" request in the history for a transcript produced without it.
        if (context is not null && !context.IsEmpty)
        {
            switch (Provider.Grounding)
            {
                case GroundingSupport.MultimodalGrounding:
                    parts.AddRange(_encoder.Encode(context));
                    break;
                case GroundingSupport.KeytermGrounding keyterm when KeytermBiasing:
                    keyterms = DoNotType.Core.PersonalDictionary.MergeKeyterms(
                        PersonalDictionary,
                        Keyterms.Derive(context, keyterm.MaxTerms, keyterm.MaxCharsPerTerm),
                        keyterm.MaxTerms, keyterm.MaxCharsPerTerm);
                    break;
            }
        }

        if (Provider.Grounding is GroundingSupport.KeytermGrounding speech && keyterms.Count == 0)
        {
            keyterms = DoNotType.Core.PersonalDictionary.Keyterms(
                PersonalDictionary, speech.MaxTerms, speech.MaxCharsPerTerm);
        }

        // Falls back to the WAV whenever libopus is unavailable or the encode fails, because a
        // compression optimisation must never be able to cost someone their words.
        parts.Add(CompressedPart(wav));

        var result = await Provider.TranscribeAsync(
                systemInstruction, parts, cancellationToken: cancellationToken,
                fidelity: Fidelity, keyterms: keyterms, connection: connection)
            .ConfigureAwait(false);

        // Here rather than at the call site, because every backend and every caller — dictation,
        // file transcription, retry — comes through this one method, and a guard some of them skip
        // is a guard that will be skipped by the one that matters. The duration comes from the WAV
        // rather than the compressed payload, whose length is not readable without decoding it.
        var (checkedTranscript, verdict) = HallucinationGuard.Inspect(
            result.Transcript, AudioChunker.DurationSeconds(wav));
        if (verdict.Reason == HallucinationGuard.Reason.Kept)
        {
            return result;
        }

        // Warning, not debug: text the user never said was about to be typed into whatever they had
        // focused, and the whole measurement goes in the line so the threshold can be argued with
        // from the log alone.
        Log.Warn(() => "transcript discarded — the audio cannot contain it",
            new Dictionary<string, string>
            {
                ["provider"] = Provider.Name,
                ["reason"] = verdict.Summary,
            });
        return result with { Transcript = checkedTranscript };
    }

    /// <summary>
    /// One request, joined by a second identical one if it stalls. See <see cref="StallHedge"/>.
    /// </summary>
    /// <remarks>
    /// Wrapped here rather than around <see cref="TranscribeAsync"/> itself so the retry ladder
    /// below sees a single attempt: a stall and a failure are different problems with different
    /// remedies, and a request that stalled three times should still get its three tries at
    /// <em>failing</em>.
    ///
    /// <para>The duration comes from the audio this call was handed, which for a split recording is
    /// one chunk rather than the whole dictation. That is the right denominator — a chunk is what
    /// the request is being asked to transcribe.</para>
    /// </remarks>
    private async Task<TranscriptionResult> HedgedAttemptAsync(
        byte[] wav, ScreenContext? context, CancellationToken cancellationToken,
        ConnectionPreference connection = ConnectionPreference.Pooled)
    {
        if (!HedgeStalledRequests)
        {
            return await TranscribeAsync(wav, context, cancellationToken, connection)
                .ConfigureAwait(false);
        }

        var deadline = StallHedge.DeadlineFor(AudioChunker.DurationSeconds(wav));
        return await StallHedge.RaceAsync(
                deadline,
                // The duplicate goes out on a connection of its own. On the same one it is not a
                // second draw — it is a second stream on whatever the original is stuck behind.
                // See ProviderTransport.
                (isHedge, token) => TranscribeAsync(
                    wav, context, token,
                    isHedge ? ConnectionPreference.Fresh : connection),
                // Info, not debug: this is the app spending a second request on the user's behalf.
                // A hedge that fires on every dictation is a backend having a bad day rather than a
                // working feature, and that should be visible without turning anything on.
                () => Log.Info(() => "request stalled; sending a second one",
                    new Dictionary<string, string>
                    {
                        ["provider"] = Provider.Name,
                        ["after"] = $"{deadline.TotalSeconds:0.0}s",
                    }),
                cancellationToken)
            .ConfigureAwait(false);
    }

    /// <summary>
    /// Retries with exponential backoff, giving up early on errors that will not change.
    /// </summary>
    public async Task<TranscriptionResult> TranscribeWithRetryAsync(
        byte[] wav,
        ScreenContext? context,
        int attempts = 3,
        CancellationToken cancellationToken = default)
    {
        var delay = TimeSpan.FromMilliseconds(600);
        Exception last = new ProviderException("No attempt was made.");

        for (var attempt = 1; attempt <= Math.Max(1, attempts); attempt++)
        {
            try
            {
                // Every attempt after the first opens its own connection. The one it would
                // otherwise reuse is the one that just failed, and that is measurably why a retry
                // succeeds at all: on macOS all sixteen slow dictations finished in 2-6 s once the
                // request went out on a new connection.
                return await HedgedAttemptAsync(
                        wav, context, cancellationToken,
                        attempt == 1 ? ConnectionPreference.Pooled : ConnectionPreference.Fresh)
                    .ConfigureAwait(false);
            }
            catch (Exception error) when (error is ProviderException or HttpRequestException or TaskCanceledException)
            {
                last = error;
                if (attempt >= attempts || !IsTransient(error)) throw;

                await Task.Delay(delay, cancellationToken).ConfigureAwait(false);
                delay *= 2;
            }
        }
        throw last;
    }

    /// <summary>
    /// Transcribes a recording of any length, splitting long ones across concurrent requests.
    /// </summary>
    /// <remarks>
    /// Every chunk carries the <em>same</em> screen context. That is what stops chunk three
    /// spelling a name differently from chunk two -- the requests are independent and have no idea
    /// what the others produced.
    ///
    /// Short recordings take the ordinary single-request path untouched, so this is safe to call
    /// unconditionally.
    /// </remarks>
    public async Task<TranscriptionResult> TranscribeLongAsync(
        byte[] wav,
        ScreenContext? context,
        int attempts = 3,
        int maxConcurrent = 3,
        Action<int, int>? onProgress = null,
        CancellationToken cancellationToken = default)
    {
        var chunks = AudioChunker.Split(wav);

        // Reported before the first request rather than after it, so a caller showing a counter has
        // the total straight away. It is also the only place that knows it without splitting the
        // audio a second time, which on a long recording is a second copy of it in memory.
        onProgress?.Invoke(0, chunks.Count);

        if (chunks.Count <= 1)
        {
            return await TranscribeWithRetryAsync(wav, context, attempts, cancellationToken)
                .ConfigureAwait(false);
        }

        // Bounded concurrency: a ten-minute dictation is ten simultaneous requests otherwise, which
        // is the fastest way to hit a rate limit and turn a slow dictation into a failed one.
        using var gate = new SemaphoreSlim(maxConcurrent);
        var finished = 0;

        var tasks = chunks.Select(async chunk =>
        {
            await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
            try
            {
                var result = await TranscribeWithRetryAsync(
                        chunk.Data, context, attempts, cancellationToken)
                    .ConfigureAwait(false);
                onProgress?.Invoke(Interlocked.Increment(ref finished), chunks.Count);
                return result;
            }
            finally
            {
                gate.Release();
            }
        });

        var results = await Task.WhenAll(tasks).ConfigureAwait(false);
        return new TranscriptionResult(
            new Transcript(
                AudioChunker.Stitch(results.Select(result => result.Transcript.Text)),
                results.FirstOrDefault()?.Transcript.Language ?? string.Empty),
            results.Aggregate(new TokenUsage(), (total, result) => TokenUsage.Add(total, result.Usage)),
            string.Join("\n", results.Select(result => result.RawOutput)),
            results.Length);
    }

    /// <summary>The recording as Ogg Opus, or as WAV if that is not possible.</summary>
    internal static InputPart CompressedPart(byte[] wav)
    {
        var ogg = OpusEncoder.Encode(wav);
        return ogg is not null
            ? new InputPart.Audio(ogg, "audio/ogg")
            : new InputPart.Audio(wav, "audio/wav");
    }

    public static bool IsTransient(Exception error) => error switch
    {
        ProviderException provider => provider.IsTransient,
        HttpRequestException => true,
        TaskCanceledException => true,
        IOException => true,
        _ => false,
    };
}
