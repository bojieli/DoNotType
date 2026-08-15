using System.Net.Http.Headers;
using System.Text;
using System.Text.Json.Nodes;
using System.Web;

namespace DoNotType.Core;

/// <summary>
/// The speech recognition backends, which are not language models.
///
/// Kept in one file because they are variations on a single shape — audio in, text out, no system
/// instruction — and three files of forty lines each would hide that. What differs between them is
/// transport and one capability flag, which is easier to see side by side.
///
/// None of them can serve a text-only request, so rewriting fails here with a message that says to
/// switch provider rather than a bare HTTP 400.
/// </summary>
internal static class SpeechRecognition
{
    internal static InputPart.Audio RequireAudio(IReadOnlyList<InputPart> parts, string provider) =>
        parts.OfType<InputPart.Audio>().FirstOrDefault()
        ?? throw new ProviderException(
            $"{provider} is a speech recognition endpoint and only accepts audio. It cannot " +
            "rewrite or reformat text that has already been transcribed — switch to a model " +
            "provider for that.")
        { IsTransient = false };

    /// <summary>The container is auto-detected, but a filename with no extension is the kind of
    /// thing a strict multipart parser rejects, and it costs one switch to send a true one.</summary>
    internal static string FileExtension(string mimeType) => mimeType.ToLowerInvariant() switch
    {
        "audio/wav" or "audio/x-wav" or "audio/wave" => "wav",
        "audio/flac" or "audio/x-flac" => "flac",
        "audio/mpeg" or "audio/mp3" => "mp3",
        "audio/ogg" or "audio/opus" => "ogg",
        "audio/aac" => "aac",
        _ => "bin",
    };

    internal static string Truncate(string value, int max) =>
        value.Length <= max ? value : value[..max];
}

