import Foundation

/// Deepgram's `/v1/listen` speech recognition endpoint.
///
/// The first backend here that is not a language model, which changes what the rest of the app can
/// expect of it. There is no system instruction, so `PROMPT.md` never reaches it; there is no
/// image input, so the screenshot path is unavailable; and there is no conversation, so
/// `TranscriptionService.rewrite` cannot run through it. Each of those is declared rather than
/// discovered — see `grounding` and `ProviderError.audioRequired`.
///
/// What it offers in exchange is speed and price: transcription is billed per audio minute rather
/// than per token, and the round trip is a fraction of a model call. See `docs/EVALUATION.md` for
/// the measured comparison, including where it loses.
public struct DeepgramProvider: TranscriptionProvider {
    public let name = "deepgram"
    public let apiKey: String
    public let endpoint: URL
    /// Language code to decode as, or `nil` for the model's best general setting.
    ///
    /// `nil` resolves to `multi` on nova-3 and to `detect_language` elsewhere, which is a measured
    /// choice rather than a reading of the documentation. On the 16-case near-miss suite,
    /// three passes each:
    ///
    /// | language setting | matched | with keyterms |
    /// |---|---|---|
    /// | `detect_language=true` | 12/42 | 17/42 |
    /// | `multi` | 18/42 | **27/42** |
    ///
    /// Detection does not merely score worse, it fails in the worst available way. It is a
    /// per-request classification, and when it guesses wrong the response is HTTP 200 with an
    /// empty transcript rather than an error — `real-mandarin.wav` was classified as French and
    /// came back blank. `multi` at least fails the same clips consistently.
    ///
    /// Neither setting transcribes Mandarin at all; `language: "zh"` does, perfectly, on all three
    /// Mandarin fixtures. A Chinese-speaking user must set `DNT_DEEPGRAM_LANGUAGE=zh`, and there is
    /// no autodetecting default that would spare them that.
    public let language: String?

    /// Injected by tests only. Nil means `ProviderTransport` decides, which is what the
    /// app does.
    private let sessionOverride: URLSession?

    /// `keyterm` is nova-3 only; earlier models reject it outright rather than ignoring it.
    ///
    /// Capacities are Deepgram's documented ceilings. Exceeding either is a 400, so
    /// `TranscriptionService` truncates to them rather than letting a long document produce a
    /// failed dictation.
    static let keytermCapableModelPrefix = "nova-3"
    static let maxKeyterms = 100
    static let maxKeytermChars = 50

    public init(
        apiKey: String,
        endpoint: URL = URL(string: "https://api.deepgram.com/v1/listen")!,
        language: String? = nil,
        session: URLSession? = nil
    ) {
        self.apiKey = apiKey
        self.endpoint = endpoint
        self.language = language
        self.sessionOverride = session
    }

    public var endpointOrigin: URL? { endpoint.origin }

    /// Answered per-model, because the biasing channel only exists on nova-3. A provider that
    /// claimed `.keyterms` while configured with nova-2 would have the service derive terms,
    /// truncate them, send them, and get a 400 for its trouble.
    public func grounding(forModel model: String) -> GroundingSupport {
        model.hasPrefix(Self.keytermCapableModelPrefix)
            ? .keyterms(maxTerms: Self.maxKeyterms, maxCharsPerTerm: Self.maxKeytermChars)
            : .none
    }

    public func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        guard let audio = request.audioPart else {
            throw ProviderError.audioRequired(provider: name)
        }

        var urlRequest = URLRequest(url: try url(for: request))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue(audio.mimeType, forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = audio.data
        urlRequest.timeoutInterval = ProviderTransport.requestTimeoutSeconds

        let session = await ProviderTransport.session(
            override: sessionOverride, for: endpoint, connection: request.connection)
        let (data, http) = try await session.send(
            urlRequest, provider: name, model: request.model)
        guard (200..<300).contains(http.statusCode) else {
            throw ProviderError.http(status: http.statusCode, body: Self.errorMessage(from: data))
        }

        let transcript = try Self.parse(data)
        guard !transcript.transcript.trimmed.isEmpty else { throw ProviderError.emptyOutput }

        // Deliberately no usage: Deepgram bills by audio duration and reports no token counts, and
        // `TokenUsage` has no field that would not be an invention. Reporting zero audio tokens
        // would trip `assertAudioWasProcessed` on every successful call.
        return TranscriptionResult(
            transcript: transcript, usage: TokenUsage(),
            rawOutput: String(decoding: data, as: UTF8.self))
    }

