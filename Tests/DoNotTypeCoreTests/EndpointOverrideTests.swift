import XCTest

@testable import DoNotTypeCore

/// Pointing a backend at a URL somebody else runs.
///
/// This was reachable for exactly one backend, only through `DNT_LOCAL_BASE_URL`, and only in a
/// process that inherits a shell environment — which a menu-bar app opened from Finder does not.
/// So the documented way to use a compatible third-party service did not work for the people most
/// likely to want it.
final class EndpointOverrideTests: XCTestCase {

    private let key = ["GEMINI_API_KEY": "k", "OPENROUTER_API_KEY": "k", "XAI_API_KEY": "k",
                       "DEEPGRAM_API_KEY": "k", "MISTRAL_API_KEY": "k"]

    /// Every backend takes one. "I want to use a mirror of this API" is not a wish specific to any
    /// of them, and a per-backend allowlist would be a list somebody has to remember to extend.
    func testEveryBackendAcceptsAnEndpointOverride() throws {
        let mirror = "https://mirror.example.com/v1/transcribe"
        for kind in ProviderKind.allCases {
            let provider = try ProviderFactory.make(kind, endpoint: mirror, environment: key)
            XCTAssertEqual(
                provider.endpointOrigin?.absoluteString, "https://mirror.example.com/",
                "\(kind.rawValue) ignored the endpoint it was given")
        }
    }

    /// The default is what it always was, so an install that has never touched this setting sends
    /// its audio exactly where it used to.
    func testNoOverrideKeepsTheBuiltInEndpoint() throws {
        let google = try ProviderFactory.make(.google, environment: key)
        XCTAssertEqual(
            google.endpointOrigin?.absoluteString, "https://generativelanguage.googleapis.com/")

        let xai = try ProviderFactory.make(.xai, environment: key)
        XCTAssertEqual(xai.endpointOrigin?.absoluteString, "https://api.x.ai/")
    }

    /// Empty and whitespace mean "unset", because that is what an emptied text field produces and
    /// it must not be read as a URL.
    func testAnEmptyOverrideIsNotAnEndpoint() throws {
        for blank in ["", "   ", "\n"] {
            let provider = try ProviderFactory.make(.google, endpoint: blank, environment: key)
            XCTAssertEqual(
                provider.endpointOrigin?.absoluteString,
                "https://generativelanguage.googleapis.com/",
                "a blank field must not be treated as a URL")
        }
    }

    /// Falling back would send the recording to a different recipient than the user configured.
    /// Refuse it before reading or sending the audio instead.
    func testAnUnparseableOverrideFailsExplicitly() {
        XCTAssertThrowsError(
            try ProviderFactory.make(.google, endpoint: "not a url at all", environment: key)
        ) { error in
            guard case ProviderError.invalidEndpoint = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertFalse(TranscriptionService.isTransient(error))
            let guidance = FailureAdvice.describe(error)
            XCTAssertTrue(guidance.needsUserAction)
            XCTAssertFalse(guidance.isQueued)
        }
    }

    /// Credential-bearing remote providers must not send keys or recordings in cleartext. A local
    /// model keeps HTTP because localhost and LAN serving surfaces commonly have no TLS at all.
    func testOnlyTheLocalProviderAcceptsPlainHTTP() throws {
        XCTAssertThrowsError(
            try ProviderFactory.make(
                .google, endpoint: "http://mirror.example.com/v1", environment: key))

        let local = try ProviderFactory.make(
            .local, endpoint: "http://127.0.0.1:8000/v1/chat/completions", environment: key)
        XCTAssertEqual(local.endpointOrigin?.absoluteString, "http://127.0.0.1:8000/")
    }

    func testEndpointCredentialsAreRejected() {
        XCTAssertThrowsError(
            try ProviderFactory.make(
                .google, endpoint: "https://user:secret@mirror.example.com/v1", environment: key))
    }

    func testAnEmptyLocalEnvironmentEndpointFailsWithoutCrashing() {
        XCTAssertThrowsError(
            try ProviderFactory.make(.local, environment: ["DNT_LOCAL_BASE_URL": ""])) { error in
                guard case ProviderError.invalidEndpoint = error else {
                    return XCTFail("unexpected error: \(error)")
                }
        }
    }

    /// The placeholder the settings field shows has to be the URL that is actually used, or it
    /// documents something the app does not do.
    func testTheAdvertisedDefaultIsTheOneUsed() throws {
        for kind in ProviderKind.allCases {
            let provider = try ProviderFactory.make(kind, environment: key)
            let advertised = URL(string: kind.defaultEndpoint)?.origin?.absoluteString
            XCTAssertEqual(
                provider.endpointOrigin?.absoluteString, advertised,
                "\(kind.rawValue)'s advertised default endpoint is not where it posts")
        }
    }

