import Foundation

/// One transcription request, provider-agnostic.
public struct TranscriptionRequest: Sendable {
    public var model: String
    public var systemInstruction: String
    /// Context parts followed by exactly one audio part. Order matters — see `CONTEXT_FORMAT.md`.
    public var parts: [InputPart]
    public var maxOutputTokens: Int

    public init(
        model: String,
        systemInstruction: String,
        parts: [InputPart],
        maxOutputTokens: Int = 2048
    ) {
        self.model = model
        self.systemInstruction = systemInstruction
        self.parts = parts
        self.maxOutputTokens = maxOutputTokens
    }

    var containsAudio: Bool {
        parts.contains { if case .audio = $0 { true } else { false } }
    }
}

public struct TokenUsage: Sendable, Equatable {
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
}

public struct TranscriptionResult: Sendable {
    public var transcript: Transcript
    public var usage: TokenUsage
    /// Raw model output before parsing, kept for the eval report and the context inspector.
    public var rawOutput: String
}

public enum ProviderError: Error, LocalizedError, Sendable {
    case http(status: Int, body: String)
    case malformedResponse(String)
    case emptyOutput
    /// Audio was sent, the call succeeded, and the provider billed zero audio tokens.
    case audioSilentlyDropped(provider: String, model: String)
    case missingAPIKey(envVar: String)

    public var errorDescription: String? {
        switch self {
        case .http(let status, let body):
            return "HTTP \(status): \(body.prefix(400))"
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
        }
    }
}

public protocol TranscriptionProvider: Sendable {
    var name: String { get }
    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult
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
