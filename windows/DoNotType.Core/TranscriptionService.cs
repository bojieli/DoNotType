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

    public ITranscriptionProvider Provider { get; } = provider;

    public async Task<TranscriptionResult> TranscribeAsync(
        byte[] wav,
        ScreenContext? context,
        InputPart? audioPart = null,
        CancellationToken cancellationToken = default)
    {
        var parts = new List<InputPart>();
        if (context is not null && !context.IsEmpty)
        {
            parts.AddRange(_encoder.Encode(context));
        }
        parts.Add(audioPart ?? new InputPart.Audio(wav, "audio/wav"));

        return await Provider.TranscribeAsync(systemInstruction, parts, cancellationToken: cancellationToken)
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