/// <summary>
/// Deepgram's <c>/v1/listen</c>.
///
/// <para><c>language</c> defaults to nova-3's <c>multi</c> rather than <c>detect_language</c>,
/// which is measured rather than read off the documentation: detection scored 12/42 against
/// multi's 18/42 on the near-miss suite, and fails by returning HTTP 200 with an <em>empty</em>
/// transcript when it guesses wrong. Neither setting transcribes Mandarin — <c>language=zh</c>
/// does. See docs/EVALUATION.md.</para>
/// </summary>
public sealed class DeepgramProvider(
    string apiKey,
    string model = "nova-3",
    string? language = null,
    HttpClient? httpClient = null) : ITranscriptionProvider
{
    private const string Endpoint = "https://api.deepgram.com/v1/listen";
    internal const string KeytermCapablePrefix = "nova-3";
    internal const int MaxKeyterms = 100;
    internal const int MaxKeytermChars = 50;

    private static readonly HttpClient Shared = new() { Timeout = TimeSpan.FromSeconds(150) };
    private HttpClient Http => httpClient ?? Shared;

    public string Name => "deepgram";
    public string Model => model;

    /// <summary>The Files API is Google-specific; there is no equivalent here.</summary>
    public bool SupportsPreUpload => false;

    /// <summary>
    /// Answered per-model, because the biasing channel only exists on nova-3. A provider that
    /// claimed keyterms while configured with nova-2 would have the service derive terms, send
    /// them, and get a 400 for its trouble.
    /// </summary>
    public GroundingSupport Grounding =>
        model.StartsWith(KeytermCapablePrefix, StringComparison.Ordinal)
            ? GroundingSupport.Keyterms(MaxKeyterms, MaxKeytermChars)
            : GroundingSupport.None;

    public async Task<TranscriptionResult> TranscribeAsync(
        string systemInstruction,
        IReadOnlyList<InputPart> parts,
        int maxOutputTokens = 2048,
        CancellationToken cancellationToken = default,
        Fidelity fidelity = Fidelity.Light,
        IReadOnlyList<string>? keyterms = null)
    {
        var audio = SpeechRecognition.RequireAudio(parts, Name);

        var query = new StringBuilder("?model=").Append(HttpUtility.UrlEncode(model));
        // The fidelity ladder in the only vocabulary this endpoint has, which has two rungs where
        // PROMPT.md has three. `light` and `tidy` collapse: Deepgram's only unpunctuated mode also
        // returns everything lower case, which breaks `light`'s "keep proper nouns" clause more
        // visibly than adding punctuation breaks its other half.
        query.Append(fidelity == Fidelity.Raw
            ? "&punctuate=false&smart_format=false&filler_words=true"
            : "&smart_format=true&filler_words=false");
        query.Append(LanguageQuery(language, model));

        if (Grounding is GroundingSupport.KeytermGrounding && keyterms is not null)
        {
            foreach (var term in keyterms.Take(MaxKeyterms).Where(t => t.Length <= MaxKeytermChars))
            {
                query.Append("&keyterm=").Append(HttpUtility.UrlEncode(term));
            }
        }

        using var request = new HttpRequestMessage(HttpMethod.Post, Endpoint + query);
        request.Headers.TryAddWithoutValidation("Authorization", $"Token {apiKey}");
        request.Content = new ByteArrayContent(audio.Data);
        request.Content.Headers.ContentType = new MediaTypeHeaderValue(audio.MimeType);

        using var response = await Http.SendLoggedAsync(request, Name, Model, cancellationToken).ConfigureAwait(false);
        var body = await response.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false);
        if (!response.IsSuccessStatusCode)
        {
            throw new ProviderException($"HTTP {(int)response.StatusCode}: {ErrorMessage(body)}")
            {
                IsTransient = (int)response.StatusCode is 408 or 429 or >= 500,
                Status = (int)response.StatusCode,
                Body = body,
            };
        }

        var transcript = Parse(body);
        if (string.IsNullOrWhiteSpace(transcript.Text))
        {
            throw new ProviderException("Model returned no output.");
        }

        // Deliberately no usage: Deepgram bills by audio duration and reports no token counts.
        // Reporting zero audio tokens would trip the silent-drop guard on every successful call.
        return new TranscriptionResult(transcript, new TokenUsage(), body);
    }

    /// <summary><c>multi</c> is nova-3 only; sending it to an older model is a 400.</summary>
    internal static string LanguageQuery(string? explicitLanguage, string model)
    {
        if (!string.IsNullOrEmpty(explicitLanguage))
        {
            return "&language=" + HttpUtility.UrlEncode(explicitLanguage);
        }
        return model.StartsWith(KeytermCapablePrefix, StringComparison.Ordinal)
            ? "&language=multi"
            : "&detect_language=true";
    }

    internal static Transcript Parse(string body)
    {
        var channel = JsonNode.Parse(body)?["results"]?["channels"]?[0]
            ?? throw new ProviderException(
                $"No transcript in response: {SpeechRecognition.Truncate(body, 200)}");
        var text = channel["alternatives"]?[0]?["transcript"]?.GetValue<string>()
            ?? throw new ProviderException(
                $"No transcript in response: {SpeechRecognition.Truncate(body, 200)}");
        return new Transcript(text.Trim(), channel["detected_language"]?.GetValue<string>() ?? "");
    }

    /// <summary>Deepgram reports failures as <c>{"err_code":…,"err_msg":…}</c>.</summary>
    internal static string ErrorMessage(string body)
    {
        try
        {
            var root = JsonNode.Parse(body)?.AsObject();
            var message = root?["err_msg"]?.GetValue<string>() ?? root?["message"]?.GetValue<string>();
            var code = root?["err_code"]?.GetValue<string>();
            return (message, code) switch
            {
                (not null, not null) => $"{message} ({code})",
                (not null, null) => message,
                _ => SpeechRecognition.Truncate(body, 400),
            };
        }
        catch (Exception)
        {
            return SpeechRecognition.Truncate(body, 400);
        }
    }
}