    // MARK: - Response

    /// Reads `results.channels[0].alternatives[0].transcript`, with the detected language when
    /// Deepgram classified one.
    static func parse(_ data: Data) throws -> Transcript {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError.malformedResponse("response was not a JSON object")
        }
        guard
            let results = root["results"] as? [String: Any],
            let channels = results["channels"] as? [[String: Any]],
            let channel = channels.first,
            let alternatives = channel["alternatives"] as? [[String: Any]],
            let text = alternatives.first?["transcript"] as? String
        else {
            throw ProviderError.malformedResponse(
                "no transcript in response: \(String(decoding: data.prefix(300), as: UTF8.self))")
        }
        return Transcript(
            transcript: text.trimmed,
            language: channel["detected_language"] as? String ?? "")
    }

    /// Deepgram reports failures as `{"err_code": "...", "err_msg": "..."}`.
    ///
    /// Worth unwrapping for the same reason `GeminiProvider` unwraps its own: the settings panel
    /// truncates, and `err_msg` is the half that says what to change.
    static func errorMessage(from data: Data) -> String {
        let raw = String(decoding: data, as: UTF8.self)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return raw
        }
        let message = root["err_msg"] as? String ?? root["message"] as? String
        let code = root["err_code"] as? String
        switch (message, code) {
        case (let message?, let code?): return "\(message) (\(code))"
        case (let message?, nil): return message
        case (nil, let code?): return code
        default: return raw
        }
    }

    // MARK: - Request

    /// `multi` is a nova-3 feature. Sending it to an older model is a 400, so those fall back to
    /// detection — worse, but a worse transcript beats a failed dictation.
    static func languageItems(explicit: String?, model: String) -> [URLQueryItem] {
        if let explicit, !explicit.isEmpty {
            return [URLQueryItem(name: "language", value: explicit)]
        }
        return model.hasPrefix(keytermCapableModelPrefix)
            ? [URLQueryItem(name: "language", value: "multi")]
            : [URLQueryItem(name: "detect_language", value: "true")]
    }

    private func url(for request: TranscriptionRequest) throws -> URL {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw ProviderError.malformedResponse("invalid Deepgram endpoint: \(endpoint)")
        }

        var items = [URLQueryItem(name: "model", value: request.model)]

        // The fidelity ladder, in the only vocabulary this endpoint has — which has two rungs
        // where `PROMPT.md` has three.
        //
        // `raw` and `tidy` map exactly. `light` does not, and cannot: its clause says "do not add
        // punctuation the speaker did not imply" *and* "do not change capitalisation beyond
        // proper nouns", while Deepgram's only unpunctuated mode returns everything lower case.
        // Both reachable settings therefore break one half of the clause, so `light` takes the
        // half that keeps the transcript usable — proper nouns intact, at the cost of punctuation
        // the speaker may not have implied. `light` and `tidy` consequently collapse to the same
        // request here. Faking a difference by disabling number formatting would produce "three
        // point five" where every other backend writes "3.5", which is a bigger and stranger
        // divergence than the one being avoided.
        switch request.fidelity {
        case .raw:
            items.append(URLQueryItem(name: "punctuate", value: "false"))
            items.append(URLQueryItem(name: "smart_format", value: "false"))
            items.append(URLQueryItem(name: "filler_words", value: "true"))
        case .light, .tidy:
            items.append(URLQueryItem(name: "smart_format", value: "true"))
            items.append(URLQueryItem(name: "filler_words", value: "false"))
        }

        items.append(contentsOf: Self.languageItems(explicit: language, model: request.model))

        // Guarded by the model check as well as by the caller, so a request built by hand cannot
        // turn a supported dictation into a 400.
        if case .keyterms = grounding(forModel: request.model) {
            for term in request.keyterms.prefix(Self.maxKeyterms)
            where term.count <= Self.maxKeytermChars {
                items.append(URLQueryItem(name: "keyterm", value: term))
            }
        }

        components.queryItems = items
        guard let url = components.url else {
            throw ProviderError.malformedResponse("could not build Deepgram request URL")
        }
        return url
    }
}
