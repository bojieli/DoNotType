import XCTest

@testable import DoNotTypeCore

/// Response parsing, request shaping and capability reporting for the two speech recognition
/// backends, all offline.
///
/// The response fixtures are trimmed copies of real bodies returned by the live APIs, not invented
/// shapes — a parser tested against a guess proves only that the guess is self-consistent.
final class DeepgramProviderTests: XCTestCase {
    /// Captured from `POST /v1/listen?model=nova-3` on 2026-08-12.
    private let response = Data(
        """
        {"metadata":{"transaction_key":"deprecated","request_id":"019ff19e-5d8c-7f72",
        "duration":3.0441875,"channels":1},
        "results":{"channels":[{"detected_language":"en","language_confidence":0.9987,
        "alternatives":[{"transcript":"Should switch to Gemini 3.5 flash for this.",
        "confidence":1.0}]}]}}
        """.replacingOccurrences(of: "\n", with: "").utf8)

    func testParsesTranscriptAndDetectedLanguage() throws {
        let transcript = try DeepgramProvider.parse(response)
        XCTAssertEqual(transcript.transcript, "Should switch to Gemini 3.5 flash for this.")
        XCTAssertEqual(transcript.language, "en")
    }

    /// Silence is a valid response, and it must not be mistaken for a broken one by the parser —
    /// `transcribe` turns it into `emptyOutput` a step later, where the distinction is meaningful.
    func testEmptyTranscriptParsesRatherThanThrowing() throws {
        let silent = Data(
            #"{"results":{"channels":[{"alternatives":[{"transcript":""}]}]}}"#.utf8)
        XCTAssertEqual(try DeepgramProvider.parse(silent).transcript, "")
    }

    func testResponseWithoutATranscriptThrows() {
        XCTAssertThrowsError(try DeepgramProvider.parse(Data(#"{"results":{}}"#.utf8)))
        XCTAssertThrowsError(try DeepgramProvider.parse(Data("not json".utf8)))
    }

    func testErrorBodyIsUnwrappedToTheActionableSentence() {
        let body = Data(#"{"err_code":"INVALID_AUTH","err_msg":"Token is invalid"}"#.utf8)
        XCTAssertEqual(DeepgramProvider.errorMessage(from: body), "Token is invalid (INVALID_AUTH)")
    }

    func testUnparseableErrorBodyFallsBackToTheRawText() {
        XCTAssertEqual(DeepgramProvider.errorMessage(from: Data("502 Bad Gateway".utf8)),
            "502 Bad Gateway")
    }

    // MARK: - Capability

    /// Keyterm biasing is nova-3 only, and claiming it on an older model would have the service
    /// build terms that the API then rejects outright.
    func testKeytermSupportIsReportedPerModel() {
        let provider = DeepgramProvider(apiKey: "k")
        XCTAssertEqual(
            provider.grounding(forModel: "nova-3"),
            .keyterms(maxTerms: 100, maxCharsPerTerm: 50))
        XCTAssertEqual(provider.grounding(forModel: "nova-2"), GroundingSupport.none)
        XCTAssertEqual(provider.grounding(forModel: "whisper-large"), GroundingSupport.none)
    }

    // MARK: - Language

    /// `multi` measured 18/42 against detection's 12/42 on the near-miss suite, and 27 against 17
    /// with keyterms — see the table on `DeepgramProvider.language`.
    func testNovaThreeDefaultsToMultilingualRatherThanDetection() {
        let items = DeepgramProvider.languageItems(explicit: nil, model: "nova-3")
        XCTAssertEqual(items.map(\.name), ["language"])
        XCTAssertEqual(items.first?.value, "multi")
    }

    /// `multi` is nova-3 only and a 400 on anything older, which would turn a working dictation
    /// into a failed one.
    func testOlderModelsFallBackToDetectionRatherThanSendingMulti() {
        let items = DeepgramProvider.languageItems(explicit: nil, model: "nova-2")
        XCTAssertEqual(items.map(\.name), ["detect_language"])
    }

    func testAnExplicitLanguageAlwaysWins() {
        for model in ["nova-3", "nova-2"] {
            let items = DeepgramProvider.languageItems(explicit: "zh", model: model)
            XCTAssertEqual(items.map(\.name), ["language"])
            XCTAssertEqual(items.first?.value, "zh")
        }
    }

    func testTextOnlyRequestIsRejectedRatherThanSentAsAnEmptyBody() async {
        let request = TranscriptionRequest(
            model: "nova-3", systemInstruction: "", parts: [.text("rewrite this")])
        do {
            _ = try await DeepgramProvider(apiKey: "k").transcribe(request)
            XCTFail("expected audioRequired")
        } catch ProviderError.audioRequired(let provider) {
            XCTAssertEqual(provider, "deepgram")
        } catch {
            XCTFail("expected audioRequired, got \(error)")
        }
    }
}

final class XAISpeechProviderTests: XCTestCase {
    func testParsesDocumentedResponseShape() throws {
        let body = Data(
            #"{"text":"Ask Kaelith to review it.","language":"en","duration":2.6}"#.utf8)
        let transcript = try XAISpeechProvider.parse(body)
        XCTAssertEqual(transcript.transcript, "Ask Kaelith to review it.")
        XCTAssertEqual(transcript.language, "en")
    }

    /// The one part of this provider confirmed against the live API: the error shape, observed
    /// while the supplied key was being rejected.
    func testLiveErrorShapeIsUnwrapped() {
        let body = Data(
            """
            {"code":"invalid-argument","error":"Incorrect API key provided. You can obtain an \
            API key from https://console.x.ai."}
            """.utf8)
        XCTAssertEqual(
            XAISpeechProvider.errorMessage(from: body),
            "Incorrect API key provided. You can obtain an API key from "
                + "https://console.x.ai. (invalid-argument)")
    }

    func testMultipartBodyCarriesTheAudioAndItsFields() {
        let request = TranscriptionRequest(
            model: "grok-stt", systemInstruction: "",
            parts: [.audio(data: Data([1, 2, 3, 4]), mimeType: "audio/ogg")],
            fidelity: .tidy, keyterms: ["Kaelith", "quillmark-sync"])

        let body = XAISpeechProvider.multipartBody(
            for: request, audio: (Data([1, 2, 3, 4]), "audio/ogg"), boundary: "BOUND",
            language: "en")
        let text = String(decoding: body, as: UTF8.self)

        XCTAssertTrue(text.contains("name=\"file\"; filename=\"audio.ogg\""))
        XCTAssertTrue(text.contains("Content-Type: audio/ogg"))
        XCTAssertTrue(text.contains("name=\"language\"\r\n\r\nen"))
        XCTAssertTrue(text.contains("name=\"keyterm\"\r\n\r\nKaelith"))
        XCTAssertTrue(text.contains("name=\"keyterm\"\r\n\r\nquillmark-sync"))
        // Inverse text normalisation on, so numbers arrive as numerals like every other backend.
        XCTAssertTrue(text.contains("name=\"format\"\r\n\r\ntrue"))
        XCTAssertTrue(text.hasSuffix("--BOUND--\r\n"))
    }

    /// The invariant that is invisible in a diff and silent at runtime.
    ///
    /// `/v1/stt` ignores form fields written after the file part — no error, HTTP 200, options
    /// simply not applied. Measured deterministically: fields-then-file returned "3.5" three times
    /// out of three, file-then-fields "three point five" three out of three, same request
    /// otherwise. A refactor that reorders the body would quietly disable formatting and keyterm
    /// biasing, and nothing else in the project would notice.
    func testEveryFieldIsWrittenBeforeTheFilePart() {
        let request = TranscriptionRequest(
            model: "grok-stt", systemInstruction: "",
            parts: [.audio(data: Data([9]), mimeType: "audio/wav")],
            keyterms: ["Kaelith"])
        let text = String(
            decoding: XAISpeechProvider.multipartBody(
                for: request, audio: (Data([9]), "audio/wav"), boundary: "B", language: "auto"),
            as: UTF8.self)

        let filePosition = try? XCTUnwrap(text.range(of: "name=\"file\"")).lowerBound
        for field in ["format", "filler_words", "language", "keyterm"] {
            guard let position = text.range(of: "name=\"\(field)\"")?.lowerBound,
                let filePosition
            else { return XCTFail("\(field) missing from the body") }
            XCTAssertLessThan(position, filePosition, "\(field) must precede the file part")
        }
    }

    /// `format=true` is rejected with "Field 'language' is required when 'format' is true", so a
    /// nil language would 400 on every non-raw request.
    func testLanguageDefaultsToAutoRatherThanBeingOmitted() {
        XCTAssertEqual(XAISpeechProvider(apiKey: "k").resolvedLanguage, "auto")
        XCTAssertEqual(XAISpeechProvider(apiKey: "k", language: "  ").resolvedLanguage, "auto")
        XCTAssertEqual(XAISpeechProvider(apiKey: "k", language: "en").resolvedLanguage, "en")
    }

    func testRawFidelityKeepsFillersAndSuppressesNumberFormatting() {
        let request = TranscriptionRequest(
            model: "grok-stt", systemInstruction: "",
            parts: [.audio(data: Data(), mimeType: "audio/wav")], fidelity: .raw)
        let text = String(
            decoding: XAISpeechProvider.multipartBody(
                for: request, audio: (Data(), "audio/wav"), boundary: "B", language: nil),
            as: UTF8.self)

        XCTAssertTrue(text.contains("name=\"format\"\r\n\r\nfalse"))
        XCTAssertTrue(text.contains("name=\"filler_words\"\r\n\r\ntrue"))
        XCTAssertFalse(text.contains("name=\"language\""))
    }

    /// A term over the documented 50-character ceiling is dropped rather than sent, because the
    /// endpoint rejects the whole request rather than the offending term.
    func testOversizedKeytermsAreDroppedNotTruncated() {
        let long = String(repeating: "a", count: 60)
        let request = TranscriptionRequest(
            model: "grok-stt", systemInstruction: "",
            parts: [.audio(data: Data(), mimeType: "audio/wav")],
            keyterms: [long, "Kaelith"])
        let text = String(
            decoding: XAISpeechProvider.multipartBody(
                for: request, audio: (Data(), "audio/wav"), boundary: "B", language: nil),
            as: UTF8.self)

        XCTAssertFalse(text.contains(long))
        XCTAssertTrue(text.contains("Kaelith"))
    }
}

/// The thinking level is not a constant, and finding that out cost a broken request.
///
/// `gemini-3.6-flash` accepts `minimal`; `gemini-3.7-flash` rejects it with "'minimal' is not a
/// supported thinking level for this model. Allowed values are: medium, low, high." A hardcoded
/// default therefore failed every request the moment the model field was changed.
final class GeminiThinkingLevelTests: XCTestCase {
    func testEachFamilyGetsTheCheapestLevelItAccepts() {
        XCTAssertEqual(
            GeminiProvider.cheapestThinkingLevel(forModel: "gemini-3.6-flash"), "minimal")
        XCTAssertEqual(
            GeminiProvider.cheapestThinkingLevel(forModel: "gemini-3.7-flash"), "low")
    }

    /// A prefix match rather than an allowlist, so a point release inherits its family's floor
    /// instead of silently costing thinking tokens on every dictation.
    func testAPointReleaseInheritsItsFamilyFloor() {
        XCTAssertEqual(
            GeminiProvider.cheapestThinkingLevel(forModel: "gemini-3.7-flash-preview-0812"), "low")
        XCTAssertEqual(
            GeminiProvider.cheapestThinkingLevel(forModel: "gemini-4-flash"), "low")
        XCTAssertEqual(
            GeminiProvider.cheapestThinkingLevel(forModel: "gemini-2.5-flash"), "minimal")
    }

    /// An explicit level still wins, so `dnt-eval` can measure what the constraint costs.
    func testAnExplicitLevelIsHonoured() {
        let provider = GeminiProvider(apiKey: "k", thinkingLevel: "high")
        XCTAssertEqual(provider.thinkingLevel, "high")
    }
}

final class MistralProviderTests: XCTestCase {
    /// Trimmed from a real `voxtral-mini-latest` response.
    private let response = Data(
        """
        {"model":"voxtral-mini-latest","text":"We should switch to Gemini 3.5 flash for this.",
        "language":null,"segments":[],"usage":{"prompt_audio_seconds":3,"prompt_tokens":3,
        "total_tokens":392,"completion_tokens":14,
        "prompt_tokens_details":{"cached_tokens":0,"audio_tokens":375}}}
        """.replacingOccurrences(of: "\n", with: "").utf8)

    func testParsesTranscript() throws {
        let transcript = try MistralProvider.parse(response)
        XCTAssertEqual(transcript.transcript, "We should switch to Gemini 3.5 flash for this.")
        // `language` comes back null on every clip tested, including correct Mandarin ones.
        XCTAssertEqual(transcript.language, "")
    }

    /// Voxtral is the only recognition backend here that reports audio tokens, so it is the only
    /// one where the silent-drop guard can actually fire.
    func testReportsAudioTokensSoTheSilentDropGuardIsLive() {
        let usage = MistralProvider.parseUsage(response)
        XCTAssertEqual(usage.audioTokens, 375)
        XCTAssertEqual(usage.promptTokens, 3)
        XCTAssertEqual(usage.completionTokens, 14)
    }

    /// Measured, not assumed: `context=` and `prompt=` are accepted with HTTP 200 and leave the
    /// transcript byte-identical, so claiming any grounding would be a lie.
    func testReportsNoGroundingAtAll() {
        XCTAssertEqual(
            MistralProvider(apiKey: "k").grounding(forModel: "voxtral-mini-latest"),
            GroundingSupport.none)
    }

    func testMultipartCarriesModelAndAudioButNoInventedFidelityField() {
        let request = TranscriptionRequest(
            model: "voxtral-mini-latest", systemInstruction: "",
            parts: [.audio(data: Data([1, 2]), mimeType: "audio/ogg")], fidelity: .raw)
        let text = String(
            decoding: MistralProvider.multipartBody(
                for: request, audio: (Data([1, 2]), "audio/ogg"), boundary: "B", language: nil),
            as: UTF8.self)

        XCTAssertTrue(text.contains("name=\"model\"\r\n\r\nvoxtral-mini-latest"))
        XCTAssertTrue(text.contains("filename=\"audio.ogg\""))
        // The endpoint accepts unknown fields silently, so sending one would be worse than none.
        XCTAssertFalse(text.contains("filler_words"))
        XCTAssertFalse(text.contains("format"))
        XCTAssertFalse(text.contains("name=\"language\""))
    }

    func testErrorBodyIsUnwrapped() {
        let body = Data(
            #"{"object":"error","message":"Invalid model","type":"invalid_model","code":"1500"}"#
                .utf8)
        XCTAssertEqual(MistralProvider.errorMessage(from: body), "Invalid model (1500)")
    }

    func testTextOnlyRequestIsRejected() async {
        let request = TranscriptionRequest(
            model: "voxtral-mini-latest", systemInstruction: "", parts: [.text("rewrite")])
        do {
            _ = try await MistralProvider(apiKey: "k").transcribe(request)
            XCTFail("expected audioRequired")
        } catch ProviderError.audioRequired(let provider) {
            XCTAssertEqual(provider, "mistral")
        } catch {
            XCTFail("expected audioRequired, got \(error)")
        }
    }
}

final class ProviderRegistrySpeechTests: XCTestCase {
    func testKeyEnvironmentVariablesMatchTheDocumentedNames() {
        XCTAssertEqual(ProviderKind.deepgram.apiKeyEnvVar, "DEEPGRAM_API_KEY")
        XCTAssertEqual(ProviderKind.xai.apiKeyEnvVar, "XAI_API_KEY")
        XCTAssertEqual(ProviderKind.mistral.apiKeyEnvVar, "MISTRAL_API_KEY")
    }

    /// nova-3 by default specifically because it is the only Deepgram model with a keyterm
    /// channel; an older default would disable the feature without saying so.
    func testDeepgramDefaultsToTheOnlyModelThatSupportsBiasing() {
        XCTAssertEqual(ProviderKind.deepgram.defaultModel, "nova-3")
    }

    func testRecognitionBackendsAreFlaggedAsSuch() {
        XCTAssertTrue(ProviderKind.deepgram.isSpeechRecognition)
        XCTAssertTrue(ProviderKind.xai.isSpeechRecognition)
        XCTAssertTrue(ProviderKind.mistral.isSpeechRecognition)
        XCTAssertFalse(ProviderKind.google.isSpeechRecognition)
        XCTAssertFalse(ProviderKind.openrouter.isSpeechRecognition)
    }

    func testFactoryBuildsBothFromTheEnvironment() throws {
        let deepgram = try ProviderFactory.make(
            .deepgram, environment: ["DEEPGRAM_API_KEY": "k"])
        XCTAssertEqual(deepgram.name, "deepgram")

        let xai = try ProviderFactory.make(.xai, environment: ["XAI_API_KEY": "k"])
        XCTAssertEqual(xai.name, "xai")

        // The name this provider was first written against still works, so a shell that already
        // has the key under it does not look like a missing key.
        let legacy = try ProviderFactory.make(.xai, environment: ["GROK_API_KEY": "k"])
        XCTAssertEqual(legacy.name, "xai")

        let mistral = try ProviderFactory.make(.mistral, environment: ["MISTRAL_API_KEY": "k"])
        XCTAssertEqual(mistral.name, "mistral")
    }

    /// The list the app resolves a key from and the list the factory accepts have to be one list.
    /// While they were two, a shell holding only `GROK_API_KEY` was told it had no key — by an app
    /// that would have used that key without complaint had it ever got as far as the factory.
    func testEveryAdvertisedVariableActuallyBuildsAProvider() throws {
        for kind in ProviderKind.allCases {
            XCTAssertEqual(kind.apiKeyEnvVars.first, kind.apiKeyEnvVar)
            for name in kind.apiKeyEnvVars {
                let provider = try ProviderFactory.make(kind, environment: [name: "k"])
                XCTAssertEqual(
                    provider.name, kind.rawValue, "\(name) must be accepted for \(kind.rawValue)")
            }
        }
    }

    func testMissingKeyNamesTheVariableToSet() {
        XCTAssertThrowsError(try ProviderFactory.make(.deepgram, environment: [:])) { error in
            guard case ProviderError.missingAPIKey(let envVar) = error else {
                return XCTFail("expected missingAPIKey, got \(error)")
            }
            XCTAssertEqual(envVar, "DEEPGRAM_API_KEY")
        }
    }
}
