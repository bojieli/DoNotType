using System.Net.Http.Headers;
using System.Text;
using System.Text.Json.Nodes;

namespace DoNotType.Core;

/// <summary>
/// Any <c>/v1/chat/completions</c> gateway — OpenRouter and most others.
///
/// The second implementation exists mainly to keep <see cref="ITranscriptionProvider"/> honest. It
/// differs from Gemini in ways the interface has to accommodate rather than paper over: a
/// different request shape and a different usage field for audio tokens.
/// </summary>
public sealed class OpenAiCompatibleProvider(
    string name,
    string endpoint,
    string apiKey,
    string model,
    IReadOnlyDictionary<string, string>? extraHeaders = null,
    string? reasoningEffort = "minimal",
    HttpClient? httpClient = null) : ITranscriptionProvider, IStyledTranscriptionProvider
{
    /// <summary>The connection this request goes out on. See <see cref="ProviderTransport"/>.</summary>
    /// <remarks>An injected client wins, so a test still talks to its own stub.</remarks>
    private HttpClient Http(ConnectionPreference connection) =>
        httpClient ?? ProviderTransport.Client(new Uri(endpoint), connection);

    public Uri? EndpointOrigin => ProviderTransport.Origin(new Uri(endpoint));

    public string Name => name;

    public string Model => model;

    /// <remarks>See <see cref="GeminiProvider"/>: fidelity travels in the system instruction here.</remarks>
    public Task<TranscriptionResult> TranscribeAsync(
        string systemInstruction,
        IReadOnlyList<InputPart> parts,
        int maxOutputTokens = 2048,
        CancellationToken cancellationToken = default,
        Fidelity fidelity = Fidelity.Light,
        IReadOnlyList<string>? keyterms = null,
        ConnectionPreference connection = ConnectionPreference.Pooled) =>
        TranscribeStyledAsync(
            systemInstruction, parts, maxOutputTokens, cancellationToken, fidelity, keyterms,
            connection, wantsStyledOutput: false);

    public async Task<TranscriptionResult> TranscribeStyledAsync(
        string systemInstruction,
        IReadOnlyList<InputPart> parts,
        int maxOutputTokens = 2048,
        CancellationToken cancellationToken = default,
        Fidelity fidelity = Fidelity.Light,
        IReadOnlyList<string>? keyterms = null,
        ConnectionPreference connection = ConnectionPreference.Pooled,
        bool wantsStyledOutput = false)
    {
        var content = new JsonArray();
        foreach (var part in parts)
        {
            switch (part)
            {
                case InputPart.Text textPart:
                    content.Add(new JsonObject { ["type"] = "text", ["text"] = textPart.Value });
                    break;
                case InputPart.Image image:
                    content.Add(new JsonObject
                    {
                        ["type"] = "image_url",
                        ["image_url"] = new JsonObject
                        {
                            ["url"] = $"data:{image.MimeType};base64,{Convert.ToBase64String(image.Data)}",
                        },
                    });
                    break;
                case InputPart.Audio audio:
                    content.Add(new JsonObject
                    {
                        ["type"] = "input_audio",
                        ["input_audio"] = new JsonObject
                        {
                            ["data"] = Convert.ToBase64String(audio.Data),
                            ["format"] = AudioFormat(audio.MimeType),
                        },
                    });
                    break;
            }
        }

        var body = new JsonObject
        {
            ["model"] = model,
            ["messages"] = new JsonArray(
                new JsonObject { ["role"] = "system", ["content"] = systemInstruction },
                new JsonObject { ["role"] = "user", ["content"] = content }),
            ["max_tokens"] = maxOutputTokens,
            ["response_format"] = new JsonObject
            {
                ["type"] = "json_schema",
                ["json_schema"] = new JsonObject
                {
                    ["name"] = "transcript",
                    ["strict"] = true,
                    ["schema"] = wantsStyledOutput ? Transcript.StyledSchema() : Transcript.Schema(),
                },
            },
        };
        if (reasoningEffort is not null)
        {
            body["reasoning"] = new JsonObject { ["effort"] = reasoningEffort };
        }

        using var request = new HttpRequestMessage(HttpMethod.Post, endpoint);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", apiKey);
        foreach (var (key, value) in extraHeaders ?? new Dictionary<string, string>())
        {
            request.Headers.TryAddWithoutValidation(key, value);
        }
        request.Content = new StringContent(body.ToJsonString(), Encoding.UTF8, "application/json");

        using var response = await Http(connection).SendLoggedAsync(request, Name, Model, cancellationToken).ConfigureAwait(false);
        var text = await response.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false);

        if (!response.IsSuccessStatusCode)
        {
            var status = (int)response.StatusCode;
            throw new ProviderException($"HTTP {status}: {text}")
            {
                IsTransient = status is 408 or 429 or >= 500,
                Status = status,
                Body = text,
            };
        }

        var root = JsonNode.Parse(text)?.AsObject()
            ?? throw new ProviderException("Response was not a JSON object.");

        // Some gateways return HTTP 200 with an error object in the body.
        if (root["error"] is JsonObject error)
        {
            throw new ProviderException($"Provider error: {error.ToJsonString()}");
        }

        var usage = ParseUsage(root["usage"]?.AsObject());
        if (parts.Any(p => p is InputPart.Audio) && usage.AudioTokens == 0)
        {
            throw new ProviderException(
                $"{name} accepted the audio but billed 0 audio tokens for {model} — the recording "
                + "never reached the model, so any transcript it returned is fabricated.")
            {
                IsTransient = false,
            };
        }

        var output = root["choices"]?[0]?["message"]?["content"]?.GetValue<string>();
        if (string.IsNullOrWhiteSpace(output)) throw new ProviderException("Model returned no output.");

        return new TranscriptionResult(Transcript.Parse(output), usage, output);
    }

    /// <summary>The <c>format</c> field wants a bare codec name, not a MIME type.</summary>
    internal static string AudioFormat(string mimeType) => mimeType.ToLowerInvariant() switch
    {
        "audio/wav" or "audio/x-wav" or "audio/wave" => "wav",
        "audio/flac" or "audio/x-flac" => "flac",
        "audio/mpeg" or "audio/mp3" => "mp3",
        "audio/ogg" or "audio/opus" => "ogg",
        "audio/aac" => "aac",
        _ => mimeType.Replace("audio/", string.Empty),
    };

    private static TokenUsage ParseUsage(JsonObject? usage)
    {
        if (usage is null) return new TokenUsage();
        var details = usage["prompt_tokens_details"]?.AsObject();
        return new TokenUsage(
            usage["prompt_tokens"]?.GetValue<int>(),
            usage["completion_tokens"]?.GetValue<int>(),
            details?["audio_tokens"]?.GetValue<int>());
    }
}
