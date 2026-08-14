import Foundation

/// xAI's `/v1/stt` speech recognition endpoint.
///
/// Shaped almost identically to `DeepgramProvider` — audio in, text out, a keyterm list as the
/// only grounding channel — and differing in transport: multipart form fields rather than a raw
/// body with query parameters. The two are kept as separate types rather than one parameterised
/// one because that is the only thing they share, and a shared base class would exist to hold two
/// string constants.
///
/// Verified against the live API on 2026-08-12, after a working key became available. It had been
/// written blind to the published specification, and verification immediately found two things the
/// specification does not mention — both of which had made the default configuration broken:
///
/// - `format=true` is rejected with "Field 'language' is required when 'format' is true", so the
///   nil-language default 400'd on every `light` and `tidy` request.
/// - **Form fields written after the file part are silently ignored.** HTTP 200, no error, options
///   simply not applied. See the warning in `multipartBody`.
///
/// This is exactly what `ProviderRegistry`'s "verify before adding" rule exists to catch.
public struct XAISpeechProvider: TranscriptionProvider {
    public let name = "xai"
    public let apiKey: String
    public let endpoint: URL

    /// Language code, or `nil` for `auto`.
    ///
    /// `auto` is the default and it is not free: an explicit language is what turns on inverse
    /// text normalisation, so `auto` transcribes "three point five" where `en` writes "3.5".
    /// Measured, both ways, on the same clip.
    ///
    /// It is still the right default here, because the alternative is worse in a way that cannot
    /// be recovered from. Pinning `en` does not merely mis-format Mandarin, and `auto` genuinely
    /// detects: the same request returned `zh` with the English kept inline — `retrieval
    /// pipeline`, `OK` — on a code-switched clip. Set `DNT_XAI_LANGUAGE=en` to trade that for
    /// formatted numbers.
    public let language: String?

    /// Never empty: `format=true` is rejected with "Field 'language' is required when 'format' is
    /// true", so a request with formatting on and no language is a guaranteed 400.
    var resolvedLanguage: String { language?.trimmed.nilIfEmpty ?? "auto" }

    private let session: URLSession
    private let boundaryProvider: @Sendable () -> String

    /// Documented ceilings: 100 terms, 50 characters each.
    static let maxKeyterms = 100
    static let maxKeytermChars = 50

    public init(
        apiKey: String,
        endpoint: URL = URL(string: "https://api.x.ai/v1/stt")!,
        language: String? = nil,
        session: URLSession = .shared,
        // Spelled out rather than calling `MultipartBody.randomBoundary()`: a default argument in
        // a public initializer cannot reference an internal type.
        boundaryProvider: @escaping @Sendable () -> String = { "dnt-\(UUID().uuidString)" }
    ) {
        self.apiKey = apiKey
        self.endpoint = endpoint
        self.language = language
        self.session = session
        self.boundaryProvider = boundaryProvider
    }

    public func grounding(forModel model: String) -> GroundingSupport {
        .keyterms(maxTerms: Self.maxKeyterms, maxCharsPerTerm: Self.maxKeytermChars)
    }

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
        urlRequest.httpBody = Self.multipartBody(for: request, audio: audio, boundary: boundary,
            language: resolvedLanguage)
        urlRequest.timeoutInterval = 120

        let (data, http) = try await session.send(
            urlRequest, provider: name, model: request.model)
        guard (200..<300).contains(http.statusCode) else {
            throw ProviderError.http(status: http.statusCode, body: Self.errorMessage(from: data))
        }

        let transcript = try Self.parse(data)
        guard !transcript.transcript.trimmed.isEmpty else { throw ProviderError.emptyOutput }

        // No usage for the same reason as Deepgram: billing is per audio hour and no token counts
        // are reported. Zero would falsely trip `assertAudioWasProcessed`.
        return TranscriptionResult(
            transcript: transcript, usage: TokenUsage(),
            rawOutput: String(decoding: data, as: UTF8.self))
    }

    // MARK: - Response

    /// Reads the documented `{ "text", "language", "duration", "words" }` shape.
    static func parse(_ data: Data) throws -> Transcript {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.malformedResponse("response was not a JSON object")
        }
        guard let text = root["text"] as? String else {
            throw ProviderError.malformedResponse(
                "no text in response: \(String(decoding: data.prefix(300), as: UTF8.self))")
        }
        return Transcript(
            transcript: text.trimmed, language: root["language"] as? String ?? "")
    }

    /// xAI reports failures as `{"code": "...", "error": "..."}`, observed from the live API.
    static func errorMessage(from data: Data) -> String {
        let raw = String(decoding: data, as: UTF8.self)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return raw
        }
        let message = root["error"] as? String
            ?? (root["error"] as? [String: Any])?["message"] as? String
            ?? root["msg"] as? String
        let code = root["code"] as? String
        switch (message, code) {
        case (let message?, let code?): return "\(message) (\(code))"
        case (let message?, nil): return message
        case (nil, let code?): return code
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

        // ⚠️ Every field must be written BEFORE the file part. This endpoint silently ignores form
        // fields that appear after it — no error, HTTP 200, and the options simply do not apply.
        // Verified deterministically: fields-then-file returns "3.5" on three runs out of three,
        // file-then-fields returns "three point five" on three out of three, same request
        // otherwise. Reordering these lines would quietly disable formatting and keyterm biasing,
        // which is why `testEveryFieldIsWrittenBeforeTheFilePart` exists.

        // `format` is Inverse Text Normalization — "three point five" becoming "3.5", dates and
        // currency written as numerals. Left on for `light` as well as `tidy`, for the reason
        // spelled out in `DeepgramProvider`: a recogniser has two rungs where `PROMPT.md` has
        // three, and the alternative makes `light` diverge from every other backend on numbers.
        body.addField("format", request.fidelity == .raw ? "false" : "true")
        body.addField("filler_words", request.fidelity == .raw ? "true" : "false")
        // Always sent, never conditional: `format=true` is a 400 without it.
        if let language { body.addField("language", language) }

        for term in request.keyterms.prefix(maxKeyterms) where term.count <= maxKeytermChars {
            body.addField("keyterm", term)
        }

        body.addFile(
            "file", filename: "audio.\(MultipartBody.fileExtension(for: audio.mimeType))",
            mimeType: audio.mimeType, bytes: audio.data)
        return body.finish()
    }
}
