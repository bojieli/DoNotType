import Foundation

/// Google's native Interactions API, which replaced `generateContent`.
///
/// Kept alongside the OpenAI-compatible path because it is the only one that is first-party: no
/// gateway sits between the audio and the model, and `store: false` is honoured directly. That
/// matters for an app whose requests contain screen contents.
public struct GeminiProvider: TranscriptionProvider {
    public let name = "gemini"
    public let apiKey: String
    public let endpoint: URL
    /// Enum of `minimal`, `low`, `medium`, `high`. Transcription wants `minimal` — thinking
    /// tokens bill as output and buy nothing here.
    public let thinkingLevel: String

    /// Whether to constrain output to the `Transcript` JSON schema.
    ///
    /// On by default and worth keeping: unconstrained output occasionally arrives wrapped in
    /// prose or a code fence, and a transcription tool that sometimes inserts "Here is the
    /// transcript:" is broken. Exposed only so `dnt-eval` can measure what the constraint costs.
    public let usesStructuredOutput: Bool

    private let session: URLSession

    public init(
        apiKey: String,
        endpoint: URL = URL(string: "https://generativelanguage.googleapis.com/v1beta/interactions")!,
        thinkingLevel: String = "minimal",
        usesStructuredOutput: Bool = true,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.endpoint = endpoint
        self.thinkingLevel = thinkingLevel
        self.usesStructuredOutput = usesStructuredOutput
        self.session = session
    }

    public func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body(for: request))
        urlRequest.timeoutInterval = 120

        let (data, http) = try await session.send(
            urlRequest, provider: name, model: request.model)
        // Errors arrive as a top-level JSON *array*, unlike the success shape.
        guard (200..<300).contains(http.statusCode) else {
            throw ProviderError.http(
                status: http.statusCode, body: Self.errorMessage(from: data))
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.malformedResponse(
                "expected an Interaction object, got: \(String(decoding: data.prefix(300), as: UTF8.self))")
        }

        let usage = parseUsage(root["usage"] as? [String: Any])
        try assertAudioWasProcessed(request: request, usage: usage, model: request.model)

        guard let text = Self.extractText(from: root), !text.trimmed.isEmpty else {
            throw ProviderError.emptyOutput
        }
        return TranscriptionResult(
            transcript: try Transcript.parse(text), usage: usage, rawOutput: text)
    }

    /// Walks `steps[] -> model_output -> content[] -> text`.
    ///
    /// Deliberately not `output_text`: that field is added by the SDKs and is not on the wire.
    static func extractText(from root: [String: Any]) -> String? {
        guard let steps = root["steps"] as? [[String: Any]] else { return nil }
        let chunks = steps
            .filter { $0["type"] as? String == "model_output" }
            .compactMap { $0["content"] as? [[String: Any]] }
            .flatMap { $0 }
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
        return chunks.isEmpty ? nil : chunks.joined()
    }

    // MARK: - Private

    /// Pulls the human-readable message out of an error response.
    ///
    /// Worth the parsing. Raw, the body reads `[{ "error": { "code": 400, "message": "API key not
    /// valid…` — and anywhere it is shown to a user it is truncated long before the sentence that
    /// says what went wrong. A settings panel reporting `HTTP 400: [{ "error": {…` tells someone
    /// nothing they can act on, which is the opposite of the point of showing them an error.
    ///
    /// Falls back to the raw body: an unparseable error is still better than a swallowed one.
    static func errorMessage(from data: Data) -> String {
        let raw = String(decoding: data, as: UTF8.self)
        let parsed = try? JSONSerialization.jsonObject(with: data)

        // Errors come back as a top-level array; a single object is accepted too, since that is
        // the shape most of the API's siblings use and costs one line to support.
        let candidates: [Any]
        switch parsed {
        case let array as [Any]: candidates = array
        case let object as [String: Any]: candidates = [object]
        default: return raw
        }

        let messages = candidates.compactMap { entry -> String? in
            guard let object = entry as? [String: Any],
                let error = object["error"] as? [String: Any]
            else { return nil }

            let message = error["message"] as? String
            let status = error["status"] as? String
            switch (message, status) {
            case (let message?, let status?): return "\(message) (\(status))"
            case (let message?, nil): return message
            case (nil, let status?): return status
            default: return nil
            }
        }
        return messages.isEmpty ? raw : messages.joined(separator: "; ")
    }

    private func body(for request: TranscriptionRequest) -> [String: Any] {
        var body: [String: Any] = [
            "model": request.model,
            // Server-side retention is on by default and these requests carry screen contents.
            "store": false,
            "system_instruction": request.systemInstruction,
            "input": request.parts.map(Self.encode),
            "generation_config": [
                "thinking_level": thinkingLevel,
                "max_output_tokens": request.maxOutputTokens,
            ],
        ]
        if usesStructuredOutput {
            body["response_format"] = [
                "type": "text",
                "mime_type": "application/json",
                "schema": Transcript.jsonSchema,
            ]
        }
        return body
    }

    private static func encode(_ part: InputPart) -> [String: Any] {
        switch part {
        case .text(let value):
            ["type": "text", "text": value]
        case .image(let data, let mimeType):
            ["type": "image", "data": data.base64EncodedString(), "mime_type": mimeType]
        case .audio(let data, let mimeType):
            ["type": "audio", "data": data.base64EncodedString(), "mime_type": mimeType]
        case .remoteAudio(let uri, let mimeType):
            // `uri`, not `file_uri` — the latter is rejected as an unknown parameter.
            ["type": "audio", "uri": uri, "mime_type": mimeType]
        }
    }

    private func parseUsage(_ usage: [String: Any]?) -> TokenUsage {
        guard let usage else { return TokenUsage() }
        let byModality = usage["input_tokens_by_modality"] as? [[String: Any]] ?? []
        let audio = byModality
            .first { ($0["modality"] as? String)?.lowercased() == "audio" }?["tokens"] as? Int
        return TokenUsage(
            promptTokens: usage["total_input_tokens"] as? Int,
            completionTokens: usage["total_output_tokens"] as? Int,
            // Absent modality breakdown means "not reported", not "zero" — only report 0 when the
            // breakdown exists and audio is genuinely missing from it.
            audioTokens: byModality.isEmpty ? nil : (audio ?? 0)
        )
    }
}
