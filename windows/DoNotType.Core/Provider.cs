namespace DoNotType.Core;

/// <summary>
/// A backend that can turn audio plus context into a transcript.
///
/// Everything above this line is provider-agnostic: the prompt, the context format, the history,
/// the retry policy. Gemini is one implementation, and the interface exists so a second one is a
/// new file rather than a rewrite.
///
/// Two members are not obviously part of "call a model", and both are here because leaving them
/// out would make the abstraction lie:
///
/// <list type="bullet">
/// <item><see cref="SupportsPreUpload"/> — the Files API is Google-specific. A gateway with no
/// equivalent must not be handed a URI it cannot resolve.</item>
/// <item><see cref="TokenUsage.AudioTokens"/> in the result — the guard against a provider that
/// accepts audio and silently discards it needs a number, and only the provider can report it.
/// </item>
/// </list>
/// </summary>
public interface ITranscriptionProvider
{
    /// <summary>Short identifier, used in history rows and error messages.</summary>
    string Name { get; }

    /// <summary>Model identifier this provider was configured with.</summary>
    string Model { get; }

    /// <summary>
    /// Whether audio can be uploaded ahead of the request and referenced by URI.
    /// Providers without an equivalent get inline bytes and never see a
    /// <see cref="InputPart.RemoteAudio"/>.
    /// </summary>
    bool SupportsPreUpload { get; }

    Task<TranscriptionResult> TranscribeAsync(
        string systemInstruction,
        IReadOnlyList<InputPart> parts,
        int maxOutputTokens = 2048,
        CancellationToken cancellationToken = default);

    /// <summary>
    /// Creates an uploader for the pre-upload path, or null when the provider has none.
    /// </summary>
    IAudioUploader? CreateUploader() => null;
}

/// <summary>
/// Gets a recording to a provider ahead of the request that references it.
/// </summary>
public interface IAudioUploader
{
    /// <summary>Begins any handshake, without waiting. Called at hotkey-down.</summary>
    void Prepare(int estimatedBytes, string mimeType = "audio/wav");

    void Cancel();

    /// <summary>
    /// Returns the part to send. Implementations degrade to inline rather than failing, so a
    /// flaky network costs latency and never words.
    /// </summary>
    Task<InputPart> PlanAsync(byte[] audio, string mimeType = "audio/wav");
}

/// <summary>Known backends and how to construct them.</summary>
public enum ProviderKind
{
    Gemini,
    OpenRouter,
}

public static class ProviderFactory
{
    public static string DefaultModel(this ProviderKind kind) => kind switch
    {
        ProviderKind.Gemini => "gemini-3.6-flash",
        _ => "google/gemini-3.6-flash",
    };

    public static string ApiKeyEnvVar(this ProviderKind kind) => kind switch
    {
        ProviderKind.Gemini => "GEMINI_API_KEY",
        _ => "OPENROUTER_API_KEY",
    };

    public static ITranscriptionProvider Create(ProviderKind kind, string apiKey, string? model = null) =>
        kind switch
        {
            ProviderKind.Gemini => new GeminiProvider(apiKey, model ?? kind.DefaultModel()),
            _ => new OpenAiCompatibleProvider(
                "openrouter",
                "https://openrouter.ai/api/v1/chat/completions",
                apiKey,
                model ?? kind.DefaultModel()),
        };
}
