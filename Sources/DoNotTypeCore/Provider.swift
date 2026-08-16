import Foundation

/// One transcription request, provider-agnostic.
public struct TranscriptionRequest: Sendable {
    public var model: String
    public var systemInstruction: String
    /// Context parts followed by exactly one audio part. Order matters — see `CONTEXT_FORMAT.md`.
    public var parts: [InputPart]
    public var maxOutputTokens: Int
    /// How much cleanup the transcript may receive.
    ///
    /// Redundant for a model provider, where the same dial is already baked into
    /// `systemInstruction` by `PromptBuilder`. It is carried separately because a speech
    /// recognition endpoint has no system instruction to bake it into: Deepgram spells `raw`
    /// as `filler_words=true&punctuate=false`, and the only way it can honour the user's
    /// setting is to be told what the setting is.
    public var fidelity: Fidelity
    /// Spellings to bias recognition toward, for backends whose only grounding channel is a
    /// word list. Empty for model providers, which get the screen text itself.
    ///
    /// Populated by `TranscriptionService`, never by a provider — deriving these requires the
    /// `ScreenContext`, which providers deliberately never see.
    public var keyterms: [String]

    public init(
        model: String,
        systemInstruction: String,
        parts: [InputPart],
        maxOutputTokens: Int = 2048,
        fidelity: Fidelity = .default,
        keyterms: [String] = []
    ) {
        self.model = model
        self.systemInstruction = systemInstruction
        self.parts = parts
        self.maxOutputTokens = maxOutputTokens
        self.fidelity = fidelity
        self.keyterms = keyterms
    }

    /// The recording, when there is one. Speech recognition endpoints send exactly this and
    /// nothing else.
    var audioPart: (data: Data, mimeType: String)? {
        for part in parts {
            if case .audio(let data, let mimeType) = part { return (data, mimeType) }
        }
        return nil
    }

    var containsAudio: Bool {
        parts.contains { if case .audio = $0 { true } else { false } }
    }
}

public struct TokenUsage: Sendable, Equatable, Codable {
    public var promptTokens: Int?
    public var completionTokens: Int?
    /// Audio tokens the provider says it billed.
    ///
    /// This is a correctness signal, not an accounting one: a provider that accepts an audio part
    /// and reports zero audio tokens never gave the audio to the model.
    public var audioTokens: Int?

    public init(promptTokens: Int? = nil, completionTokens: Int? = nil, audioTokens: Int? = nil) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.audioTokens = audioTokens
    }

    /// Totals the cost of a dictation that took more than one request.
    ///
    /// `nil` means "not reported" and must not become zero: zero audio tokens is the specific
    /// signal that a provider dropped the audio, so inventing one would fire that alarm falsely.
    public static func + (lhs: Self, rhs: Self) -> Self {
        func add(_ a: Int?, _ b: Int?) -> Int? {
            a == nil && b == nil ? nil : (a ?? 0) + (b ?? 0)
        }
        return TokenUsage(
            promptTokens: add(lhs.promptTokens, rhs.promptTokens),
            completionTokens: add(lhs.completionTokens, rhs.completionTokens),
            audioTokens: add(lhs.audioTokens, rhs.audioTokens))
    }
}

public struct TranscriptionResult: Sendable {
    public var transcript: Transcript
    public var usage: TokenUsage
    /// Raw model output before parsing, kept for the eval report and the context inspector.
    public var rawOutput: String
    /// How many requests the audio was split across. 1 for every ordinary dictation.
    public var chunkCount: Int

    /// Whether `transcript` was emptied on the way out, and why.
    ///
    /// Carried rather than merely logged: deleting words the user might have said is the most
    /// consequential thing this pipeline does silently, and a caller that cannot see it happened
    /// cannot show it, test it, or argue with the threshold. `rawOutput` still holds what the model
    /// actually returned.
    public var suppressed: HallucinationGuard.Verdict

    public init(
        transcript: Transcript, usage: TokenUsage, rawOutput: String, chunkCount: Int = 1,
        suppressed: HallucinationGuard.Verdict = .kept
    ) {
        self.transcript = transcript
        self.usage = usage
        self.rawOutput = rawOutput
        self.chunkCount = chunkCount
        self.suppressed = suppressed
    }
}

public enum ProviderError: Error, LocalizedError, Sendable {
    case http(status: Int, body: String)
    case malformedResponse(String)
    case emptyOutput
    /// Audio was sent, the call succeeded, and the provider billed zero audio tokens.
    case audioSilentlyDropped(provider: String, model: String)
    case missingAPIKey(envVar: String)
    /// A text-only request reached a backend that only accepts audio.
    ///
    /// Its own error case rather than an HTTP 400 because the fix is a product decision, not a
    /// request fix: rewriting a finished transcript needs a language model, and a speech
    /// recognition endpoint is not one. See `RewriteStyle`.
    case audioRequired(provider: String)

