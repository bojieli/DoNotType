import Foundation

/// Known backends, and how to build one from the environment.
///
/// Providers are not interchangeable for this app. Transcription needs audio input, and a gateway
/// that merely *accepts* an audio block without forwarding it is worse than one that rejects it —
/// see `TranscriptionProvider.assertAudioWasProcessed`. Verify any new backend with
/// `dnt-eval probe --audio` before adding it here.
///
/// They are not interchangeable in a second way since `.deepgram` and `.xai` joined: two of these
/// are not language models. What that costs is declared by `GroundingSupport` and routed on by
/// `TranscriptionService`, so the difference is visible in the type system rather than discovered
/// from a transcript that reads as though the screen was never there — because it was not.
///
/// `.xai` was for a time the one entry that did not meet the verification rule above, because
/// every key available when it was added was rejected. It has since been verified, and the rule
/// was vindicated: the first live request found two undocumented behaviours that made the default
/// configuration fail outright. See `XAISpeechProvider`.
public enum ProviderKind: String, CaseIterable, Sendable {
    /// The default. First-party Interactions API: no gateway between the audio and the model, and
    /// `store: false` is honoured directly, which matters for requests carrying screen contents.
    ///
    /// Also measurably better on the near-miss suite than the same model ID through a gateway —
    /// 15/15 versus 12/15 on 2026-08-09, with the gateway regressing the spelling-correction case.
    case gemini
    /// Any model through OpenRouter. Verified to forward audio, and useful for a second opinion
    /// or for models Google does not serve directly.
    ///
    /// **Prefer `.gemini` for a Gemini model.** The same model ID measures worse through this
    /// gateway than through the first-party API, consistently and on two separate occasions:
    /// 12/15 against 15/15 on 2026-08-09, and on the near-miss suite on 2026-08-13, 38–43/48 with
    /// 2–5 regressions against native's 44/48 with 1. Regressions are the number this project
    /// exists to report, so a gateway that multiplies them is the wrong default even when its
    /// matched count is close.
    case openrouter
    /// Any OpenAI-compatible server you run yourself — vLLM, SGLang, llama.cpp.
    ///
    /// This is the interesting one for open-weight models: `vllm serve` exposes exactly the
    /// `/v1/chat/completions` shape `OpenAICompatibleProvider` already speaks, so pointing this at
    /// `http://your-gpu-box:8000/v1/chat/completions` needs no new client code. It also removes
    /// the API key, the network dependency and the privacy question in one move.
    case local
    /// Speech recognition rather than a language model. Fast and cheap; cannot see the screen.
    ///
    /// Worth having despite giving up grounding, because grounding is the part of this project
    /// that does not yet work — see the substitution numbers in `docs/EVALUATION.md`. A backend
    /// that transcribes and nothing else is the honest floor those numbers are measured against,
    /// and for a user who dictates prose rather than identifiers it may simply be the better
    /// choice.
    case deepgram
    /// xAI's speech-to-text endpoint. Multilingual like Voxtral, and the only recogniser here
    /// whose formatting and language settings interact — see `XAISpeechProvider`.
    case xai
    /// Mistral Voxtral. The recognition backend to pick if you switch languages mid-sentence:
    /// it is the only one here that transcribes Mandarin and English without being told which is
    /// coming. No screen grounding of any kind. See `MistralProvider`.
    case mistral

