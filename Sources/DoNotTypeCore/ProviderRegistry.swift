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

    public var defaultModel: String {
        switch self {
        case .openrouter: "google/gemini-3.6-flash"
        case .gemini: "gemini-3.6-flash"
        }
    }

    public var apiKeyEnvVar: String {
        switch self {
        case .openrouter: "OPENROUTER_API_KEY"
        case .gemini: "GEMINI_API_KEY"
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
        let key = environment[kind.apiKeyEnvVar]?.trimmed ?? ""
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
            return GeminiProvider(apiKey: key)
        }
    }
}
