namespace DoNotType.Core;

/// <summary>
/// A backend that can turn audio plus context into a transcript.
///
/// Everything above this line is provider-agnostic: the prompt, the context format, the history,
/// the retry policy. Gemini is one implementation, and the interface exists so a second one is a
/// new file rather than a rewrite.
///
/// One member is not obviously part of "call a model", and it is here because leaving it out
/// would make the abstraction lie: <see cref="TokenUsage.AudioTokens"/> in the result. The guard
/// against a provider that accepts audio and silently discards it needs a number, and only the
/// provider can report it.
/// </summary>
public interface ITranscriptionProvider
{
    /// <summary>Short identifier, used in history rows and error messages.</summary>
    string Name { get; }

    /// <summary>Model identifier this provider was configured with.</summary>
    string Model { get; }

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
    /// <summary>
    /// What a fresh install uses. A model, because a recogniser cannot see the screen and screen
    /// grounding is the entire point of this project: on the near-miss suite Gemini grounded
    /// scores 43/48 against xAI's 15/48. It is bought with latency — a recogniser is 0.98 s median
    /// on the ordinary-dictation corpus against several seconds for a model — and the exact
    /// first-party figure is unmeasured, so it is not quoted here. See docs/EVALUATION.md.
    /// </summary>
    public const ProviderKind DefaultForNewInstalls = ProviderKind.Gemini;

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
        ProviderKind.OpenRouter => "OpenRouter (gateway — prefer Gemini for Gemini models)",
        ProviderKind.Deepgram => "Deepgram (transcription only)",
        ProviderKind.Mistral => "Mistral Voxtral (transcription only)",
        ProviderKind.XAI => "xAI (transcription only)",
        _ => kind.ToString(),
    };

    /// <summary>
    /// The two backends recommended to someone who has not read docs/EVALUATION.md, in the order
    /// every picker lists them.
    ///
    /// Narrowed from five to two deliberately: the rest each answer a question these two cannot,
    /// and none of them is a better answer to the question a new user is actually asking. A
    /// recommendation is only possible because these two are the two ends of one axis — Gemini
    /// reads the screen and xAI cannot — so the choice is one question rather than five.
    /// </summary>
    public static readonly IReadOnlyList<ProviderKind> Recommended =
        [ProviderKind.Gemini, ProviderKind.XAI];

    public static bool IsRecommended(this ProviderKind kind) => Recommended.Contains(kind);

    /// <summary>
    /// Every backend with the recommended ones first: the order every picker in this app uses.
    /// Order is the recommendation that survives a dropdown too short to show five rows.
    /// </summary>
    public static readonly IReadOnlyList<ProviderKind> PickerOrder =
        [.. Recommended, .. Enum.GetValues<ProviderKind>().Where(k => !Recommended.Contains(k))];

    /// <summary>
    /// The row label in a settings picker — never in history, a log line or an error, which say
    /// what ran rather than what we advise.
    /// </summary>
    public static string PickerLabel(this ProviderKind kind) =>
        kind.IsRecommended() ? $"{kind.DisplayName()} — recommended" : kind.DisplayName();

    /// <summary>
    /// One line under the picker: what this backend is recommended for, and the measurement behind
    /// the claim. Empty for the rest — a picker that recommends everything recommends nothing.
    ///
    /// Word for word the same as the Swift and Kotlin copies, which is checked by the tests in
    /// each language rather than by anything that can see all three at once.
    /// </summary>
    public static string RecommendationNote(this ProviderKind kind) => kind switch
    {
        ProviderKind.Gemini =>
            "Recommended for accuracy. It reads the screen, so it spells the names and versions "
            + "already in front of you: 44 of 48 on the near-miss suite against xAI's 15. You pay "
            + "in latency, and unevenly — one three-second clip took 5 s and the next 61 s.",
        ProviderKind.XAI =>
            "Recommended for speed. About 1 s for a short clip, 2.8 s for two minutes of speech, "
            + "and no tail. It cannot see the screen, so an unfamiliar name or a version number "
            + "is transcribed by ear alone: 15 of 48 on the same suite, 25 with keyterm biasing "
            + "turned on.",
        _ => string.Empty,
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
