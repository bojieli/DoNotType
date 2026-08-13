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

    /// <summary>
    /// What this backend can do with what is on screen.
    ///
    /// Defaulted to <see cref="GroundingSupport.Multimodal"/>, which is simply the truth for the
    /// model providers, so they say nothing extra.
    /// </summary>
    GroundingSupport Grounding => GroundingSupport.Multimodal;

    Task<TranscriptionResult> TranscribeAsync(
        string systemInstruction,
        IReadOnlyList<InputPart> parts,
        int maxOutputTokens = 2048,
        CancellationToken cancellationToken = default,
        Fidelity fidelity = Fidelity.Light,
        IReadOnlyList<string>? keyterms = null);

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

/// <summary>
/// What a backend can do with what is on screen.
///
/// This exists because the two kinds of backend are not interchangeable and the difference is
/// invisible at the call site. A model provider reads PROMPT.md, the labelled screen text and the
/// screenshot. A speech recognition endpoint reads none of them — no system instruction, no eyes,
/// no conversation. Handing one a <see cref="ScreenContext"/> and carrying on would produce a
/// transcript that looks grounded, is recorded in history as grounded, and was produced by a model
/// that never saw the screen. That is the same class of failure as a silently dropped recording,
/// which this codebase already refuses to let pass quietly.
/// </summary>
public abstract record GroundingSupport
{
    private GroundingSupport() { }

    /// <summary>Reads everything: system instruction, labelled screen text, screenshot.</summary>
    public sealed record MultimodalGrounding : GroundingSupport;

    /// <summary>A recogniser that accepts a list of spellings to bias toward, and nothing else.</summary>
    public sealed record KeytermGrounding(int MaxTerms, int MaxCharsPerTerm) : GroundingSupport;

    /// <summary>A recogniser with no biasing channel at all.</summary>
    public sealed record NoGrounding : GroundingSupport;

    public static readonly GroundingSupport Multimodal = new MultimodalGrounding();
    public static readonly GroundingSupport None = new NoGrounding();
    public static GroundingSupport Keyterms(int maxTerms, int maxCharsPerTerm) =>
        new KeytermGrounding(maxTerms, maxCharsPerTerm);
}

/// <summary>Known backends and how to construct them.</summary>
public enum ProviderKind
{
    Gemini,
    OpenRouter,

    /// <summary>
    /// Speech recognition rather than a language model: fast and cheap, cannot see the screen,
    /// and cannot transcribe Mandarin under any autodetecting setting. See docs/EVALUATION.md.
    /// </summary>
    Deepgram,

    /// <summary>
    /// Mistral Voxtral. The recognition backend to pick if you switch languages mid-sentence —
    /// the only one here that transcribes Mandarin and English without being told which is coming.
    /// </summary>
    Mistral,

    /// <summary>
    /// xAI. Multilingual, and the only recogniser here whose language setting also controls number
    /// formatting: an explicit language buys "3.5" and costs code-switching.
    /// </summary>
    XAI,
}

public static class ProviderFactory
{
    /// <summary>
    /// What a fresh install uses. A recogniser rather than a model, measured on the 100-clip
    /// ordinary-dictation corpus: xAI is the fastest backend tested (0.98 s median against the
    /// model's 5.44 s) and the only recogniser that does not fall over on non-English speech —
    /// Deepgram failed 44 of 68 Chinese clips outright. See docs/EVALUATION.md.
    /// </summary>
    public const ProviderKind DefaultForNewInstalls = ProviderKind.XAI;

    public static string DefaultModel(this ProviderKind kind) => kind switch
    {
        ProviderKind.Gemini => "gemini-3.6-flash",
        // nova-3 is the only Deepgram model with keyterm biasing, its sole grounding channel.
        ProviderKind.Deepgram => "nova-3",
        ProviderKind.Mistral => "voxtral-mini-latest",
        ProviderKind.XAI => "grok-stt",
        _ => "google/gemini-3.6-flash",
    };

    public static string ApiKeyEnvVar(this ProviderKind kind) => kind switch
    {
        ProviderKind.Gemini => "GEMINI_API_KEY",
        ProviderKind.Deepgram => "DEEPGRAM_API_KEY",
        ProviderKind.Mistral => "MISTRAL_API_KEY",
        ProviderKind.XAI => "XAI_API_KEY",
        _ => "OPENROUTER_API_KEY",
    };

    /// <summary>
    /// Whether this backend is a language model at all. Drives the parts of the UI that would
    /// otherwise offer settings with no effect: grounding, the prompt, and the rewrite path.
    /// </summary>
    public static bool IsSpeechRecognition(this ProviderKind kind) =>
        kind is ProviderKind.Deepgram or ProviderKind.Mistral or ProviderKind.XAI;

    /// <summary>Name for the settings dropdown, honest about what each one gives up.</summary>
    public static string DisplayName(this ProviderKind kind) => kind switch
    {
        ProviderKind.Gemini => "Gemini",
        ProviderKind.OpenRouter => "OpenRouter",
        ProviderKind.Deepgram => "Deepgram (transcription only)",
        ProviderKind.Mistral => "Mistral Voxtral (transcription only)",
        ProviderKind.XAI => "xAI (transcription only)",
        _ => kind.ToString(),
    };

    public static ITranscriptionProvider Create(ProviderKind kind, string apiKey, string? model = null) =>
        kind switch
        {
            ProviderKind.Gemini => new GeminiProvider(apiKey, model ?? kind.DefaultModel()),
            ProviderKind.Deepgram => new DeepgramProvider(apiKey, model ?? kind.DefaultModel()),
            ProviderKind.Mistral => new MistralProvider(apiKey, model ?? kind.DefaultModel()),
            ProviderKind.XAI => new XAISpeechProvider(apiKey, model ?? kind.DefaultModel()),
            _ => new OpenAiCompatibleProvider(
                "openrouter",
                "https://openrouter.ai/api/v1/chat/completions",
                apiKey,
                model ?? kind.DefaultModel()),
        };
}
