import Foundation

/// Talks to any `/v1/chat/completions` gateway — OpenRouter and most others.
///
/// Multimodal parts map onto the OpenAI content-array shape: `input_audio` for the recording,
/// `image_url` with a data URI for the screenshot. Note that accepting these blocks is not the
/// same as processing them; see `assertAudioWasProcessed`.
public struct OpenAICompatibleProvider: TranscriptionProvider {
    public let name: String
    public let baseURL: URL
    public let apiKey: String
    public let extraHeaders: [String: String]
    /// Reasoning effort, when the gateway forwards it. Transcription needs none.
    public let reasoningEffort: String?

    private let session: URLSession

    /// Models observed to reject `response_format`, so the fallback is paid for once rather than
    /// on every request.
    ///
    /// `openai/gpt-audio` is the reason this exists: it transcribes perfectly well but returns a
    /// provider error the moment a JSON schema is attached. Structured output is a convenience
    /// here, not a requirement — `Transcript.parse` already tolerates bare prose — so refusing to
    /// work with such a model would be the client's failure, not the model's.
    private static let schemaUnsupported = SchemaSupportCache()

    final class SchemaSupportCache: @unchecked Sendable {
        private let lock = NSLock()
        private var models: Set<String> = []

        func isUnsupported(_ model: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return models.contains(model)
        }

        func markUnsupported(_ model: String) {
            lock.lock(); defer { lock.unlock() }
            models.insert(model)
        }
    }

    public init(
        name: String,
        baseURL: URL,
        apiKey: String,
        extraHeaders: [String: String] = [:],
        reasoningEffort: String? = "minimal",
        session: URLSession = .shared
    ) {
        self.name = name
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.extraHeaders = extraHeaders
        self.reasoningEffort = reasoningEffort
        self.session = session
    }

    public func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        let useSchema = !Self.schemaUnsupported.isUnsupported(request.model)
        do {
            return try await send(request, structuredOutput: useSchema)
        } catch let error as ProviderError {
            // Retry once without the schema when that is plausibly the cause. Losing structured
            // output costs nothing here; losing the dictation would cost the user their words.
            guard useSchema, case .http(let status, let body) = error,
                Self.looksLikeSchemaRejection(status: status, body: body)
            else { throw error }

            Self.schemaUnsupported.markUnsupported(request.model)
            return try await send(request, structuredOutput: false)
        }
    }

    /// A 400 with no detail is the common shape here, so the heuristic is deliberately broad —
    /// the cost of a wrong guess is one extra request, and it is remembered either way.
    static func looksLikeSchemaRejection(status: Int, body: String) -> Bool {
        guard status == 400 || status == 422 else { return false }
        let haystack = body.lowercased()
        return haystack.contains("response_format") || haystack.contains("schema")
            || haystack.contains("json") || haystack.contains("provider returned error")
            || haystack.isEmpty
    }

    private func send(
        _ request: TranscriptionRequest, structuredOutput: Bool
    ) async throws -> TranscriptionResult {
        var urlRequest = URLRequest(url: baseURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        for (key, value) in extraHeaders {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        urlRequest.httpBody = try JSONSerialization.data(
            withJSONObject: body(for: request, structuredOutput: structuredOutput))
        urlRequest.timeoutInterval = 120

        let (data, http) = try await session.send(
            urlRequest, provider: name, model: request.model)
        guard (200..<300).contains(http.statusCode) else {
            throw ProviderError.http(
                status: http.statusCode, body: String(decoding: data, as: UTF8.self))
        }

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.malformedResponse("response was not a JSON object")
        }
        // Some gateways return HTTP 200 with an error object in the body.
        if let error = root["error"] as? [String: Any] {
            throw ProviderError.http(status: http.statusCode, body: "\(error)")
        }

        let usage = parseUsage(root["usage"] as? [String: Any])
        try assertAudioWasProcessed(request: request, usage: usage, model: request.model)

        guard
            let choices = root["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any],
            let content = message["content"] as? String,
            !content.trimmed.isEmpty
        else {
            throw ProviderError.emptyOutput
        }

        return TranscriptionResult(
            transcript: try Transcript.parse(content), usage: usage, rawOutput: content)
    }

    // MARK: - Private

    private func body(for request: TranscriptionRequest, structuredOutput: Bool) -> [String: Any] {
        var content: [[String: Any]] = []
        for part in request.parts {
            switch part {
            case .text(let value):
                content.append(["type": "text", "text": value])
            case .image(let data, let mimeType):
                content.append([
                    "type": "image_url",
                    "image_url": ["url": "data:\(mimeType);base64,\(data.base64EncodedString())"],
                ])
            case .audio(let data, let mimeType):
                content.append([
                    "type": "input_audio",
                    "input_audio": [
                        "data": data.base64EncodedString(),
                        "format": Self.audioFormat(for: mimeType),
                    ],
                ])
            }
        }

        var body: [String: Any] = [
            "model": request.model,
            "messages": [
                ["role": "system", "content": request.systemInstruction],
                ["role": "user", "content": content],
            ],
            "max_tokens": request.maxOutputTokens,
        ]
        if structuredOutput {
            body["response_format"] = [
                "type": "json_schema",
                "json_schema": [
                    "name": "transcript",
                    "strict": true,
                    "schema": Transcript.jsonSchema,
                ],
            ]
        }
        if let reasoningEffort {
            body["reasoning"] = ["effort": reasoningEffort]
        }
        return body
    }

    /// The `format` field wants a bare codec name, not a MIME type.
    static func audioFormat(for mimeType: String) -> String {
        switch mimeType.lowercased() {
        case "audio/wav", "audio/x-wav", "audio/wave": "wav"
        case "audio/flac", "audio/x-flac": "flac"
        case "audio/mpeg", "audio/mp3": "mp3"
        case "audio/ogg", "audio/opus": "ogg"
        case "audio/aac": "aac"
        case "audio/aiff", "audio/x-aiff": "aiff"
        default: mimeType.replacingOccurrences(of: "audio/", with: "")
        }
    }

    private func parseUsage(_ usage: [String: Any]?) -> TokenUsage {
        guard let usage else { return TokenUsage() }
        let details = usage["prompt_tokens_details"] as? [String: Any]
        return TokenUsage(
            promptTokens: usage["prompt_tokens"] as? Int,
            completionTokens: usage["completion_tokens"] as? Int,
            audioTokens: details?["audio_tokens"] as? Int
        )
    }
}
