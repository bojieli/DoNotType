import Foundation

/// Known backends, and how to build one from the environment.
///
/// Providers are not interchangeable for this app. Transcription needs audio input, and a gateway
/// that merely *accepts* an audio block without forwarding it is worse than one that rejects it —
/// see `TranscriptionProvider.assertAudioWasProcessed`. Verify any new backend with
/// `dnt-eval probe --audio` before adding it here.
public enum ProviderKind: String, CaseIterable, Sendable {
    /// The default. First-party Interactions API: no gateway between the audio and the model, and
    /// `store: false` is honoured directly, which matters for requests carrying screen contents.
    ///
    /// Also measurably better on the near-miss suite than the same model ID through a gateway —
    /// 15/15 versus 12/15 on 2026-08-09, with the gateway regressing the spelling-correction case.
    case gemini
    /// Verified to forward audio. Useful as a second opinion and for models Google does not serve.
    case openrouter
    /// Any OpenAI-compatible server you run yourself — vLLM, SGLang, llama.cpp.
    ///
    /// This is the interesting one for open-weight models: `vllm serve` exposes exactly the
    /// `/v1/chat/completions` shape `OpenAICompatibleProvider` already speaks, so pointing this at
    /// `http://your-gpu-box:8000/v1/chat/completions` needs no new client code. It also removes
    /// the API key, the network dependency and the privacy question in one move.
    case local

    public var defaultModel: String {
        switch self {
        case .openrouter: "google/gemini-3.6-flash"
        case .gemini: "gemini-3.6-flash"
        // Whatever the server was started with; overridden by --model in practice.
        case .local: ProcessInfo.processInfo.environment["DNT_LOCAL_MODEL"] ?? "local-model"
        }
    }

    public var apiKeyEnvVar: String {
        switch self {
        case .openrouter: "OPENROUTER_API_KEY"
        case .gemini: "GEMINI_API_KEY"
        // Most local servers ignore the key entirely; the factory supplies a placeholder so an
        // unauthenticated server does not require inventing one.
        case .local: "DNT_LOCAL_API_KEY"
        }
    }
}

public enum ProviderFactory {
    /// Builds a provider, reading the key from the environment.
    ///
    /// - Parameters:
    ///   - appURL: OpenRouter attribution header; ignored elsewhere.
    ///   - appTitle: OpenRouter attribution header; ignored elsewhere.
    public static func make(
        _ kind: ProviderKind,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        appURL: String = "https://github.com/donottype/donottype",
        appTitle: String = "DoNotType"
    ) throws -> any TranscriptionProvider {
        var key = environment[kind.apiKeyEnvVar]?.trimmed ?? ""
        // A self-hosted server usually has no auth at all, so an absent key is normal there
        // rather than a misconfiguration.
        if kind == .local, key.isEmpty { key = "not-required" }
        guard !key.isEmpty else {
            throw ProviderError.missingAPIKey(envVar: kind.apiKeyEnvVar)
        }

        switch kind {
        case .openrouter:
            return OpenAICompatibleProvider(
                name: "openrouter",
                baseURL: URL(string: "https://openrouter.ai/api/v1/chat/completions")!,
                apiKey: key,
                extraHeaders: ["HTTP-Referer": appURL, "X-Title": appTitle]
            )
        case .gemini:
            // DNT_NO_SCHEMA exists so `dnt-eval` can measure what the structured-output
            // constraint costs in latency. Not a supported configuration: unconstrained output
            // sometimes arrives wrapped in prose, and a dictation tool that occasionally types
            // "Here is the transcript:" is broken.
            return GeminiProvider(
                apiKey: key,
                usesStructuredOutput: environment["DNT_NO_SCHEMA"] == nil)

        case .local:
            let base = environment["DNT_LOCAL_BASE_URL"]
                ?? "http://localhost:8000/v1/chat/completions"
            guard let url = URL(string: base) else {
                throw ProviderError.malformedResponse(
                    "DNT_LOCAL_BASE_URL is not a valid URL: \(base)")
            }
            return OpenAICompatibleProvider(
                name: "local",
                baseURL: url,
                apiKey: key,
                // Open models generally reject an unknown `reasoning` field outright.
                reasoningEffort: nil)
        }
    }
}