    public var errorDescription: String? {
        switch self {
        case .http(let status, let body):
            // Uncut. This is the string somebody pastes into an issue, and the part that was being
            // dropped is routinely the useful part: providers put the offending field name and the
            // request id at the end of the body, after the human-readable message.
            return "HTTP \(status): \(body)"
        case .malformedResponse(let detail):
            return "Malformed response: \(detail)"
        case .emptyOutput:
            return "Model returned no output"
        case .audioSilentlyDropped(let provider, let model):
            return """
                \(provider) accepted the audio but billed 0 audio tokens for \(model) — the \
                recording never reached the model, so any transcript it returned is fabricated. \
                Use a provider that supports audio input.
                """
        case .missingAPIKey(let envVar):
            return "No API key: set \(envVar)"
        case .audioRequired(let provider):
            return """
                \(provider) is a speech recognition endpoint and only accepts audio. It cannot \
                rewrite or reformat text that has already been transcribed — switch to a model \
                provider for that.
                """
        }
    }
}

/// What a backend can do with what is on screen.
///
/// This exists because the two kinds of backend are not interchangeable, and the difference is
/// invisible at the call site. A model provider reads `PROMPT.md`, the labelled context sections
/// and the screenshot. A speech recognition endpoint reads none of them — it has no system
/// instruction, no eyes, and no notion of a conversation. Handing it a `ScreenContext` and
/// carrying on would produce a transcript that looks grounded, is billed as grounded, is recorded
/// in history as grounded, and was in fact produced by a model that never saw the screen.
///
/// That is the same class of failure as `audioSilentlyDropped`, which this codebase already
/// refuses to let pass quietly, so it gets the same treatment: the capability is declared, and
/// `TranscriptionService` sends each backend only what it can actually use.
public enum GroundingSupport: Sendable, Equatable {
    /// Reads everything: system instruction, labelled screen text, screenshot.
    case multimodal
    /// A recogniser that accepts a list of spellings to bias toward, and nothing else.
    ///
    /// - Parameters:
    ///   - maxTerms: how many the endpoint accepts before it starts rejecting or ignoring them.
    ///   - maxCharsPerTerm: longest single term the endpoint accepts.
    case keyterms(maxTerms: Int, maxCharsPerTerm: Int)
    /// A recogniser with no biasing channel at all. Screen context is unusable, full stop.
    case none

    /// Whether the system instruction — and therefore `PROMPT.md` and the fidelity ladder it
    /// encodes — reaches the model at all.
    public var readsSystemInstruction: Bool { self == .multimodal }
}

public protocol TranscriptionProvider: Sendable {
    var name: String { get }

    /// Takes the model because the capability is often the model's, not the backend's: Deepgram
    /// offers keyterm biasing on nova-3 and rejects the parameter on everything older, and a
    /// backend-wide answer would have to be wrong for one of them.
    ///
    /// Defaulted so the existing model providers, for which `.multimodal` is simply the truth,
    /// say nothing extra.
    func grounding(forModel model: String) -> GroundingSupport

    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult
}

extension TranscriptionProvider {
    public func grounding(forModel model: String) -> GroundingSupport { .multimodal }
}

extension TranscriptionProvider {
    /// Fails loudly when audio was sent but demonstrably not processed.
    ///
    /// Worth the strictness: a silently-dropped recording does not produce an error or an empty
    /// string, it produces a fluent, confident, entirely invented sentence. This is not
    /// hypothetical — one OpenAI-compatible gateway was observed accepting an `input_audio` block,
    /// returning HTTP 200, billing 14 prompt tokens for a 6-second clip, and transcribing the
    /// *screen context* as though it were speech. That gateway was dropped, but any provider can
    /// behave this way, so the check lives here rather than in a per-provider allowlist.
    ///
    /// A provider that reports no usage data at all gets the benefit of the doubt, since "dropped"
    /// and "not reported" are indistinguishable. Verify those with `dnt-eval probe --audio`.
    func assertAudioWasProcessed(
        request: TranscriptionRequest, usage: TokenUsage, model: String
    ) throws {
        guard request.containsAudio, let audioTokens = usage.audioTokens, audioTokens == 0 else {
            return
        }
        throw ProviderError.audioSilentlyDropped(provider: name, model: model)
    }
}
