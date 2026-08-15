using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace DoNotType.Core;

public sealed record Transcript(string Text, string Language = "")
{
    public static JsonObject Schema() => new()
    {
        ["type"] = "object",
        ["properties"] = new JsonObject
        {
            ["transcript"] = new JsonObject { ["type"] = "string" },
            ["language"] = new JsonObject { ["type"] = "string" },
        },
        ["required"] = new JsonArray("transcript", "language"),
    };

    /// <summary>
    /// Parses a response that should be JSON but may not quite be.
    ///
    /// Models wrap structured output in markdown fences often enough that tolerating it is cheaper
    /// than failing a dictation over punctuation. A model that ignored the schema entirely still
    /// produced usable text, so bare prose becomes the transcript.
    /// </summary>
    public static Transcript Parse(string raw)
    {
        var candidate = StripFence(raw).Trim();
        try
        {
            var node = JsonNode.Parse(candidate)?.AsObject();
            if (node is not null)
            {
                return new Transcript(
                    node["transcript"]?.GetValue<string>() ?? string.Empty,
                    node["language"]?.GetValue<string>() ?? string.Empty);
            }
        }
        catch (JsonException)
        {
            // Falls through to treating the text as the transcript.
        }
        return new Transcript(candidate);
    }

    private static string StripFence(string raw)
    {
        var text = raw.Trim();
        if (!text.StartsWith("```", StringComparison.Ordinal)) return text;

        var lines = text.Split('\n').Skip(1).ToList();
        if (lines.Count > 0 && lines[^1].Trim() == "```") lines.RemoveAt(lines.Count - 1);
        return string.Join("\n", lines);
    }
}

public sealed record TokenUsage(int? PromptTokens = null, int? CompletionTokens = null, int? AudioTokens = null)
{
    /// <summary>Totals the cost of a dictation that took more than one request.</summary>
    /// <remarks>
    /// Null means "not reported" and must not become zero: zero audio tokens is the specific signal
    /// that a provider dropped the audio, so inventing one would fire that alarm falsely.
    /// </remarks>
    public static TokenUsage Add(TokenUsage left, TokenUsage right) => new(
        Sum(left.PromptTokens, right.PromptTokens),
        Sum(left.CompletionTokens, right.CompletionTokens),
        Sum(left.AudioTokens, right.AudioTokens));

    private static int? Sum(int? left, int? right) =>
        left is null && right is null ? null : (left ?? 0) + (right ?? 0);
}

/// <param name="ChunkCount">
/// How many requests the audio was split across. 1 for every ordinary dictation.
/// </param>
public sealed record TranscriptionResult(
    Transcript Transcript, TokenUsage Usage, string RawOutput, int ChunkCount = 1);

public sealed class ProviderException(string message) : Exception(message)
{
    /// <summary>
    /// Errors worth retrying, as opposed to ones that fail identically forever. Retrying a 401
    /// just burns the user's time; a 503 or a dropped connection is what retry exists for.
    /// </summary>
    public bool IsTransient { get; init; } = true;

    /// <summary>The HTTP status, when this came from a response. Zero when it did not.</summary>
    /// <remarks>
    /// Carried as a number rather than left inside the message. The status used to exist only as
    /// text — `HTTP 401: {body}` — and callers that needed it asked whether the message
    /// <em>contained</em> "HTTP 401", which is a substring search over a body the provider wrote.
    /// A provider quoting a status in its own error text was enough to misclassify the failure.
    /// </remarks>
    public int Status { get; init; }

    /// <summary>The response body, for the sentence the provider put in it.</summary>
    public string Body { get; init; } = string.Empty;
}

