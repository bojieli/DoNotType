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
        var urlRequest = URLRequest(url: baseURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        for (key, value) in extraHeaders {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body(for: request))
        urlRequest.timeoutInterval = 120

        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.malformedResponse("no HTTP response")
        }
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

    private func body(for request: TranscriptionRequest) -> [String: Any] {
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
            "response_format": [
                "type": "json_schema",
                "json_schema": [
                    "name": "transcript",
                    "strict": true,
                    "schema": Transcript.jsonSchema,
                ],
            ],
        ]
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