    /// What a fresh install uses, and the one setting in this file that is a product decision
    /// rather than a fact about an API.
    ///
    /// A recogniser rather than a model, measured on the 100-clip ordinary-dictation corpus —
    /// real speech with nothing on screen contradicting it, which is the distribution a default
    /// actually serves. The adversarial near-miss suite says a model is more accurate; it says
    /// nothing about the dictation people mostly do.
    ///
    /// | backend | median latency | ×realtime | failed |
    /// |---|---|---|---|
    /// | xai | **0.98 s** | 0.053× | **1 / 100** |
    /// | deepgram | 1.23 s | 0.066× | 48 / 100 |
    /// | mistral | 1.29 s | 0.069× | 3 / 100 |
    /// | openrouter (model) | 5.44 s | 0.282× | 0 / 100 |
    ///
    /// `.xai` wins on the two things a default has to get right: it is the fastest, and it is the
    /// only recogniser that does not fall over on the corpus's actual language. Deepgram failed
    /// 44 of 68 Chinese clips outright — it is disqualified as a default for anyone who is not
    /// exclusively English-speaking, whatever it scores when it works.
    ///
    /// The model is not gone, it is demoted: it is 5.5× slower for a benefit that measured
    /// **+4 improved against 3 regressed** on the near-miss suite, which is close to nothing for
    /// a lot of waiting. Choose it in Settings when dictating identifiers with the reference on
    /// screen, which is the case where grounding genuinely pays.
    ///
    /// Deepgram is deliberately not the fallback here despite being the second recogniser added:
    /// it returned nothing for 44 of 68 Mandarin clips on that corpus, which disqualifies it as a
    /// default for anyone who is not exclusively English-speaking.
    public static let defaultForNewInstalls: ProviderKind = .xai

    public var defaultModel: String {
        switch self {
        case .openrouter: "google/gemini-3.6-flash"
        case .gemini: "gemini-3.6-flash"
        // Whatever the server was started with; overridden by --model in practice.
        case .local: ProcessInfo.processInfo.environment["DNT_LOCAL_MODEL"] ?? "local-model"
        // nova-3 is the only Deepgram model with keyterm biasing, which is this backend's sole
        // grounding channel. Defaulting to anything older would silently disable it.
        case .deepgram: "nova-3"
        // The endpoint serves one model and takes no model parameter; the string exists so the
        // settings field and history rows have something truthful to show.
        case .xai: "grok-stt"
        // `-latest` rather than a pinned date, because this is the alias Mistral documents and a
        // pin here would silently rot. `voxtral-small-latest` is also accepted.
        case .mistral: "voxtral-mini-latest"
        }
    }

    /// The model this backend runs the second stage on — rewriting and summarising — when that
    /// is not the model that transcribes.
    ///
    /// `nil` means two different things, told apart by `isSpeechRecognition`: for a language model
    /// the transcription model does both jobs and a second entry would only be a way for them to
    /// disagree; for a recogniser there is no text stage at all.
    ///
    /// xAI is why this exists. `/v1/stt` takes audio and nothing else, but the same key reaches
    /// Grok chat models on `/v1/chat/completions` — the limitation is the endpoint, not the
    /// account, and a key that can rewrite should be allowed to.
    public var defaultTextModel: String? {
        guard self == .xai else { return nil }
        return ProcessInfo.processInfo.environment["DNT_XAI_TEXT_MODEL"]?.trimmed.nilIfEmpty
            ?? "grok-4-fast-non-reasoning"
    }

    public var apiKeyEnvVar: String {
        switch self {
        case .openrouter: "OPENROUTER_API_KEY"
        case .gemini: "GEMINI_API_KEY"
        // Most local servers ignore the key entirely; the factory supplies a placeholder so an
        // unauthenticated server does not require inventing one.
        case .local: "DNT_LOCAL_API_KEY"
        case .deepgram: "DEEPGRAM_API_KEY"
        // xAI's own name for it. `GROK_API_KEY` is accepted as a fallback by the factory, since
        // that is what this provider was first written against.
        case .xai: "XAI_API_KEY"
        case .mistral: "MISTRAL_API_KEY"
        }
    }

    /// Other names the same key is commonly stored under, tried in order after `apiKeyEnvVar`.
    var alternateAPIKeyEnvVars: [String] {
        switch self {
        case .xai: ["GROK_API_KEY"]
        default: []
        }
    }

    /// Every environment variable consulted for this backend's key, in the order they are tried.
    ///
    /// Public because the app resolves the key itself before it ever reaches `ProviderFactory` —
    /// and when the two lists disagreed, a shell holding only `GROK_API_KEY` was reported as
    /// having no key at all, by a factory that would have accepted it. One list, one answer.
    public var apiKeyEnvVars: [String] { [apiKeyEnvVar] + alternateAPIKeyEnvVars }

