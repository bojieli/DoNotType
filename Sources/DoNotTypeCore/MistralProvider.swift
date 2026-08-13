import Foundation

/// Mistral's Voxtral transcription endpoint, `POST /v1/audio/transcriptions`.
///
/// The third recognition backend, and the one that answers the objection to the other two: it
/// transcribes Mandarin and English **without being told which is coming**, including inside a
/// single sentence. Deepgram cannot do this under any autodetecting setting — see
/// `docs/EVALUATION.md` — which for a bilingual user disqualifies it as a default outright.
/// Voxtral returned correct Han text with `retrieval pipeline`, `Google` and `storyline` written
/// in English where the speaker code-switched, from the same request shape as everything else.
///
/// It has no biasing channel at all, so `grounding` is `.none` rather than `.keyterms`. That is
/// measured, not assumed from the documentation: `context=` and `prompt=` form fields are both
/// accepted with HTTP 200 and both leave the transcript byte-identical, including the token
/// counts. An endpoint that silently ignores a parameter is worse than one that rejects it, and
/// pretending it grounds would be the exact failure `GroundingSupport` exists to prevent.
///
/// > Note: this repository previously recorded Voxtral as out of scope. That decision was made
/// > when no `MISTRAL_API_KEY` was configured and applied to the local-GPU campaign;
/// > `docs/MODELS.md` simultaneously called Voxtral's decoder-level biasing "the most promising
/// > follow-up experiment". A key is configured now. The decoder biasing is still unavailable —
/// > it belongs to a Transcribe 2 serving surface this endpoint does not expose.
public struct MistralProvider: TranscriptionProvider {
    public let name = "mistral"
    public let apiKey: String
    public let endpoint: URL
    /// Language code, or `nil` to let Voxtral decide. `nil` is the right default here, unlike on
    /// Deepgram: detection is what makes the code-switching case work.
    public let language: String?

    private let session: URLSession
    private let boundaryProvider: @Sendable () -> String

    public init(
        apiKey: String,
        endpoint: URL = URL(string: "https://api.mistral.ai/v1/audio/transcriptions")!,
        language: String? = nil,
        session: URLSession = .shared,
        // See `XAISpeechProvider`: an internal type cannot appear in a public default argument.
        boundaryProvider: @escaping @Sendable () -> String = { "dnt-\(UUID().uuidString)" }
    ) {
        self.apiKey = apiKey
        self.endpoint = endpoint
        self.language = language
        self.session = session
        self.boundaryProvider = boundaryProvider
    }

    /// No biasing channel exists, so nothing about the screen can reach this backend.
    public func grounding(forModel model: String) -> GroundingSupport { .none }

    public func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        guard let audio = request.audioPart else {
            throw ProviderError.audioRequired(provider: name)
        }

        let boundary = boundaryProvider()
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue(
            "multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = Self.multipartBody(
            for: request, audio: audio, boundary: boundary, language: language)
        urlRequest.timeoutInterval = 120

        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.malformedResponse("no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ProviderError.http(status: http.statusCode, body: Self.errorMessage(from: data))
        }

        let usage = Self.parseUsage(data)
        // Unlike Deepgram and xAI, Voxtral does report audio tokens, so the silent-drop guard is
        // live here rather than skipped for want of a number.
        try assertAudioWasProcessed(request: request, usage: usage, model: request.model)

        let transcript = try Self.parse(data)
        guard !transcript.transcript.trimmed.isEmpty else { throw ProviderError.emptyOutput }

        return TranscriptionResult(
            transcript: transcript, usage: usage,
            rawOutput: String(decoding: data, as: UTF8.self))
    }

    // MARK: - Response

    static func parse(_ data: Data) throws -> Transcript {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.malformedResponse("response was not a JSON object")
        }
        guard let text = root["text"] as? String else {
            throw ProviderError.malformedResponse(
                "no text in response: \(String(decoding: data.prefix(300), as: UTF8.self))")
        }
        // `language` is present but observed null on every clip tested, including ones Voxtral
        // transcribed correctly in Mandarin. Absent means "not reported", not "English".
        return Transcript(transcript: text.trimmed, language: root["language"] as? String ?? "")
    }

    static func parseUsage(_ data: Data) -> TokenUsage {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let usage = root["usage"] as? [String: Any]
        else { return TokenUsage() }

        let details = usage["prompt_tokens_details"] as? [String: Any]
        return TokenUsage(
            promptTokens: usage["prompt_tokens"] as? Int,
            completionTokens: usage["completion_tokens"] as? Int,
            audioTokens: details?["audio_tokens"] as? Int)
    }

    /// Mistral reports failures as `{"object":"error","message":"…","code":"…"}`.
    static func errorMessage(from data: Data) -> String {
        let raw = String(decoding: data, as: UTF8.self)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return raw
        }
        let message = root["message"] as? String
            ?? (root["error"] as? [String: Any])?["message"] as? String
        let code = root["code"] as? String ?? (root["code"] as? Int).map(String.init)
        switch (message, code) {
        case (let message?, let code?): return "\(message) (\(code))"
        case (let message?, nil): return message
        default: return raw
        }
    }

    // MARK: - Request

    static func multipartBody(
        for request: TranscriptionRequest,
        audio: (data: Data, mimeType: String),
        boundary: String,
        language: String?
    ) -> Data {
        var body = MultipartBody(boundary: boundary)
        body.addField("model", request.model)
        if let language { body.addField("language", language) }
        // No fidelity field: the endpoint exposes no formatting or disfluency control, so `raw`,
        // `light` and `tidy` are indistinguishable here. Sending an invented parameter would be
        // worse than sending none — this endpoint accepts unknown fields silently.
        body.addFile(
            "file", filename: "audio.\(MultipartBody.fileExtension(for: audio.mimeType))",
            mimeType: audio.mimeType, bytes: audio.data)
        return body.finish()
    }
}
