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
    ///
    /// Named for the provider rather than the model it serves: Gemini is what runs here, Google
    /// is who runs it, and the same model is reachable through `.openrouter` as well.
    case google
    /// Any model through OpenRouter. Verified to forward audio, and useful for a second opinion
    /// or for models Google does not serve directly.
    ///
    /// **Prefer `.google` for a Gemini model.** The same model ID measures worse through this
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
    /// A model, because a recogniser cannot see the screen and screen grounding is the entire
    /// point of this project. On the adversarial near-miss suite — the thing this repository
    /// exists to measure — the two shipping configurations are not close:
    ///
    /// | configuration | near-miss | regressed |
    /// |---|---|---|
    /// | **google · gemini-3.5-flash · grounded** | not yet golden-scored | — |
    /// | xai · grok-stt | 15 / 48 | 0 |
    ///
    /// The older golden near-miss campaign still favours 3.6 (43–44 / 48 versus 31–35 / 48 for
    /// 3.5). The default moved after a newer seven-clip sweep of the maintainer's actual technical
    /// dictation: 3.5 retained names and commands more consistently and returned in 2.54 s median,
    /// while 3.6 took 10.54 s and was not consistently better. Those clips do not have human
    /// references yet, so this is a product recommendation for the current jargon-heavy workload,
    /// not a claim that the historical accuracy result reversed.
    ///
    /// This is bought with latency, and the price is real. On the 100-clip ordinary-dictation
    /// corpus — real speech, nothing on screen contradicting it — a recogniser is several times
    /// faster:
    ///
    /// | backend | median latency | ×realtime | failed |
    /// |---|---|---|---|
    /// | xai | 0.98 s | 0.053× | 1 / 100 |
    /// | deepgram | 1.23 s | 0.066× | 48 / 100 |
    /// | mistral | 1.29 s | 0.069× | 3 / 100 |
    /// | openrouter (model) | 5.44 s | 0.282× | 0 / 100 |
    ///
    /// Note what that table does *not* contain: a first-party `.google` row. The 5.44 s is the
    /// same model class through a gateway, and the near-miss suite says first-party beats the
    /// gateway on accuracy (15/15 against 12/15), but nobody has timed `.google` on the ordinary
    /// corpus. Quoting the gateway's number as this default's cost would be inventing a
    /// measurement; the honest statement is that it is several seconds rather than one, and that
    /// the exact figure is unmeasured.
    ///
    /// The trade was made deliberately: a default that is fast at the thing the README says this
    /// tool does not do — leaving the caret unspelled — serves nobody, and a fresh install that
    /// ships with grounding structurally inert misrepresents the product on first run. A user who
    /// wants the speed back picks `.xai` in Settings; it is one dropdown, and it keeps its own key
    /// and model.
    ///
    /// Deepgram is deliberately neither the default nor the fallback despite being the second
    /// recogniser added: it returned nothing for 44 of 68 Mandarin clips on that corpus, which
    /// disqualifies it for anyone who is not exclusively English-speaking, whatever it scores
    /// when it works.
    public static let defaultForNewInstalls: ProviderKind = .google

    /// Reads a name written before the providers were named after themselves rather than after
    /// their models.
    ///
    /// `gemini` meant Google. Falling back to `init?(rawValue:)` alone would quietly reset a
    /// configured install to the default backend, so stored settings, `--provider` arguments, the
    /// fallback picker and the Keychain account all resolve through here.
    public init?(persistedValue: String) {
        switch persistedValue.trimmed.lowercased() {
        case "gemini": self = .google
        case let value:
            guard let kind = ProviderKind(rawValue: value) else { return nil }
            self = kind
        }
    }

    /// The name this backend was stored under before the rename — a defaults key, a Keychain
    /// account — or nil for one that has always had the name it has now.
    public var legacyPersistedValue: String? {
        self == .google ? "gemini" : nil
    }

    /// The provider's name, never a model's.
    ///
    /// "Gemini" is what `.google` runs, not who serves it, and putting it here is what made
    /// "Gemini through OpenRouter" impossible to say in a window that can do exactly that.
    public var displayName: String {
        switch self {
        case .google: "Google"
        case .openrouter: "OpenRouter"
        case .local: "Local server"
        case .deepgram: "Deepgram"
        case .xai: "xAI"
        case .mistral: "Mistral"
        }
    }

    /// How a configuration reads out loud: what runs the request, then who serves it.
    ///
    /// Neither half answers on its own. OpenRouter serves hundreds of models, and the same model
    /// ID measures differently depending on the route it took — which is the whole reason both
    /// are settings.
    public func label(forModel model: String) -> String {
        let name = model.trimmed.nilIfEmpty ?? defaultModel
        return "\(name) via \(displayName)"
    }

    public var defaultModel: String {
        switch self {
        case .openrouter: "google/gemini-3.5-flash"
        case .google: "gemini-3.5-flash"
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

    /// The URL this backend posts to when nobody has said otherwise.
    ///
    /// Public so the settings panel can show it as the placeholder in the field that overrides it.
    /// An empty override means "use this", and a user who wants to know what they are overriding
    /// should not have to read the source to find out.
    public var defaultEndpoint: String {
        switch self {
        case .google: "https://generativelanguage.googleapis.com/v1beta/interactions"
        case .openrouter: "https://openrouter.ai/api/v1/chat/completions"
        case .local:
            ProcessInfo.processInfo.environment["DNT_LOCAL_BASE_URL"]
                ?? "http://localhost:8000/v1/chat/completions"
        case .deepgram: "https://api.deepgram.com/v1/listen"
        case .xai: "https://api.x.ai/v1/stt"
        case .mistral: "https://api.mistral.ai/v1/audio/transcriptions"
        }
    }

    /// The caveat that belongs under the endpoint field once it points at a server nobody here has
    /// measured.
    ///
    /// Dictation is the one use of these APIs that needs the audio modality, and it is the one a
    /// compatible third party is least likely to have. "OpenAI-compatible" is a claim about the
    /// request shape, not about what the model behind it accepts: relays, aggregators and a
    /// `vllm serve` pointed at a text-only checkpoint all speak `/v1/chat/completions` fluently
    /// and have nowhere to put an `input_audio` block. Some answer that with an error, which is
    /// the good case. Others accept it, drop it, and answer HTTP 200 with a fluent invention —
    /// see the incident in `TranscriptionProvider.assertAudioWasProcessed`.
    ///
    /// Stated here rather than left to the connection test to catch, because that test can only
    /// prove the negative it is shown: `assertAudioWasProcessed` calls a *reported* zero a dropped
    /// recording, and a third party that reports no usage at all is given the benefit of the
    /// doubt. That is the residual gap the wording below points at, and the endpoint field is the
    /// last moment where reading the service's own documentation is cheap.
    ///
    /// - Parameter endpointOverride: the contents of the endpoint field; empty when unset.
    /// - Returns: `nil` when there is nothing to warn about — see the guards below.
    public func thirdPartyAudioNote(endpointOverride: String) -> String? {
        // A recognition endpoint takes audio and nothing else, so a mirror of one that could not
        // carry a recording would not be a mirror of it. The whole API is the audio.
        guard !isSpeechRecognition else { return nil }
        // `.local` is a third-party server whether or not the field is filled in: the default is
        // only a default port on the user's own machine, and a text-only checkpoint served there
        // is the most likely way anyone reaches this note.
        guard self == .local || !endpointOverride.trimmed.isEmpty else { return nil }
        return """
            Dictation sends the recording itself to this URL, so the service has to accept audio \
            input — plenty that speak this API serve text and images only. The connection test \
            below sends a real recording, and catches an endpoint that refuses one or accepts it \
            and quietly discards it — but only while the service reports its token usage. If it \
            reports none, confirm from its own documentation that the model above takes audio.
            """
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
        case .google: "GEMINI_API_KEY"
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
        case .google, .openrouter, .local: false
        }
    }

    /// Whether this backend can turn text into text — the rewrite and summary pass.
    ///
    /// Deliberately not the negation of `isSpeechRecognition`. The two were the same question
    /// until xAI arrived: it is a recogniser that also sells chat, so "cannot read your screen"
    /// and "cannot rewrite what you said" now have different answers, and a UI that asks the
    /// first when it means the second takes away a hotkey the key pays for.
    public var supportsTextGeneration: Bool { !isSpeechRecognition || defaultTextModel != nil }

    /// The two backends recommended to someone who has not read `docs/EVALUATION.md`, in the order
    /// every picker lists them.
    ///
    /// Narrowed from six to two deliberately. The other four each answer a question these two
    /// cannot — a model Google does not serve, a server you run yourself, English keyterm biasing,
    /// a transcript with no vendor at all — and none of them is a better answer to the question a
    /// new user is actually asking. Six equally weighted entries made the picker a research
    /// project, and the research is already written down.
    ///
    /// A recommendation is only possible because these two differ on **one** axis and are the
    /// extremes of it: `.google` reads the screen and `.xai` does not. Every number in
    /// `recommendationNote` follows from that single difference, which is why the choice can be
    /// put to a user as one question — accuracy or latency — rather than as six.
    public static let recommended: [ProviderKind] = [.google, .xai]

    public var isRecommended: Bool { Self.recommended.contains(self) }

    /// Every backend with the recommended ones first: the order all four clients' pickers use.
    ///
    /// Order is the recommendation that survives translation, a fixed-height dropdown and a
    /// Spinner that shows three rows at a time. The label and the note below it can be missed;
    /// being first cannot.
    public static var pickerOrder: [ProviderKind] {
        recommended + allCases.filter { !$0.isRecommended }
    }

    /// The row label in a settings picker — never in history, a log line or an error, which say
    /// what ran rather than what we advise.
    public var pickerLabel: String {
        isRecommended ? "\(displayName) — recommended" : displayName
    }

    /// One line under the picker: what this backend is recommended *for*, and the measurement
    /// behind the claim.
    ///
    /// Nil for the other four. A picker that recommends everything recommends nothing, and the
    /// trade-off notes those four already carry say what they give up — which is a different
    /// sentence from what they are best at.
    public var recommendationNote: String? {
        switch self {
        case .google:
            "Recommended for technical dictation. On seven recent jargon-heavy recordings, "
                + "Gemini 3.5 retained names and commands more consistently than 3.6; no human "
                + "goldens exist for those clips yet. It reads the screen for spelling context. "
                + "The older near-miss goldens still favour 3.6."
        case .xai:
            "Recommended for speed. About 1 s for a short clip, 2.8 s for two minutes of speech, "
                + "and no tail. It cannot see the screen, so an unfamiliar name or a version "
                + "number is transcribed by ear alone: 15 of 48 on the same suite, 25 with "
                + "keyterm biasing turned on."
        default: nil
        }
    }

    /// The same recommendation for a client that has no screen grounding to offer — iOS, where
    /// the sandbox forbids reading another app's screen at all. See `docs/PARITY.md`.
    ///
    /// It lives here, next to the note it replaces, because the two must be argued from the same
    /// measurements and the failure mode of putting it in the iOS target is that only one of them
    /// gets updated when a number moves. The claim genuinely differs: `.google`'s advantage on the
    /// other three clients is stated as reading the screen, which on iOS would be a promise the
    /// platform cannot keep. What survives is that the model is better at unfamiliar words with no
    /// screen at all — 41 to 42 of 48 ungrounded — which is the honest reason to pay for it here.
    public var ungroundedRecommendationNote: String? {
        switch self {
        case .google:
            "Recommended for technical dictation. On seven recent jargon-heavy recordings, "
                + "Gemini 3.5 retained names and commands more consistently than 3.6; no human "
                + "goldens exist for those clips yet. On iOS it works from the audio alone. The "
                + "older near-miss goldens still favour 3.6."
        case .xai:
            "Recommended for speed. About 1 s for a short clip, 2.8 s for two minutes of speech, "
                + "and no tail. An unfamiliar name or a version number is transcribed by ear "
                + "alone: 15 of 48 on the same suite."
        default: nil
        }
    }
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
        endpoint: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> any TranscriptionProvider {
        var merged = environment
        // Every spelling is cleared first, so a stale key under an alternate name cannot win a
        // lookup that the canonical one would have satisfied.
        for name in kind.apiKeyEnvVars { merged[name] = nil }
        merged[kind.apiKeyEnvVar] = apiKey
        return try make(kind, endpoint: endpoint, environment: merged)
    }

    /// A backend for the second stage — rewriting, summarising — or nil when there is none.
    ///
    /// For a language model this is the same backend that transcribes, so the answer is the
    /// ordinary provider. For xAI it is a different endpoint reached with the same key:
    /// `/v1/chat/completions` and a Grok chat model, rather than `/v1/stt` and `grok-stt`.
    /// Deepgram and Mistral sell recognition alone and return nil, which is what stops the UI
    /// offering a rewrite that could only fail.
    ///
    /// - Parameter endpoint: honoured only for a language model, where the second stage is the
    ///   same backend on the same URL. A recogniser's override points at its audio endpoint, and
    ///   sending a chat request there would fail for a reason nobody could read off the setting.
    public static func makeTextProvider(
        _ kind: ProviderKind,
        apiKey: String,
        endpoint: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> (any TranscriptionProvider)? {
        guard kind.supportsTextGeneration else { return nil }
        guard kind.isSpeechRecognition else {
            return try make(kind, apiKey: apiKey, endpoint: endpoint, environment: environment)
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
    /// - Parameter endpoint: a URL to post to instead of the backend's own.
    ///
    ///   Every backend takes one, not just `.local`. A user pointing this at a compatible service
    ///   somebody else runs — a proxy, a regional mirror, a gateway that fronts several models —
    ///   is the case this exists for, and it was previously reachable only for `.local` and only
    ///   through an environment variable an app opened from Finder never sees. An empty or
    ///   non-empty invalid value fails explicitly. Silently falling back would send a recording to
    ///   a different recipient than the endpoint the user believed they configured.
    public static func make(
        _ kind: ProviderKind,
        endpoint: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        appURL: String = "https://github.com/donottype/donottype",
        appTitle: String = "DoNotType"
    ) throws -> any TranscriptionProvider {
        let override = try validatedEndpoint(endpoint, for: kind)
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
                baseURL: override
                    ?? URL(string: "https://openrouter.ai/api/v1/chat/completions")!,
                apiKey: key,
                extraHeaders: ["HTTP-Referer": appURL, "X-Title": appTitle]
            )
        case .google:
            // DNT_NO_SCHEMA exists so `dnt-eval` can measure what the structured-output
            // constraint costs in latency. Not a supported configuration: unconstrained output
            // sometimes arrives wrapped in prose, and a dictation tool that occasionally types
            // "Here is the transcript:" is broken.
            return GeminiProvider(
                apiKey: key,
                endpoint: override
                    ?? URL(string: "https://generativelanguage.googleapis.com/v1beta/interactions")!,
                usesStructuredOutput: environment["DNT_NO_SCHEMA"] == nil)

        case .local:
            let base = environment["DNT_LOCAL_BASE_URL"]
                ?? "http://localhost:8000/v1/chat/completions"
            let url: URL
            if let override {
                url = override
            } else if let validated = try validatedEndpoint(base, for: .local) {
                url = validated
            } else {
                throw ProviderError.invalidEndpoint("the local provider endpoint is empty")
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
                apiKey: key,
                endpoint: override ?? URL(string: "https://api.deepgram.com/v1/listen")!,
                language: environment["DNT_DEEPGRAM_LANGUAGE"]?.trimmed.nilIfEmpty)

        case .xai:
            return XAISpeechProvider(
                apiKey: key,
                endpoint: override ?? URL(string: "https://api.x.ai/v1/stt")!,
                language: environment["DNT_XAI_LANGUAGE"]?.trimmed.nilIfEmpty)

        case .mistral:
            // Absent by design: Voxtral's own detection is what makes the code-switching case
            // work, so pinning a language here would remove the reason to choose it.
            return MistralProvider(
                apiKey: key,
                endpoint: override
                    ?? URL(string: "https://api.mistral.ai/v1/audio/transcriptions")!,
                language: environment["DNT_MISTRAL_LANGUAGE"]?.trimmed.nilIfEmpty)
        }
    }

    /// A remote override receives an API key, audio, and possibly screen context, so it must use
    /// TLS. The local-model provider is the exception: its normal serving surface is HTTP on a
    /// loopback or LAN address and its placeholder key is not a credential.
    private static func validatedEndpoint(_ raw: String?, for kind: ProviderKind) throws -> URL? {
        guard let value = raw?.trimmed.nilIfEmpty else { return nil }
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased(),
            let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
            scheme == "https" || (kind == .local && scheme == "http")
        else {
            let requirement = kind == .local ? "use an HTTP or HTTPS URL" : "use an HTTPS URL"
            throw ProviderError.invalidEndpoint(
                "\(requirement) with a host and no embedded credentials")
        }
        return url
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
