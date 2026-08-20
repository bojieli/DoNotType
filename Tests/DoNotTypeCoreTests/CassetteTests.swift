import XCTest

@testable import DoNotTypeCore

/// A provider that answers differently each time, so a replay that flattened the variance would be
/// visible rather than plausible.
private final class CountingProvider: TranscriptionProvider, @unchecked Sendable {
    let name = "counting"
    private(set) var calls = 0

    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        calls += 1
        return TranscriptionResult(
            transcript: Transcript(transcript: "take \(calls)", language: "en"),
            usage: TokenUsage(audioTokens: 90 + calls),
            rawOutput: "take \(calls)")
    }
}

/// Recording a run once so it can be re-scored for free, without turning a cache into evidence.
final class CassetteTests: XCTestCase {
    private var directory: URL!
    private let audio = AudioFile(data: Data("pretend this is a wav".utf8), mimeType: "audio/wav")

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private func runner(
        _ provider: any TranscriptionProvider,
        mode: CassetteStore.Mode,
        instruction: String = "system instruction"
    ) -> EvalRunner {
        EvalRunner(
            provider: provider, model: "m", systemInstruction: instruction,
            cassette: mode == .live ? nil : CassetteStore(mode: mode))
    }

    private func provenance(_ instruction: String = "system instruction") -> Cassette.Provenance {
        Cassette.Provenance(
            provider: "counting", model: "m", fidelity: "light", recordedAt: Date(),
            promptDigest: CassetteKey.digest(of: instruction))
    }

    // MARK: - The round trip