    /// Whether this backend is a language model at all.
    ///
    /// Drives the parts of the UI that would otherwise offer settings with no effect: screen
    /// grounding, the prompt editor, and the rewrite hotkey all require a model.
    public var isSpeechRecognition: Bool {
        switch self {
        case .deepgram, .xai, .mistral: true
        case .gemini, .openrouter, .local: false
        }
    }

    /// Whether this backend can turn text into text — the rewrite and summary pass.
    ///
    /// Deliberately not the negation of `isSpeechRecognition`. The two were the same question
    /// until xAI arrived: it is a recogniser that also sells chat, so "cannot read your screen"
    /// and "cannot rewrite what you said" now have different answers, and a UI that asks the
    /// first when it means the second takes away a hotkey the key pays for.
    public var supportsTextGeneration: Bool { !isSpeechRecognition || defaultTextModel != nil }
}

public enum ProviderFactory {
    /// Builds a provider with a key from somewhere other than the environment — the Keychain, a
    /// settings field, a flag.
    ///
    /// This exists because every caller that had a key already was writing
    /// `make(kind, environment: [kind.apiKeyEnvVar: key])`, and that dictionary *replaces* the
    /// environment rather than adding to it. Everything else this factory reads from there was
    /// therefore silently unreachable from the app: `DNT_LOCAL_BASE_URL` (so a self-hosted server
    /// was always assumed to be on `localhost:8000`) and `DNT_DEEPGRAM_LANGUAGE`, which the
    /// settings panel tells Chinese-speaking users to set — advice that could not work. The
    /// process environment is merged in, with the supplied key taking precedence over any copy of
    /// itself found there.
    public static func make(
        _ kind: ProviderKind,
        apiKey: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> any TranscriptionProvider {
        var merged = environment
        // Every spelling is cleared first, so a stale key under an alternate name cannot win a
        // lookup that the canonical one would have satisfied.
        for name in kind.apiKeyEnvVars { merged[name] = nil }
        merged[kind.apiKeyEnvVar] = apiKey
        return try make(kind, environment: merged)
    }

    /// A backend for the second stage — rewriting, summarising — or nil when there is none.
    ///
    /// For a language model this is the same backend that transcribes, so the answer is the
    /// ordinary provider. For xAI it is a different endpoint reached with the same key:
    /// `/v1/chat/completions` and a Grok chat model, rather than `/v1/stt` and `grok-stt`.
    /// Deepgram and Mistral sell recognition alone and return nil, which is what stops the UI
    /// offering a rewrite that could only fail.
    public static func makeTextProvider(
        _ kind: ProviderKind,
        apiKey: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> (any TranscriptionProvider)? {
        guard kind.supportsTextGeneration else { return nil }
        guard kind.isSpeechRecognition else {
            return try make(kind, apiKey: apiKey, environment: environment)
        }
        switch kind {
        case .xai:
            return OpenAICompatibleProvider(
                name: kind.rawValue,
                baseURL: URL(string: "https://api.x.ai/v1/chat/completions")!,
                apiKey: apiKey,
                // Grok's non-reasoning models reject an unknown `reasoning` field outright, and
                // restyling a sentence has nothing to reason about anyway.
                reasoningEffort: nil)
        default:
            return nil
        }
    }

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
        // Every spelling is tried before giving up, so a shell that already has the key under a
        // different name does not look like a missing key.
        var key = ""
        for name in kind.apiKeyEnvVars where key.isEmpty {
            key = environment[name]?.trimmed ?? ""
        }
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

        case .deepgram:
            // Absent means detect per request, which is what a code-switching user wants and what
            // the near-miss suite's Mandarin and mixed cases need.
            return DeepgramProvider(
                apiKey: key, language: environment["DNT_DEEPGRAM_LANGUAGE"]?.trimmed.nilIfEmpty)

        case .xai:
            return XAISpeechProvider(
                apiKey: key, language: environment["DNT_XAI_LANGUAGE"]?.trimmed.nilIfEmpty)

        case .mistral:
            // Absent by design: Voxtral's own detection is what makes the code-switching case
            // work, so pinning a language here would remove the reason to choose it.
            return MistralProvider(
                apiKey: key, language: environment["DNT_MISTRAL_LANGUAGE"]?.trimmed.nilIfEmpty)
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