/// <summary>
/// Google's Interactions API.
/// </summary>
public sealed class GeminiProvider(
    string apiKey,
    string model = "gemini-3.6-flash",
    string? thinkingLevel = null,
    HttpClient? httpClient = null) : ITranscriptionProvider
{
    private const string Endpoint = "https://generativelanguage.googleapis.com/v1beta/interactions";

    private static readonly HttpClient Shared = new() { Timeout = TimeSpan.FromSeconds(150) };

    /// <summary>
    /// The cheapest thinking level a given model accepts.
    ///
    /// <para>Not a constant, and finding that out cost a total outage on the newer model: 3.6
    /// accepts <c>minimal</c>, 3.7 rejects it with "'minimal' is not a supported thinking level
    /// for this model. Allowed values are: medium, low, high." Transcription wants as little
    /// thinking as allowed — thought tokens bill as output and buy nothing when the job is writing
    /// down what was said.</para>
    ///
    /// <para>A prefix match on the family rather than an allowlist of exact IDs, so a point release
    /// inherits its family's floor instead of costing thinking tokens on every dictation.</para>
    /// </summary>
    internal static string CheapestThinkingLevel(string model) =>
        model.StartsWith("gemini-3.7", StringComparison.Ordinal)
        || model.StartsWith("gemini-4", StringComparison.Ordinal)
            ? "low"
            : "minimal";
    private readonly HttpClient _http = httpClient ?? Shared;

    public string Name => "gemini";

    public string Model => model;

    /// <summary>The Files API is first-party, so the pre-upload path is available here.</summary>
    public bool SupportsPreUpload => true;

    public IAudioUploader CreateUploader() => new GeminiAudioUploader(apiKey, _http);

    /// <remarks>
    /// <paramref name="fidelity"/> and <paramref name="keyterms"/> are ignored, and that is not an
    /// oversight: fidelity already reached this backend inside <paramref name="systemInstruction"/>,
    /// and keyterms exist only for endpoints with no instruction to put them in.
    /// </remarks>
    public async Task<TranscriptionResult> TranscribeAsync(
        string systemInstruction,
        IReadOnlyList<InputPart> parts,
        int maxOutputTokens = 2048,
        CancellationToken cancellationToken = default,
        Fidelity fidelity = Fidelity.Light,
        IReadOnlyList<string>? keyterms = null)
    {
        var body = new JsonObject
        {
            ["model"] = model,
            // Server-side retention defaults on, and these requests carry screen contents.
            ["store"] = false,
            ["system_instruction"] = systemInstruction,
            ["input"] = new JsonArray(parts.Select(Encode).ToArray()),
            ["response_format"] = new JsonObject
            {
                ["type"] = "text",
                ["mime_type"] = "application/json",
                ["schema"] = Transcript.Schema(),
            },
            ["generation_config"] = new JsonObject
            {
                ["thinking_level"] = thinkingLevel ?? CheapestThinkingLevel(model),
                ["max_output_tokens"] = maxOutputTokens,
            },
        };

        using var request = new HttpRequestMessage(HttpMethod.Post, Endpoint);
        request.Headers.TryAddWithoutValidation("x-goog-api-key", apiKey);
        request.Content = new StringContent(body.ToJsonString(), Encoding.UTF8, "application/json");

        using var response = await _http.SendLoggedAsync(request, Name, Model, cancellationToken).ConfigureAwait(false);
        var text = await response.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false);

        if (!response.IsSuccessStatusCode)
        {
            var status = (int)response.StatusCode;
            throw new ProviderException($"HTTP {status}: {Truncate(text, 400)}")
            {
                IsTransient = status is 408 or 429 or >= 500,
                Status = status,
                Body = text,
            };
        }

        var root = JsonNode.Parse(text)?.AsObject()
            ?? throw new ProviderException("Response was not a JSON object.");

        var usage = ParseUsage(root["usage"]?.AsObject());
        AssertAudioWasProcessed(parts, usage);

        var output = ExtractText(root)
            ?? throw new ProviderException("Model returned no output.");
        return new TranscriptionResult(Transcript.Parse(output), usage, output);
    }

    /// <summary>
    /// A provider that accepts audio and bills zero audio tokens never gave it to the model, and
    /// the "transcript" it returns is invented rather than empty. Observed in the wild, so the
    /// check lives here rather than in a per-provider allowlist.
    /// </summary>
    private void AssertAudioWasProcessed(IReadOnlyList<InputPart> parts, TokenUsage usage)
    {
        var sentAudio = parts.Any(p => p is InputPart.Audio or InputPart.RemoteAudio);
        if (sentAudio && usage.AudioTokens == 0)
        {
            throw new ProviderException(
                $"The provider accepted the audio but billed 0 audio tokens for {model} — the "
                + "recording never reached the model, so any transcript it returned is fabricated.")
            {
                IsTransient = false,
            };
        }
    }

    private static JsonObject Encode(InputPart part) => part switch
    {
        InputPart.Text text => new JsonObject { ["type"] = "text", ["text"] = text.Value },
        InputPart.Image image => new JsonObject
        {
            ["type"] = "image",
            ["data"] = Convert.ToBase64String(image.Data),
            ["mime_type"] = image.MimeType,
        },
        InputPart.Audio audio => new JsonObject
        {
            ["type"] = "audio",
            ["data"] = Convert.ToBase64String(audio.Data),
            ["mime_type"] = audio.MimeType,
        },
        InputPart.RemoteAudio remote => new JsonObject
        {
            // `uri`, not `file_uri` — the latter is rejected as an unknown parameter.
            ["type"] = "audio",
            ["uri"] = remote.Uri,
            ["mime_type"] = remote.MimeType,
        },
        _ => throw new ArgumentOutOfRangeException(nameof(part)),
    };

    /// <summary>Walks steps[] → model_output → content[] → text. `output_text` is SDK-added.</summary>
    private static string? ExtractText(JsonObject root)
    {
        if (root["steps"] is not JsonArray steps) return null;

        var builder = new StringBuilder();
        foreach (var step in steps.OfType<JsonObject>())
        {
            if (step["type"]?.GetValue<string>() != "model_output") continue;
            if (step["content"] is not JsonArray content) continue;

            foreach (var block in content.OfType<JsonObject>())
            {
                if (block["type"]?.GetValue<string>() == "text")
                {
                    builder.Append(block["text"]?.GetValue<string>());
                }
            }
        }
        return builder.Length == 0 ? null : builder.ToString();
    }

    private static TokenUsage ParseUsage(JsonObject? usage)
    {
        if (usage is null) return new TokenUsage();

        int? audio = null;
        if (usage["input_tokens_by_modality"] is JsonArray modalities)
        {
            audio = 0;
            foreach (var entry in modalities.OfType<JsonObject>())
            {
                if (string.Equals(entry["modality"]?.GetValue<string>(), "audio", StringComparison.OrdinalIgnoreCase))
                {
                    audio = entry["tokens"]?.GetValue<int>() ?? 0;
                }
            }
        }

        return new TokenUsage(
            usage["total_input_tokens"]?.GetValue<int>(),
            usage["total_output_tokens"]?.GetValue<int>(),
            audio);
    }

    private static string Truncate(string value, int max) =>
        value.Length <= max ? value : value[..max];
}
