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
    private var sink: MemoryLogSink!

    /// The two spellings the hedge can log, repeated verbatim in each platform's test suite
    /// rather than shared from one file, per `docs/PARITY.md`.
    private enum HedgeLog {
        static let stalled = "primary stalled; starting the fallback"
        static let failed = "primary failed; starting the fallback"
    }

    override func setUp() {
        super.setUp()
        sink = MemoryLogSink()
        LogRouter.shared.install(sinks: [sink], level: .trace)
        LogRouter.shared.clearBuffer()
    }

    override func tearDown() {
        LogRouter.shared.install(sinks: [], level: .off)
        super.tearDown()
    }

    /// The line that announced the handover, which is the first thing the category logs.
    private var handoverLine: LogEvent? {
        sink.events.first { $0.category == "fallback" }
    }

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
    ///
    /// The delay is a realistic eight seconds and the elapsed time is asserted, because neither
    /// was true before and the gap that hid was a real one. With a 20 ms hedge and only the
    /// transcript checked, this test passed against an implementation that always slept the full
    /// delay: "secondary" comes back either way, just six seconds later. Which backend answered
    /// is not the claim being made here — *when* it started is.
    ///
    /// The failure is a 400 rather than a 500 so that `isTransient` is false and no retry backoff
    /// lands inside the measurement. That is also the shape of the failure this was written for:
    /// Gemini answering `HTTP 400: This API is not available in your current location` in about a
    /// second, after which there is nothing left to wait for.
    func testAFailingPrimaryFallsBackWithoutWaitingOutTheDelay() async throws {
        let hedger = FallbackTranscriber(
            primary: service(
                "primary", delay: .milliseconds(5), text: "",
                failure: ProviderError.http(status: 400, body: "location not supported")),
            secondary: service("secondary", delay: .milliseconds(10), text: "secondary"),
            hedgeAfter: .seconds(8))

        let clock = ContinuousClock()
        let started = clock.now
        let outcome = try await hedger.transcribe(audio: audio, context: nil)
        let elapsed = clock.now - started

        XCTAssertEqual(outcome.result.transcript.transcript, "secondary")
        XCTAssertTrue(outcome.attribution.wasFallback)
        XCTAssertLessThan(
            elapsed, .seconds(1),
            "the hedge waited out its delay after the primary had already failed")
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

    /// A stall and a failure are different problems, so the log has to name which one happened.
    ///
    /// "The primary is slow" and "the primary is broken" want opposite responses from whoever
    /// reads the log, and for as long as both said "stalled" the log pointed at the wrong one.
    func testAStalledPrimaryIsLoggedAsAStall() async throws {
        let hedger = FallbackTranscriber(
            primary: service("primary", delay: .seconds(30), text: "primary"),
            secondary: service("secondary", delay: .milliseconds(10), text: "secondary"),
            hedgeAfter: .milliseconds(20))

        _ = try await hedger.transcribe(audio: audio, context: nil)

        XCTAssertEqual(handoverLine?.message, HedgeLog.stalled)
        XCTAssertEqual(handoverLine?.fields["primary"], "primary")
        XCTAssertEqual(handoverLine?.fields["fallback"], "secondary")
        XCTAssertEqual(handoverLine?.fields["afterMs"], "20")
    }

    /// The delay is deliberately absent: nothing waited it out, so reporting it would describe a
    /// wait that never happened. That is exactly what the old single message did.
    func testAFailedPrimaryIsLoggedAsAFailureAndReportsNoDelay() async throws {
        let hedger = FallbackTranscriber(
            primary: service(
                "primary", delay: .milliseconds(5), text: "",
                failure: ProviderError.http(status: 400, body: "location not supported")),
            secondary: service("secondary", delay: .milliseconds(10), text: "secondary"),
            hedgeAfter: .seconds(8))

        _ = try await hedger.transcribe(audio: audio, context: nil)

        XCTAssertEqual(handoverLine?.message, HedgeLog.failed)
        XCTAssertEqual(handoverLine?.fields["primary"], "primary")
        XCTAssertEqual(handoverLine?.fields["fallback"], "secondary")
        XCTAssertNil(handoverLine?.fields["afterMs"], "nothing waited, so there is no delay")
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
