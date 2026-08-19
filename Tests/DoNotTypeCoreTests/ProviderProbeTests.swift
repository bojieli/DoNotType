import XCTest

@testable import DoNotTypeCore

/// A provider that answers however the test wants, and remembers what it was asked.
private final class ScriptedProvider: TranscriptionProvider, @unchecked Sendable {
    let name = "scripted"
    private let support: GroundingSupport
    private let answer: (any Error)?
    private(set) var lastRequest: TranscriptionRequest?

    init(grounding: GroundingSupport = .multimodal, throws answer: (any Error)? = nil) {
        self.support = grounding
        self.answer = answer
    }

    func grounding(forModel model: String) -> GroundingSupport { support }

    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        lastRequest = request
        if let answer { throw answer }
        return TranscriptionResult(
            transcript: Transcript(transcript: "ok", language: "en"), usage: TokenUsage(),
            rawOutput: "ok")
    }
}

/// The check that turns a broken key from a lost dictation into a setting with a warning on it.
///
/// Its one job that is easy to get wrong: never report "your key is bad" when the truth is "I
/// could not ask". A settings window that opens itself on every flaky network is a settings window
/// people close without reading.
final class ProviderProbeTests: XCTestCase {
    func testASuccessfulRoundTripAcceptsTheKey() async {
        let outcome = await ProviderProbe.check(ScriptedProvider(), model: "m")
        XCTAssertEqual(outcome, .accepted)
    }

    /// The recognition path probes with silence, and silence correctly transcribes to nothing.
    /// Treating that as a failure would report every working recogniser as broken.
    func testSilenceTranscribingToNothingStillProvesTheKeyWorks() async {
        let provider = ScriptedProvider(
            grounding: .none, throws: ProviderError.emptyOutput)
        let outcome = await ProviderProbe.check(provider, model: "m")
        XCTAssertEqual(outcome, .accepted)
    }

    func testARejectedKeyIsReportedAsSomethingToFix() async {
        for status in [401, 403] {
            let provider = ScriptedProvider(
                throws: ProviderError.http(status: status, body: "nope"))
            guard case .rejected = await ProviderProbe.check(provider, model: "m") else {
                return XCTFail("HTTP \(status) must be reported as a rejected key")
            }
        }
    }

    /// A model this account cannot use fails at exactly the same moment a bad key does, so it is
    /// worth catching in the same check.
    func testAnUnavailableModelIsAlsoSomethingToFix() async {
        let provider = ScriptedProvider(throws: ProviderError.http(status: 404, body: "no model"))
        guard case .rejected = await ProviderProbe.check(provider, model: "m") else {
            return XCTFail("an unavailable model must be reported, not swallowed")
        }
    }

    func testNoAnswerIsNeverReportedAsABadKey() async {
        let cases: [any Error] = [
            ProviderError.http(status: 500, body: "server on fire"),
            ProviderError.http(status: 429, body: "slow down"),
            URLError(.notConnectedToInternet),
            URLError(.timedOut),
        ]
        for error in cases {
            let outcome = await ProviderProbe.check(ScriptedProvider(throws: error), model: "m")
            guard case .inconclusive = outcome else {
                return XCTFail("\(error) says nothing about the key, but reported \(outcome)")
            }
        }
    }

    /// Every backend, not just the recognisers that always got this. A model backend probed with
    /// text answers from a code path a dictation never uses, so the one thing that could be wrong
    /// with a third-party endpoint — that it takes the request shape but not the recording — was
    /// the one thing the check could not see.
    func testEveryBackendIsProbedWithAudioAndNothingElse() async {
        let groundings: [GroundingSupport] = [
            .multimodal, .keyterms(maxTerms: 100, maxCharsPerTerm: 50), .none,
        ]
        for grounding in groundings {
            let provider = ScriptedProvider(grounding: grounding)
            _ = await ProviderProbe.check(provider, model: "m")

            let parts = provider.lastRequest?.parts ?? []
            XCTAssertTrue(
                parts.contains { if case .audio = $0 { true } else { false } },
                "\(grounding) was probed without a recording")
            XCTAssertFalse(
                parts.contains { if case .text = $0 { true } else { false } },
                "\(grounding) was probed with text a dictation would never send")
        }
    }

    /// The point of probing with audio. A provider that takes the recording, drops it and bills
    /// nothing for it throws this from inside `transcribe`, and the probe has to report it as
    /// something the user must fix — not as a flaky network to be retried.
    func testAnEndpointThatDropsTheRecordingIsRejected() async {
        let provider = ScriptedProvider(
            throws: ProviderError.audioSilentlyDropped(provider: "relay", model: "m"))
        guard case .rejected(let message) = await ProviderProbe.check(provider, model: "m") else {
            return XCTFail("an endpoint that drops audio must be reported, not accepted")
        }
        XCTAssertTrue(message.contains("audio"), "the message has to name what went wrong")
        XCTAssertFalse(TranscriptionService.isTransient(
            ProviderError.audioSilentlyDropped(provider: "relay", model: "m")))
    }

    /// A text-only endpoint that refuses the recording outright is the good case, and it has to
    /// land in the same bucket as the one that drops it quietly.
    func testAnEndpointThatRefusesAudioIsRejected() async {
        let provider = ScriptedProvider(
            throws: ProviderError.http(status: 400, body: "input_audio is not supported"))
        guard case .rejected = await ProviderProbe.check(provider, model: "m") else {
            return XCTFail("a refused recording must be reported as something to fix")
        }
    }
}