/// <summary>
/// Mistral Voxtral, <c>POST /v1/audio/transcriptions</c>.
///
/// <para>The recognition backend that transcribes Mandarin and English without being told which is
/// coming, including inside one sentence. It has no biasing channel: <c>context=</c> and
/// <c>prompt=</c> are both accepted with HTTP 200 and both leave the transcript byte-identical, so
/// <see cref="Grounding"/> is None rather than keyterms. Measured, not assumed.</para>
/// </summary>
public sealed class MistralProvider(
    string apiKey,
    string model = "voxtral-mini-latest",
    string? language = null,
    HttpClient? httpClient = null) : ITranscriptionProvider
{
    private const string Endpoint = "https://api.mistral.ai/v1/audio/transcriptions";

    private static readonly HttpClient Shared = new() { Timeout = TimeSpan.FromSeconds(150) };
    private HttpClient Http => httpClient ?? Shared;

    public string Name => "mistral";
    public string Model => model;
    public bool SupportsPreUpload => false;
    public GroundingSupport Grounding => GroundingSupport.None;

    public async Task<TranscriptionResult> TranscribeAsync(
        string systemInstruction,
        IReadOnlyList<InputPart> parts,
        int maxOutputTokens = 2048,
        CancellationToken cancellationToken = default,
        Fidelity fidelity = Fidelity.Light,
        IReadOnlyList<string>? keyterms = null)
    {
        var audio = SpeechRecognition.RequireAudio(parts, Name);

        using var form = new MultipartFormDataContent();
        form.Add(new StringContent(model), "model");
        if (!string.IsNullOrEmpty(language)) form.Add(new StringContent(language), "language");
        // No fidelity field: the endpoint exposes no formatting or disfluency control, and it
        // accepts unknown fields silently, so sending an invented one would be worse than none.
        var file = new ByteArrayContent(audio.Data);
        file.Headers.ContentType = new MediaTypeHeaderValue(audio.MimeType);
        form.Add(file, "file", $"audio.{SpeechRecognition.FileExtension(audio.MimeType)}");

        using var request = new HttpRequestMessage(HttpMethod.Post, Endpoint) { Content = form };
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", apiKey);

        using var response = await Http.SendLoggedAsync(request, Name, Model, cancellationToken).ConfigureAwait(false);
        var body = await response.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false);
        if (!response.IsSuccessStatusCode)
        {
            throw new ProviderException($"HTTP {(int)response.StatusCode}: {ErrorMessage(body)}")
            {
                IsTransient = (int)response.StatusCode is 408 or 429 or >= 500,
            };
        }

        var usage = ParseUsage(body);
        // Unlike the others, Voxtral does report audio tokens, so the silent-drop guard is live
        // here rather than skipped for want of a number.
        if (usage.AudioTokens == 0)
        {
            throw new ProviderException(
                $"{Name} accepted the audio but billed 0 audio tokens for {model} — the recording " +
                "never reached the model, so any transcript it returned is fabricated.")
            { IsTransient = false };
        }

        var transcript = Parse(body);
        if (string.IsNullOrWhiteSpace(transcript.Text))
        {
            throw new ProviderException("Model returned no output.");
        }
        return new TranscriptionResult(transcript, usage, body);
    }

    internal static Transcript Parse(string body)
    {
        var root = JsonNode.Parse(body)?.AsObject()
            ?? throw new ProviderException("Response was not a JSON object.");
        var text = root["text"]?.GetValue<string>()
            ?? throw new ProviderException(
                $"No text in response: {SpeechRecognition.Truncate(body, 200)}");
        // `language` is present but observed null on every clip tested, including ones Voxtral
        // transcribed correctly in Mandarin. Absent means "not reported", not "English".
        return new Transcript(text.Trim(), root["language"]?.GetValue<string>() ?? "");
    }

    internal static TokenUsage ParseUsage(string body)
    {
        var usage = JsonNode.Parse(body)?["usage"];
        if (usage is null) return new TokenUsage();
        return new TokenUsage(
            (int?)usage["prompt_tokens"],
            (int?)usage["completion_tokens"],
            (int?)usage["prompt_tokens_details"]?["audio_tokens"]);
    }

    internal static string ErrorMessage(string body)
    {
        try
        {
            var root = JsonNode.Parse(body)?.AsObject();
            var message = root?["message"]?.GetValue<string>()
                ?? root?["error"]?["message"]?.GetValue<string>();
            return message ?? SpeechRecognition.Truncate(body, 400);
        }
        catch (Exception)
        {
            return SpeechRecognition.Truncate(body, 400);
        }
    }
}

