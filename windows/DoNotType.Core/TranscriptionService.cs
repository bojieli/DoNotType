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

    public async Task<TranscriptionResult> TranscribeAsync(
        byte[] wav,
        ScreenContext? context,
        InputPart? audioPart = null,
        CancellationToken cancellationToken = default)
    {
        var parts = new List<InputPart>();
        IReadOnlyList<string> keyterms = [];

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
                    keyterms = Keyterms.Derive(context, keyterm.MaxTerms, keyterm.MaxCharsPerTerm);
                    break;
            }
        }

        // Compressed unless the caller already resolved the audio to a pre-uploaded reference.
        // Falls back to the WAV whenever libopus is unavailable or the encode fails, because a
        // compression optimisation must never be able to cost someone their words.
        parts.Add(audioPart ?? CompressedPart(wav));

        return await Provider.TranscribeAsync(
                systemInstruction, parts, cancellationToken: cancellationToken,
                fidelity: Fidelity, keyterms: keyterms)
            .ConfigureAwait(false);
    }

    /// <summary>
    /// Retries with exponential backoff, giving up early on errors that will not change.
    ///
    /// A pre-uploaded reference is used for the first attempt only; if it fails, later attempts
    /// fall back to inline bytes, because a URI that failed once may itself be the broken thing.
    /// </summary>
    public async Task<TranscriptionResult> TranscribeWithRetryAsync(
        byte[] wav,
        ScreenContext? context,
        InputPart? audioPart = null,
        int attempts = 3,
        CancellationToken cancellationToken = default)
    {
        var delay = TimeSpan.FromMilliseconds(600);
        Exception last = new ProviderException("No attempt was made.");
        var part = audioPart;

        for (var attempt = 1; attempt <= Math.Max(1, attempts); attempt++)
        {
            try
            {
                return await TranscribeAsync(wav, context, part, cancellationToken).ConfigureAwait(false);
            }
            catch (Exception error) when (error is ProviderException or HttpRequestException or TaskCanceledException)
            {
                last = error;
                if (attempt >= attempts || !IsTransient(error)) throw;

                part = null; // fall back to inline for every subsequent attempt
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
        InputPart? audioPart = null,
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
            var single = await TranscribeWithRetryAsync(
                    wav, context, audioPart, attempts, cancellationToken)
                .ConfigureAwait(false);
            onProgress?.Invoke(1, 1);
            return single;
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
                        chunk.Data, context, null, attempts, cancellationToken)
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

/// <summary>
/// Gets the recording to the model, by whichever route works.
///
/// A resumable Files API session is opened <em>while the user is still speaking</em>, so the
/// handshake is paid for during recording rather than after it. On release the finished file is
/// uploaded and referenced by URI, turning a megabytes-of-base64 request into a few hundred bytes
/// of JSON. Anything that goes wrong falls through to inline rather than failing the dictation.
///
/// One thing that emphatically does not work, tested rather than assumed: uploading audio in
/// chunks as it is captured. A WAV declares its length in the header, and one written with the
/// streaming convention (0xFFFFFFFF) uploads fine and is then rejected with "invalid argument".
/// So the file is uploaded once, complete.
/// </summary>
public sealed class GeminiAudioUploader(string apiKey, HttpClient? httpClient = null) : IAudioUploader
{
    /// <summary>Inline requests are capped at 20 MB including the prompt; base64 inflates by ~4/3.</summary>
    public const int InlineByteLimit = 14_000_000;

    private static readonly HttpClient Shared = new() { Timeout = TimeSpan.FromSeconds(90) };
    private readonly HttpClient _http = httpClient ?? Shared;

    private Task<string?>? _session;

    /// <summary>Starts opening a resumable session, without waiting for it. Call at hotkey-down.</summary>
    public void Prepare(int estimatedBytes, string mimeType = "audio/wav")
    {
        _session ??= OpenSessionAsync(estimatedBytes, mimeType);
    }

    public void Cancel() => _session = null;

    /// <summary>
    /// Chooses a route and returns the part to send. Never throws for network reasons alone — it
    /// degrades to inline. It throws only when the recording is too large to inline *and* the
    /// upload service is unreachable, which is the one case with no way through.
    /// </summary>
    public async Task<InputPart> PlanAsync(byte[] wav, string mimeType = "audio/wav")
    {
        var sessionUrl = _session is null ? null : await _session.ConfigureAwait(false);
        _session = null;

        // Compressed here rather than at the call site, so both routes get it. Putting it on the
        // inline path alone was a real bug on the Apple side: pre-upload is the primary route, so
        // the saving reached the eval harness and nobody else.
        var compressed = OpusEncoder.Encode(wav);
        if (compressed is not null)
        {
            wav = compressed;
            mimeType = "audio/ogg";
        }

        if (sessionUrl is not null)
        {
            try
            {
                var uri = await FinishUploadAsync(wav, sessionUrl).ConfigureAwait(false);
                return new InputPart.RemoteAudio(uri, mimeType);
            }
            catch (Exception e) when (e is HttpRequestException or TaskCanceledException or ProviderException)
            {
                // Deliberately swallowed: the inline path still works.
            }
        }

        if (wav.Length > InlineByteLimit)
        {
            throw new ProviderException(
                $"Recording is {wav.Length / 1_000_000} MB — too large to send inline, and the "
                + "upload service could not be reached.");
        }
        return new InputPart.Audio(wav, mimeType);
    }

    private async Task<string?> OpenSessionAsync(int estimatedBytes, string mimeType)
    {
        try
        {
            using var request = new HttpRequestMessage(
                HttpMethod.Post,
                $"https://generativelanguage.googleapis.com/upload/v1beta/files?key={apiKey}");
            request.Headers.TryAddWithoutValidation("X-Goog-Upload-Protocol", "resumable");
            request.Headers.TryAddWithoutValidation("X-Goog-Upload-Command", "start");
            request.Headers.TryAddWithoutValidation(
                "X-Goog-Upload-Header-Content-Length", estimatedBytes.ToString());
            request.Headers.TryAddWithoutValidation("X-Goog-Upload-Header-Content-Type", mimeType);
            request.Content = new StringContent(
                """{"file":{"display_name":"dictation"}}""", Encoding.UTF8, "application/json");

            using var response = await _http.SendAsync(request).ConfigureAwait(false);
            return response.Headers.TryGetValues("x-goog-upload-url", out var values)
                ? values.FirstOrDefault()
                : null;
        }
        catch (Exception e) when (e is HttpRequestException or TaskCanceledException)
        {
            // Not an error the user should see: the inline path still works.
            return null;
        }
    }

    private async Task<string> FinishUploadAsync(byte[] wav, string sessionUrl)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, sessionUrl)
        {
            Content = new ByteArrayContent(wav),
        };
        request.Headers.TryAddWithoutValidation("X-Goog-Upload-Offset", "0");
        request.Headers.TryAddWithoutValidation("X-Goog-Upload-Command", "upload, finalize");
        request.Content.Headers.ContentLength = wav.Length;

        using var response = await _http.SendAsync(request).ConfigureAwait(false);
        if (!response.IsSuccessStatusCode)
        {
            throw new ProviderException($"Upload failed: HTTP {(int)response.StatusCode}");
        }

        var body = await response.Content.ReadAsStringAsync().ConfigureAwait(false);
        var uri = JsonNode.Parse(body)?["file"]?["uri"]?.GetValue<string>();
        return uri ?? throw new ProviderException("Upload returned no file URI.");
    }
}
