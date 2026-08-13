import XCTest

@testable import DoNotTypeCore

/// A provider that answers after a delay, or fails after one.
private struct SlowProvider: TranscriptionProvider {
    let name: String
    var delay: Duration
    var text: String
    var failure: (any Error)?

    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        try await Task.sleep(for: delay)
        try Task.checkCancellation()
        if let failure { throw failure }
        return TranscriptionResult(
            transcript: Transcript(transcript: text, language: "en"),
            usage: TokenUsage(), rawOutput: text)
    }
}

final class FallbackTranscriberTests: XCTestCase {
    private let audio = AudioFile(data: Data("wav".utf8), mimeType: "audio/wav")

    private func service(
        _ name: String, delay: Duration, text: String, failure: (any Error)? = nil
    ) -> TranscriptionService {
        TranscriptionService(
            provider: SlowProvider(name: name, delay: delay, text: text, failure: failure),
            model: "\(name)-model", systemInstruction: "i")
    }

    /// The common case: the primary answers normally, so the hedge never fires and never bills.
    func testAFastPrimaryIsNeverSecondGuessed() async throws {
        let hedger = FallbackTranscriber(
            primary: service("primary", delay: .milliseconds(10), text: "primary"),
            secondary: service("secondary", delay: .milliseconds(10), text: "secondary"),
            hedgeAfter: .seconds(30))

        let outcome = try await hedger.transcribe(audio: audio, context: nil)

        XCTAssertEqual(outcome.result.transcript.transcript, "primary")
        XCTAssertFalse(outcome.attribution.wasFallback)
        XCTAssertEqual(outcome.attribution.provider, "primary")
    }

    /// The case this type exists for: the primary stalls, the hedge fires, the user gets words.
    func testAStalledPrimaryIsOvertakenByTheHedge() async throws {
        let hedger = FallbackTranscriber(
            primary: service("primary", delay: .seconds(30), text: "primary"),
            secondary: service("secondary", delay: .milliseconds(20), text: "secondary"),
            hedgeAfter: .milliseconds(20))

        let outcome = try await hedger.transcribe(audio: audio, context: nil)

        XCTAssertEqual(outcome.result.transcript.transcript, "secondary")
        XCTAssertTrue(outcome.attribution.wasFallback, "the caller has to be able to say so")
        XCTAssertEqual(outcome.attribution.provider, "secondary")
    }

    /// Nothing to wait for: a primary that fails hands over rather than burning the hedge delay.
    func testAFailingPrimaryFallsBackWithoutWaitingOutTheDelay() async throws {
        let hedger = FallbackTranscriber(
            primary: service(
                "primary", delay: .milliseconds(5), text: "",
                failure: ProviderError.http(status: 500, body: "boom")),
            secondary: service("secondary", delay: .milliseconds(10), text: "secondary"),
            hedgeAfter: .milliseconds(20))

        let outcome = try await hedger.transcribe(audio: audio, context: nil)
        XCTAssertEqual(outcome.result.transcript.transcript, "secondary")
    }

    /// The primary's error is the one that explains the user's configuration, so it is the one
    /// they see when everything fails.
    func testWhenBothFailThePrimaryErrorSurfaces() async {
        let hedger = FallbackTranscriber(
            primary: service(
                "primary", delay: .milliseconds(5), text: "",
                failure: ProviderError.missingAPIKey(envVar: "PRIMARY_KEY")),
            secondary: service(
                "secondary", delay: .milliseconds(5), text: "",
                failure: ProviderError.http(status: 500, body: "boom")),
            hedgeAfter: .milliseconds(1))

        do {
            _ = try await hedger.transcribe(audio: audio, context: nil)
            XCTFail("expected a failure")
        } catch ProviderError.missingAPIKey(let envVar) {
            XCTAssertEqual(envVar, "PRIMARY_KEY")
        } catch {
            XCTFail("expected the primary's error, got \(error)")
        }
    }

    /// No secondary configured is the default, and must behave exactly as before this type existed.
    func testWithoutASecondaryItIsATransparentPassThrough() async throws {
        let hedger = FallbackTranscriber(
            primary: service("primary", delay: .milliseconds(5), text: "primary"))

        let outcome = try await hedger.transcribe(audio: audio, context: nil)
        XCTAssertEqual(outcome.result.transcript.transcript, "primary")
        XCTAssertFalse(outcome.attribution.wasFallback)
    }
}