/// <summary>
/// xAI's <c>/v1/stt</c>.
///
/// <para><b>Never verified against the live API.</b> Every xAI key available when this was written
/// was rejected with <c>Incorrect API key provided</c> on every endpoint and auth scheme, so this
/// is written to the published specification. Its error parsing is confirmed against the real 400
/// body; nothing else about it has been exercised.</para>
/// </summary>
public sealed class XAISpeechProvider(
    string apiKey,
    string model = "grok-stt",
    string? language = null,
    HttpClient? httpClient = null) : ITranscriptionProvider
{
    private const string Endpoint = "https://api.x.ai/v1/stt";
    internal const int MaxKeyterms = 100;
    internal const int MaxKeytermChars = 50;

    private static readonly HttpClient Shared = new() { Timeout = TimeSpan.FromSeconds(150) };
    private HttpClient Http => httpClient ?? Shared;

    public string Name => "xai";
    public string Model => model;
    public bool SupportsPreUpload => false;
    public GroundingSupport Grounding => GroundingSupport.Keyterms(MaxKeyterms, MaxKeytermChars);

    public async Task<TranscriptionResult> TranscribeAsync(
        string systemInstruction,
        IReadOnlyList<InputPart> parts,
        int maxOutputTokens = 2048,
        CancellationToken cancellationToken = default,
        Fidelity fidelity = Fidelity.Light,
        IReadOnlyList<string>? keyterms = null)
    {
        var audio = SpeechRecognition.RequireAudio(parts, Name);

        using var form = new MultipartFormDataContent();
        // `format` is inverse text normalisation — spoken numbers written as numerals. On for
        // `light` as well as `tidy`, so numbers do not diverge from every other backend.
        form.Add(new StringContent(fidelity == Fidelity.Raw ? "false" : "true"), "format");
        form.Add(new StringContent(fidelity == Fidelity.Raw ? "true" : "false"), "filler_words");
        if (!string.IsNullOrEmpty(language)) form.Add(new StringContent(language), "language");
        foreach (var term in (keyterms ?? []).Take(MaxKeyterms).Where(t => t.Length <= MaxKeytermChars))
        {
            form.Add(new StringContent(term), "keyterm");
        }
        var file = new ByteArrayContent(audio.Data);
        file.Headers.ContentType = new MediaTypeHeaderValue(audio.MimeType);
        form.Add(file, "file", $"audio.{SpeechRecognition.FileExtension(audio.MimeType)}");

        using var request = new HttpRequestMessage(HttpMethod.Post, Endpoint) { Content = form };
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", apiKey);

        using var response = await Http.SendLoggedAsync(request, Name, Model, cancellationToken).ConfigureAwait(false);
        var body = await response.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false);
        if (!response.IsSuccessStatusCode)
        {
            throw new ProviderException($"HTTP {(int)response.StatusCode}: {ErrorMessage(body)}")
            {
                IsTransient = (int)response.StatusCode is 408 or 429 or >= 500,
            };
        }

        var root = JsonNode.Parse(body)?.AsObject()
            ?? throw new ProviderException("Response was not a JSON object.");
        var transcript = new Transcript(
            (root["text"]?.GetValue<string>() ?? string.Empty).Trim(),
            root["language"]?.GetValue<string>() ?? "");
        if (string.IsNullOrWhiteSpace(transcript.Text))
        {
            throw new ProviderException("Model returned no output.");
        }
        return new TranscriptionResult(transcript, new TokenUsage(), body);
    }

    /// <summary>The one part of this provider confirmed against the live API.</summary>
    internal static string ErrorMessage(string body)
    {
        try
        {
            var root = JsonNode.Parse(body)?.AsObject();
            var message = root?["error"]?.GetValue<string>();
            var code = root?["code"]?.GetValue<string>();
            return (message, code) switch
            {
                (not null, not null) => $"{message} ({code})",
                (not null, null) => message,
                _ => SpeechRecognition.Truncate(body, 400),
            };
        }
        catch (Exception)
        {
            return SpeechRecognition.Truncate(body, 400);
        }
    }
}
