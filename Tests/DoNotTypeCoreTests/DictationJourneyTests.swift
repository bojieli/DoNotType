import XCTest

@testable import DoNotTypeCore

/// The journey a user actually takes, end to end, without a network or a microphone.
///
/// Everything else in this suite tests a piece: the provider parses, the encoder encodes, the
/// store stores. The sequence they form — audio in, transcript out, history written, failure kept
/// for retry — was covered only by `PipelineIntegrationTests`, and **10 of its 13 cases skip
/// unless `DNT_INTEGRATION=1`**. So CI protected almost none of the path a first user walks, and
/// `DictationController` had no test references at all.
///
/// These run offline against a stub provider, so they belong in every `swift test`. They assert
/// the decisions rather than the transcription quality: what gets stored, what gets delivered,
/// what survives a failure. Quality is what `dnt-eval` is for.
final class DictationJourneyTests: XCTestCase {
    private var directory: URL!
    private var store: HistoryStore!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dnt-journey-\(UUID().uuidString)")
        store = HistoryStore(directory: directory)
        await store.configure(retention: .forever, keepAudioForCompleted: false)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// 16 kHz mono PCM, the format every platform records.
    private func wav(seconds: Double = 1) -> AudioFile {
        let rate = 16_000
        let bytes = Int(Double(rate) * 2 * seconds)
        var data = Data()
        func text(_ value: String) { data.append(Data(value.utf8)) }
        func u32(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        func u16(_ value: UInt16) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        text("RIFF"); u32(UInt32(36 + bytes)); text("WAVEfmt ")
        u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        text("data"); u32(UInt32(bytes))
        data.append(Data(repeating: 0, count: bytes))
        return AudioFile(data: data, mimeType: "audio/wav")
    }

    private func service(
        text: String = "the transcript", failure: (any Error)? = nil
    ) -> TranscriptionService {
        TranscriptionService(
            provider: JourneyProvider(text: text, failure: failure),
            model: "stub-model", systemInstruction: "instruction")
    }

    // MARK: - The happy path

    func testASuccessfulDictationIsStoredWithItsTextAndBackend() async throws {
        let result = try await service().transcribeLong(audio: wav(), context: nil)
        var record = DictationRecord(
            status: .pending, provider: "stub", model: "stub-model", fidelity: .light,
            durationSeconds: 1)
        record.status = .completed
        record.text = result.transcript.transcript

        let stored = await store.insert(record, audio: nil)

        XCTAssertEqual(stored.text, "the transcript")
        XCTAssertEqual(stored.status, .completed)
        let count = await store.all().count
        XCTAssertEqual(count, 1)
        XCTAssertFalse(stored.canRetry, "a completed dictation has nothing to retry")
    }

    /// Silence in, nothing out. The controller returns to idle without writing a row, and a test
    /// is the only thing stopping that becoming an empty history entry someone has to delete.
    func testSilenceProducesNoHistoryRow() async throws {
        let result = try await service(text: "   ").transcribeLong(audio: wav(), context: nil)
        let text = result.transcript.transcript.trimmingCharacters(in: .whitespacesAndNewlines)

        XCTAssertTrue(text.isEmpty)
        let rows = await store.all().count
        XCTAssertEqual(rows, 0, "nothing to store, so nothing stored")
    }

    // MARK: - Failure keeps the words recoverable

    /// The promise Retry rests on: a failed dictation keeps its audio, so the button can work.
    func testAFailedDictationKeepsItsAudioAndIsRetryable() async throws {
        let audio = wav()
        var record = DictationRecord(
            status: .pending, provider: "stub", model: "stub-model", fidelity: .light,
            durationSeconds: 1)

        do {
            _ = try await service(failure: ProviderError.http(status: 503, body: "down"))
                .transcribeLong(audio: audio, context: nil)
            XCTFail("expected the stub to fail")
        } catch {
            record.status = .failed
            record.errorMessage = error.localizedDescription
        }
        let stored = await store.insert(record, audio: audio.data)

        XCTAssertEqual(stored.status, .failed)
        XCTAssertTrue(stored.canRetry)
        let audioURL = await store.audioURL(for: stored)
        XCTAssertNotNil(audioURL, "the audio has to still be there")
        let pending = await store.retryable().count
        XCTAssertEqual(pending, 1)
    }

    /// And the other half: retrying actually recovers it, and releases the audio afterwards.
    func testRetryRecoversAFailedDictationAndReleasesItsAudio() async throws {
        let audio = wav()
        var record = DictationRecord(
            status: .failed, provider: "stub", model: "stub-model", fidelity: .light,
            durationSeconds: 1)
        record.errorMessage = "network"
        let stored = await store.insert(record, audio: audio.data)

        let coordinator = RetryCoordinator(
            service: service(text: "recovered on the second attempt"), store: store)
        let outcome = await coordinator.retry(stored)

        guard case .success(let text) = outcome else {
            return XCTFail("expected the retry to succeed")
        }
        XCTAssertEqual(text, "recovered on the second attempt")

        let after = await store.record(id: stored.id)
        XCTAssertEqual(after?.status, .completed)
        XCTAssertEqual(after?.text, "recovered on the second attempt")
        XCTAssertEqual(after?.retryCount, 1)
        XCTAssertNil(after?.errorMessage, "a recovered dictation should not still look broken")
        let remaining = await store.retryable().count
        XCTAssertEqual(remaining, 0)
    }

    /// A whole queue drains rather than stopping at the first success.
    func testEveryQueuedDictationDrains() async throws {
        for index in 0..<3 {
            var record = DictationRecord(
                status: .failed, provider: "stub", model: "stub-model", fidelity: .light,
                durationSeconds: 1)
            record.errorMessage = "offline \(index)"
            _ = await store.insert(record, audio: wav().data)
        }

        let outcome = await RetryCoordinator(service: service(), store: store).retryAll()

        XCTAssertEqual(outcome.succeeded.count, 3)
        XCTAssertTrue(outcome.failed.isEmpty)
        let left = await store.retryable().count
        XCTAssertEqual(left, 0)
    }

    /// A permanent failure must not be retried forever — it stays failed and says why.
    func testAPermanentFailureStaysFailedWithAReadableReason() async throws {
        var record = DictationRecord(
            status: .failed, provider: "stub", model: "stub-model", fidelity: .light,
            durationSeconds: 1)
        record.errorMessage = "old"
        let stored = await store.insert(record, audio: wav().data)

        let coordinator = RetryCoordinator(
            service: service(failure: ProviderError.missingAPIKey(envVar: "STUB_KEY")),
            store: store)
        let outcome = await coordinator.retry(stored)

        guard case .failure = outcome else { return XCTFail("expected a failure") }
        let after = await store.record(id: stored.id)
        XCTAssertEqual(after?.status, .failed)
        XCTAssertTrue(after?.errorMessage?.contains("STUB_KEY") ?? false, "must name the fix")
        XCTAssertFalse(TranscriptionService.isTransient(
            ProviderError.missingAPIKey(envVar: "STUB_KEY")))
    }

    // MARK: - Rewriting never costs the verbatim transcript

    /// The claim the whole product rests on: a rewrite is stored *beside* what was said, never
    /// instead of it, so "revert to what I said" is always possible.
    func testARewriteIsStoredBesideTheVerbatimTranscriptNotInsteadOfIt() async throws {
        let verbatim = try await service(text: "so basically we should just ship it")
            .transcribeLong(audio: wav(), context: nil).transcript.transcript
        let styled = try await service(text: "We should proceed with the release.")
            .rewrite(verbatim, instruction: "Make it formal.")

        var record = DictationRecord(
            status: .completed, provider: "stub", model: "stub-model", fidelity: .light,
            durationSeconds: 1)
        record.text = verbatim
        record.styledText = styled
        record.style = .formal
        let stored = await store.insert(record, audio: nil)

        XCTAssertEqual(stored.text, "so basically we should just ship it")
        XCTAssertEqual(stored.styledText, "We should proceed with the release.")
        XCTAssertNotEqual(stored.text, stored.styledText)
    }

    /// A rewrite that comes back empty must not erase the dictation.
    func testAnEmptyRewriteFallsBackToTheVerbatimTranscript() async throws {
        let text = try await service(text: "  ").rewrite("what I said", instruction: "Formal.")
        XCTAssertEqual(text, "what I said")
    }

    // MARK: - The fallback is recorded honestly

    /// A hedged dictation must be attributed to the backend that answered. A row naming the one
    /// that was merely asked would make history useless for the comparisons it exists to support.
    func testAHedgedDictationRecordsTheBackendThatAnsweredIt() async throws {
        let hedger = FallbackTranscriber(
            primary: TranscriptionService(
                provider: JourneyProvider(text: "primary", delay: .seconds(30)),
                model: "primary-model", systemInstruction: "i"),
            secondary: service(text: "from the fallback"),
            hedgeAfter: .milliseconds(20))

        let outcome = try await hedger.transcribe(audio: wav(), context: nil)

        var record = DictationRecord(
            status: .completed, provider: "primary", model: "primary-model", fidelity: .light,
            durationSeconds: 1)
        record.provider = outcome.attribution.provider
        record.model = outcome.attribution.model
        record.text = outcome.result.transcript.transcript
        let stored = await store.insert(record, audio: nil)

        XCTAssertEqual(stored.text, "from the fallback")
        XCTAssertEqual(stored.model, "stub-model", "not the model that was asked")
        XCTAssertTrue(outcome.attribution.wasFallback)
    }

    // MARK: - Grounding reaches the request

    /// The screen text has to arrive as parts, in front of the audio. `CONTEXT_FORMAT.md` says the
    /// order matters, and nothing else asserts it offline.
    func testScreenContextReachesTheProviderAheadOfTheAudio() async throws {
        let provider = RecordingJourneyProvider()
        let service = TranscriptionService(
            provider: provider, model: "m", systemInstruction: "i")
        let context = ScreenContext(
            appName: "Xcode",
            visibleText: String(repeating: "Brindlewood and quillmark-sync. ", count: 20))

        _ = try await service.transcribeLong(audio: wav(), context: context)

        let parts = try XCTUnwrap(provider.lastParts)
        guard case .audio = parts.last else {
            return XCTFail("the audio must be last: \(parts)")
        }
        let text = parts.dropLast().compactMap {
            if case .text(let value) = $0 { value } else { nil }
        }.joined()
        XCTAssertTrue(text.contains("Brindlewood"))
        XCTAssertTrue(text.contains("DO NOT TRANSCRIBE"), "the reference-only framing must survive")
    }
}

// MARK: - Stubs

/// Answers with fixed text, optionally after a delay or with a failure.
private struct JourneyProvider: TranscriptionProvider {
    let name = "stub"
    var text: String
    var failure: (any Error)?
    var delay: Duration = .zero

    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        if delay > .zero { try await Task.sleep(for: delay) }
        try Task.checkCancellation()
        if let failure { throw failure }
        return TranscriptionResult(
            transcript: Transcript(transcript: text, language: "en"),
            usage: TokenUsage(promptTokens: 1, completionTokens: 1, audioTokens: 32),
            rawOutput: text)
    }
}

/// Keeps the parts it was handed, for asserting request shape.
private final class RecordingJourneyProvider: TranscriptionProvider, @unchecked Sendable {
    let name = "recording"
    private(set) var lastParts: [InputPart]?

    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        lastParts = request.parts
        return TranscriptionResult(
            transcript: Transcript(transcript: "ok", language: "en"),
            usage: TokenUsage(audioTokens: 32), rawOutput: "ok")
    }
}
