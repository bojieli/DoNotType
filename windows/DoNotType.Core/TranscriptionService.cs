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
    /// Rewrites or summarises a finished transcript when a compatible second stage is needed.
    /// Text in, text out -- no audio, no screen.
    /// </summary>
    /// <remarks>
    /// The live and short model-backed paths fold rewrites into the audio request. This method stays
    /// as the compatibility path for recognizers, split recordings, and older responses.
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
        return DoNotType.Core.Typography.Normalize(rewritten, Typography);
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

    /// <summary>
    /// What to do where Chinese or Japanese meets Latin in whatever comes back. See
    /// <see cref="Typography"/>.
    /// </summary>
    /// <remarks>
    /// It lives here, on the object every path goes through — dictation, file transcription, retry,
    /// redo, the CLI — for the same reason the hallucination guard does: a transform some callers
    /// apply is a transform that will be missing from the one that matters. A history row and a
    /// live insertion of the same words must not be spaced differently.
    /// </remarks>
    public TypographySpacing Typography { get; init; } = DoNotType.Core.Typography.DefaultSpacing;

    public async Task<TranscriptionResult> TranscribeAsync(
        byte[] wav,
        ScreenContext? context,
        CancellationToken cancellationToken = default,
        ConnectionPreference connection = ConnectionPreference.Pooled,
        string? styleClause = null)
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

        // A rewrite can be folded into the audio request for multimodal model providers. The
        // response carries both fields, so the verbatim wording remains available without a
        // second round trip. Recognition backends keep the ordinary request and the caller falls
        // back to its existing text stage.
        var foldsInStyle = styleClause is not null
            && Provider.Grounding is GroundingSupport.MultimodalGrounding;
        var instruction = foldsInStyle
            ? systemInstruction + StyledInstructionSuffix(styleClause!)
            : systemInstruction;

        var result = foldsInStyle && Provider is IStyledTranscriptionProvider styledProvider
            ? await styledProvider.TranscribeStyledAsync(
                instruction, parts, cancellationToken: cancellationToken,
                fidelity: Fidelity, keyterms: keyterms, connection: connection,
                wantsStyledOutput: true)
            : await Provider.TranscribeAsync(
                instruction, parts, cancellationToken: cancellationToken,
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
            // The other end of the same question, and the one nothing used to ask: is this
            // transcript too *small* for the recording? Screened on the WAV header, which is free,
            // and only then measured against Silero — so the model runs on roughly the bottom tenth
            // of transcripts rather than on all of them. Nothing is removed; a truncated transcript
            // is part of what was said, and the remedy belongs to the caller.
            if (TruncationGuard.WarrantsInspection(
                    result.Transcript.Text, AudioChunker.DurationSeconds(wav)))
            {
                double? speechSeconds = null;
                try
                {
                    speechSeconds = SpeechActivity.Measure(wav).SpeechMilliseconds / 1000.0;
                }
                catch
                {
                    // No reading, no accusation.
                }

                var truncation = TruncationGuard.Inspect(result.Transcript.Text, speechSeconds);
                if (truncation.IsSuspect)
                {
                    // Warning for the same reason the guard above is: the user is about to be
                    // handed text with their own words missing from the middle of it, and nothing
                    // else in the pipeline will say so.
                    Log.Warn(() => "transcript is too short for the speech in the recording",
                        new Dictionary<string, string>
                        {
                            ["provider"] = Provider.Name,
                            ["detail"] = truncation.Summary,
                        });
                    return WithTypography(result with { Truncation = truncation });
                }
            }

            return WithTypography(result);
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
        return WithTypography(result with { Transcript = checkedTranscript });
    }

    /// <summary>
    /// Applies the user's typography to a finished result.
    /// </summary>
    /// <remarks>
    /// After the guards, never before. Both of them measure the transcript against the audio, and a
    /// space this added or removed is not something either is entitled to see.
    /// </remarks>
    private TranscriptionResult WithTypography(TranscriptionResult result)
    {
        if (Typography == TypographySpacing.Unchanged) return result;
        return result with
        {
            Transcript = result.Transcript with
            {
                Text = DoNotType.Core.Typography.Normalize(result.Transcript.Text, Typography),
                Styled = result.Transcript.Styled is null
                    ? null
                    : DoNotType.Core.Typography.Normalize(result.Transcript.Styled, Typography),
            },
        };
    }

    private static string StyledInstructionSuffix(string styleClause) => """


        Return `transcript` as the exact verbatim transcription, unchanged, and `styled` as that same
        transcript rewritten in the style below. The rewrite may not alter any number, name,
        identifier or fact that appears in `transcript`.

        """ + styleClause;

    /// <summary>
    /// Transcribes and rewrites in one request where the backend supports the wider schema, with a
    /// second text-only pass as a compatibility fallback. The returned pair is stable either way.
    /// </summary>
    public async Task<(TranscriptionResult Result, string Styled, bool WasSinglePass)> TranscribeStyledAsync(
        byte[] wav,
        ScreenContext? context,
        string styleClause,
        string rewriteInstruction,
        CancellationToken cancellationToken = default)
    {
        var result = await TranscribeLongAsync(
                wav, context, styleClause: styleClause, cancellationToken: cancellationToken)
            .ConfigureAwait(false);
        var verbatim = result.Transcript.Text;
        var styled = result.Transcript.Styled?.Trim();
        if (!string.IsNullOrWhiteSpace(styled))
        {
            return (result, styled, true);
        }

        if (string.IsNullOrWhiteSpace(verbatim)) return (result, verbatim, false);
        var derived = await RewriteAsync(verbatim, rewriteInstruction, cancellationToken)
            .ConfigureAwait(false);
        return (result, derived, false);
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
        ConnectionPreference connection = ConnectionPreference.Pooled,
        string? styleClause = null)
    {
        if (!HedgeStalledRequests)
        {
            return await TranscribeAsync(wav, context, cancellationToken, connection, styleClause)
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
                    isHedge ? ConnectionPreference.Fresh : connection, styleClause),
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
        CancellationToken cancellationToken = default,
        string? styleClause = null)
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
                        attempt == 1 ? ConnectionPreference.Pooled : ConnectionPreference.Fresh,
                        styleClause)
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
        CancellationToken cancellationToken = default,
        string? styleClause = null)
    {
        var chunks = AudioChunker.Split(wav);

        // Reported before the first request rather than after it, so a caller showing a counter has
        // the total straight away. It is also the only place that knows it without splitting the
        // audio a second time, which on a long recording is a second copy of it in memory.
        onProgress?.Invoke(0, chunks.Count);

        if (chunks.Count <= 1)
        {
            return await TranscribeWithRetryAsync(
                    wav, context, attempts, cancellationToken, styleClause)
                .ConfigureAwait(false);
        }

        // A split recording is stitched from independent requests, so style it once after the
        // verbatim chunks are joined rather than producing separately rewritten fragments.

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
                // Again, over the join this time. Each chunk was normalised on its own and the
                // stitch adds one space between them, which after a full stop is exactly the stray
                // space this removes. Normalising twice is normalising once.
                DoNotType.Core.Typography.Normalize(
                    AudioChunker.Stitch(results.Select(result => result.Transcript.Text)),
                    Typography),
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