    func testARecordedRunReplaysWithoutTheProvider() async throws {
        let file = directory.appendingPathComponent("cassette.json")
        let live = CountingProvider()
        let recording = runner(live, mode: .recording(file))
        try await recording.cassette?.open(provenance: provenance())

        let first = try await recording.transcribe(audio: audio, context: nil)
        try await recording.cassette?.close()

        XCTAssertEqual(live.calls, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        // A fresh provider that would fail the assertion if it were reached.
        let unused = CountingProvider()
        let replaying = runner(unused, mode: .replaying(file))
        try await replaying.cassette?.open(provenance: provenance())

        let replayed = try await replaying.transcribe(audio: audio, context: nil)
        XCTAssertEqual(replayed.transcript.transcript, first.transcript.transcript)
        XCTAssertEqual(replayed.usage.audioTokens, first.usage.audioTokens)
        XCTAssertEqual(unused.calls, 0, "replay must not touch the provider")
    }

    /// The suite's own noise floor is one of the numbers it reports. A cassette that answered the
    /// same request identically forever would report a spread of zero and look like a stable model.
    func testEveryTakeIsReplayedInOrderSoTheVarianceSurvives() async throws {
        let file = directory.appendingPathComponent("cassette.json")
        let live = CountingProvider()
        let recording = runner(live, mode: .recording(file))
        try await recording.cassette?.open(provenance: provenance())

        for _ in 0..<3 { _ = try await recording.transcribe(audio: audio, context: nil) }
        try await recording.cassette?.close()

        let replaying = runner(CountingProvider(), mode: .replaying(file))
        try await replaying.cassette?.open(provenance: provenance())

        var replayed: [String] = []
        for _ in 0..<3 {
            replayed.append(
                try await replaying.transcribe(audio: audio, context: nil).transcript.transcript)
        }
        XCTAssertEqual(replayed, ["take 1", "take 2", "take 3"])
    }

    /// Running out is allowed — replaying more passes than were recorded is a reasonable thing to
    /// do — but it must be reported, because it narrows the spread the reader is looking at.
    func testRunningOutOfTakesIsReportedRatherThanHidden() async throws {
        let file = directory.appendingPathComponent("cassette.json")
        let recording = runner(CountingProvider(), mode: .recording(file))
        try await recording.cassette?.open(provenance: provenance())
        _ = try await recording.transcribe(audio: audio, context: nil)
        try await recording.cassette?.close()

        let replaying = runner(CountingProvider(), mode: .replaying(file))
        let store = try XCTUnwrap(replaying.cassette)
        try await store.open(provenance: provenance())

        _ = try await replaying.transcribe(audio: audio, context: nil)
        var exhausted = await store.exhaustedKeys
        XCTAssertTrue(exhausted.isEmpty, "the first take was recorded, so nothing was reused")

        _ = try await replaying.transcribe(audio: audio, context: nil)
        exhausted = await store.exhaustedKeys
        XCTAssertEqual(exhausted.count, 1, "the second call reused a take and must say so")
    }

    // MARK: - The key

    /// The failure mode that would make this actively misleading: replaying a recording made with a
    /// different prompt, and reporting the numbers as though they described the new one.
    ///
    /// Caught at `open`, before any case runs, rather than per request. Both are refusals, but the
    /// difference decides whether anyone can act on it: an edited prompt misses *every* key, so the
    /// per-request version reported 48 identical "nothing recorded" errors for one fact. It also
    /// exited 0 while doing so, which is how a stale cassette held a CI job green for a week.
    func testAChangedPromptIsRefusedBeforeAnyCaseRuns() async throws {
        let file = directory.appendingPathComponent("cassette.json")
        let recording = runner(CountingProvider(), mode: .recording(file), instruction: "original")
        try await recording.cassette?.open(provenance: provenance("original"))
        _ = try await recording.transcribe(audio: audio, context: nil)
        try await recording.cassette?.close()

        let edited = runner(CountingProvider(), mode: .replaying(file), instruction: "edited")
        do {
            try await edited.cassette?.open(provenance: provenance("edited"))
            XCTFail("an edited prompt must not be answered from an old recording")
        } catch let error as CassetteStore.CassetteError {
            let message = error.errorDescription ?? ""
            XCTAssertTrue(
                message.contains("prompt"),
                "the error should explain why a prompt change misses, got: \(message)")
            XCTAssertTrue(
                message.contains("--record"),
                "the error should say how to fix it, got: \(message)")
        }
    }

    /// A model or fidelity change is the same failure wearing different clothes: both are hashed
    /// into every key, so both miss everything.
    func testAChangedModelIsRefusedTooAndNamesWhatMoved() async throws {
        let file = directory.appendingPathComponent("cassette.json")
        let recording = runner(CountingProvider(), mode: .recording(file))
        try await recording.cassette?.open(provenance: provenance())
        _ = try await recording.transcribe(audio: audio, context: nil)
        try await recording.cassette?.close()

        var moved = provenance()
        moved.model = "some-other-model"
        let store = CassetteStore(mode: .replaying(file))
        do {
            try await store.open(provenance: moved)
            XCTFail("a cassette recorded from another model must not be replayed")
        } catch let error as CassetteStore.CassetteError {
            let message = error.errorDescription ?? ""
            XCTAssertTrue(
                message.contains("m → some-other-model"),
                "the error must name what moved, got: \(message)")
        }
    }

    /// The provider deliberately does not invalidate a cassette: replay re-checks this project's
    /// scoring, not a backend's transcription, so a recording from one provider is legitimately
    /// re-scoreable under another name. Asserted because it looks like an oversight otherwise.
    func testADifferentProviderStillReplays() async throws {
        let file = directory.appendingPathComponent("cassette.json")
        let recording = runner(CountingProvider(), mode: .recording(file))
        try await recording.cassette?.open(provenance: provenance())
        _ = try await recording.transcribe(audio: audio, context: nil)
        try await recording.cassette?.close()

        var renamed = provenance()
        renamed.provider = "somebody-else"
        let store = CassetteStore(mode: .replaying(file))
        try await store.open(provenance: renamed)
        let replayed = try await store.take(for: onlyKey(in: file), hint: "no context")
        XCTAssertEqual(replayed.transcript.transcript, "take 1")
    }

    private func onlyKey(in file: URL) throws -> String {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let cassette = try decoder.decode(Cassette.self, from: try Data(contentsOf: file))
        return try XCTUnwrap(cassette.takes.keys.first)
    }

    /// The two arms of every case are different requests and must not share a recording.
    func testContextAndNoContextAreDifferentKeys() {
        let context = ScreenContext(appName: "Xcode", visibleText: String(repeating: "screen ", count: 60))
        let grounded = CassetteKey.make(
            model: "m", fidelity: .light, systemInstruction: "s", context: context,
            keyterms: [], audio: audio.data)
        let bare = CassetteKey.make(
            model: "m", fidelity: .light, systemInstruction: "s", context: nil,
            keyterms: [], audio: audio.data)
        XCTAssertNotEqual(grounded, bare)
    }

    func testEveryInputThatChangesTheAnswerChangesTheKey() {
        let base = CassetteKey.make(
            model: "m", fidelity: .light, systemInstruction: "s", context: nil,
            keyterms: [], audio: audio.data)

        let variants = [
            "model": CassetteKey.make(
                model: "other", fidelity: .light, systemInstruction: "s", context: nil,
                keyterms: [], audio: audio.data),
            "fidelity": CassetteKey.make(
                model: "m", fidelity: .tidy, systemInstruction: "s", context: nil,
                keyterms: [], audio: audio.data),
            "prompt": CassetteKey.make(
                model: "m", fidelity: .light, systemInstruction: "different", context: nil,
                keyterms: [], audio: audio.data),
            "keyterms": CassetteKey.make(
                model: "m", fidelity: .light, systemInstruction: "s", context: nil,
                keyterms: ["Kaelith"], audio: audio.data),
            "audio": CassetteKey.make(
                model: "m", fidelity: .light, systemInstruction: "s", context: nil,
                keyterms: [], audio: Data("a different recording".utf8)),
        ]

        for (name, key) in variants {
            XCTAssertNotEqual(key, base, "\(name) must change the key")
        }
    }

    /// Recorded on one machine, replayed on another. The audio is Opus-compressed on the way out
    /// and libopus does not promise byte-identical output across versions, so keying on the encoded
    /// payload would make a committed cassette miss for everybody else.
    func testTheKeyIsStableAcrossRuns() {
        let first = CassetteKey.make(
            model: "m", fidelity: .light, systemInstruction: "s",
            context: ScreenContext(appName: "Xcode"), keyterms: [], audio: audio.data)
        let second = CassetteKey.make(
            model: "m", fidelity: .light, systemInstruction: "s",
            context: ScreenContext(appName: "Xcode"), keyterms: [], audio: audio.data)
        XCTAssertEqual(first, second)
    }

    // MARK: - Failure messages

    func testAMissingCassetteSaysHowToMakeOne() async {
        let missing = directory.appendingPathComponent("nope.json")
        let store = CassetteStore(mode: .replaying(missing))
        do {
            try await store.open(provenance: provenance())
            XCTFail("replaying a file that is not there must fail")
        } catch let error as CassetteStore.CassetteError {
            let message = error.errorDescription ?? ""
            XCTAssertTrue(message.contains("--record"), "got: \(message)")
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    /// The file is committed, so a reviewer has to be able to read a diff of it.
    func testTheFileIsSortedAndReadable() async throws {
        let file = directory.appendingPathComponent("cassette.json")
        let recording = runner(CountingProvider(), mode: .recording(file))
        try await recording.cassette?.open(provenance: provenance())
        _ = try await recording.transcribe(audio: audio, context: nil)
        try await recording.cassette?.close()

        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains("\n"), "pretty printed, not one line")
        XCTAssertTrue(text.contains("provenance"))
        XCTAssertTrue(text.contains("promptDigest"), "a changed prompt should show in a diff")
        XCTAssertTrue(text.contains("take 1"))
    }
}