    /// The key path callers actually use, which resolves the key and the endpoint together.
    func testTheKeyedFactoryForwardsTheEndpoint() throws {
        let provider = try ProviderFactory.make(
            .openrouter, apiKey: "k", endpoint: "https://gateway.example.com/v1/chat/completions",
            environment: [:])
        XCTAssertEqual(provider.endpointOrigin?.absoluteString, "https://gateway.example.com/")
    }

    /// A recogniser's override points at its *audio* endpoint. Sending a chat request there would
    /// fail for a reason nobody could read off the setting, so the second stage keeps its own URL.
    func testARecognisersOverrideDoesNotRedirectItsRewriteEndpoint() throws {
        let text = try ProviderFactory.makeTextProvider(
            .xai, apiKey: "k", endpoint: "https://mirror.example.com/v1/stt", environment: key)
        XCTAssertEqual(text?.endpointOrigin?.absoluteString, "https://api.x.ai/")
    }

    // MARK: - The audio-input caveat

    /// The note appears exactly when a model backend has been pointed somewhere unmeasured.
    ///
    /// Asserted per backend rather than spot-checked, because the cost of getting this wrong runs
    /// both ways: silence on a text-only relay is the failure the note exists to prevent, and a
    /// warning on an untouched default is the kind of noise that teaches people to skip the whole
    /// block of explanations it sits in.
    func testTheAudioCaveatAppearsOnlyForAModelBackendPointedElsewhere() {
        let mirror = "https://mirror.example.com/v1/chat/completions"
        for kind in ProviderKind.allCases {
            // A recogniser's entire API is the recording, so a mirror of one that could not carry
            // audio would not be a mirror of it. Nothing to say, at any endpoint.
            guard !kind.isSpeechRecognition else {
                XCTAssertNil(kind.thirdPartyAudioNote(endpointOverride: mirror))
                XCTAssertNil(kind.thirdPartyAudioNote(endpointOverride: ""))
                continue
            }
            XCTAssertNotNil(
                kind.thirdPartyAudioNote(endpointOverride: mirror),
                "\(kind.rawValue) forwards audio to a URL nobody here has measured, silently")
            // `.local` is always somebody else's server; the others are only once told to be.
            XCTAssertEqual(
                kind.thirdPartyAudioNote(endpointOverride: "") != nil, kind == .local,
                "\(kind.rawValue) disagrees about whether its default is a third party")
        }
    }

    /// `.local` is the exception, and the one most likely to hit this: `vllm serve` in front of a
    /// text-only checkpoint speaks the same API and has nowhere to put the recording.
    func testTheLocalBackendCarriesTheCaveatWithNoOverrideAtAll() {
        XCTAssertNotNil(ProviderKind.local.thirdPartyAudioNote(endpointOverride: ""))
        XCTAssertNil(ProviderKind.google.thirdPartyAudioNote(endpointOverride: ""))
    }

    /// The same rule the factory applies: an emptied field is unset, not a URL. Otherwise a user
    /// who cleared the field would keep a warning about a server they no longer use.
    func testAWhitespaceOverrideDoesNotRaiseTheCaveat() {
        for blank in ["", "   ", "\n"] {
            XCTAssertNil(ProviderKind.google.thirdPartyAudioNote(endpointOverride: blank))
        }
    }

    /// What the note has to say to be worth its space, and the claim in it that can decay
    /// silently: that the connection test sends a recording. It said the opposite until the probe
    /// was changed to send one, and a sentence describing the wrong probe is worse than no
    /// sentence — it tells people the check they just passed proves less than it does.
    func testTheCaveatNamesAudioAndDescribesWhatTheConnectionTestActuallySends() async throws {
        let note = try XCTUnwrap(
            ProviderKind.openrouter.thirdPartyAudioNote(
                endpointOverride: "https://mirror.example.com/v1/chat/completions"))
        XCTAssertTrue(note.contains("audio input"))
        XCTAssertTrue(note.contains("sends a real recording"))

        // The behaviour the sentence describes, asserted rather than trusted. `ProviderProbe`
        // decides this without consulting the backend, so one call covers every kind that can
        // show the note; `ProviderProbeTests` is where the grounding cases are enumerated.
        let recorder = RequestRecorder(grounding: .multimodal)
        _ = await ProviderProbe.check(recorder, model: ProviderKind.openrouter.defaultModel)
        XCTAssertTrue(
            (recorder.lastRequest?.parts ?? []).contains {
                if case .audio = $0 { true } else { false }
            },
            "the probe sends no recording, so the note now overpromises")
    }
}

/// Answers anything, and remembers what it was asked.
private final class RequestRecorder: TranscriptionProvider, @unchecked Sendable {
    let name = "recorder"
    private let support: GroundingSupport
    private(set) var lastRequest: TranscriptionRequest?

    init(grounding: GroundingSupport) { self.support = grounding }

    func grounding(forModel model: String) -> GroundingSupport { support }

    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        lastRequest = request
        return TranscriptionResult(
            transcript: Transcript(transcript: "ok", language: "en"), usage: TokenUsage(),
            rawOutput: "ok")
    }
}
