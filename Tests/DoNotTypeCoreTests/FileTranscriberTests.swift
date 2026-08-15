import XCTest

@testable import DoNotTypeCore

/// A provider that answers differently depending on whether it was given audio, so a test can tell
/// the transcription request apart from the second-stage one.
private final class TwoStageProvider: TranscriptionProvider, @unchecked Sendable {
    let name: String
    private let support: GroundingSupport
    private(set) var requests: [TranscriptionRequest] = []
    var transcript = "I said the version is three point five, and Kaelith owns the rollout."
    var derived = "Version 3.5. Kaelith owns the rollout."

    init(name: String = "stub", grounding: GroundingSupport = .multimodal) {
        self.name = name
        self.support = grounding
    }

    func grounding(forModel model: String) -> GroundingSupport { support }

    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        requests.append(request)
        // A recogniser has no text channel at all; asking it to rewrite is the error, not a
        // fallback. Mirrors what the real backends do.
        if !request.containsAudio, support != .multimodal {
            throw ProviderError.audioRequired(provider: name)
        }
        let text = request.containsAudio ? transcript : derived
        return TranscriptionResult(
            transcript: Transcript(transcript: text, language: "en"),
            usage: TokenUsage(promptTokens: 10, completionTokens: 5, audioTokens: 96),
            rawOutput: text)
    }

    var audioRequests: [TranscriptionRequest] { requests.filter(\.containsAudio) }
    var textRequests: [TranscriptionRequest] { requests.filter { !$0.containsAudio } }
}

/// The offline path: a recording on disk, in every mode, including the ways it must refuse.
final class FileTranscriberTests: XCTestCase {
    private var recording: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Two seconds of 16 kHz mono silence, in a real WAV container — enough for the decoder's
        // already-in-target-format path and for a duration to be read back.
        let pcm = Data(count: 16_000 * 2 * 2)
        let wav = AudioChunker.wrapInWavContainer(pcm, format: AudioChunker.Format())
        recording = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).wav")
        try wav.write(to: recording)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: recording)
        try super.tearDownWithError()
    }

    private var prompt: PromptBuilder {
        try! PromptBuilder(contentsOf: PromptBuilder.findPromptFile()!)
    }

    private func transcriber(
        provider: TwoStageProvider, secondStage: TwoStageProvider? = nil
    ) -> FileTranscriber {
        FileTranscriber(
            service: TranscriptionService(
                provider: provider, model: "m", systemInstruction: "system"),
            prompt: prompt,
            fidelity: .light,
            secondStage: secondStage.map {
                TranscriptionService(provider: $0, model: "m2", systemInstruction: "system")
            })
    }

    // MARK: - Verbatim

    func testVerbatimMakesExactlyOneRequestAndKeepsTheWords() async throws {
        let provider = TwoStageProvider()
        let outcome = try await transcriber(provider: provider).transcribe(fileAt: recording)

        XCTAssertEqual(provider.requests.count, 1, "verbatim must not pay for a second pass")
        XCTAssertEqual(outcome.verbatim, provider.transcript)
        XCTAssertEqual(outcome.delivered, outcome.verbatim)
        XCTAssertEqual(outcome.mode, .verbatim)
        XCTAssertEqual(outcome.durationSeconds ?? 0, 2, accuracy: 0.01)
    }

    // MARK: - Second stages

    func testSummaryKeepsTheVerbatimTranscriptAlongsideIt() async throws {
        let provider = TwoStageProvider()
        let outcome = try await transcriber(provider: provider)
            .transcribe(fileAt: recording, mode: .summary(.bullets))

        XCTAssertEqual(outcome.delivered, provider.derived)
        XCTAssertEqual(
            outcome.verbatim, provider.transcript,
            "the words behind a summary must survive it")
        XCTAssertEqual(provider.textRequests.count, 1)
        XCTAssertNotNil(outcome.secondStageSeconds)
    }

    func testSummaryUsesTheSummaryBlockAndRewriteUsesTheRewriteBlock() async throws {
        let summarising = TwoStageProvider()
        _ = try await transcriber(provider: summarising)
            .transcribe(fileAt: recording, mode: .summary(.actions))
        let summaryInstruction = try XCTUnwrap(summarising.textRequests.first?.systemInstruction)

        let rewriting = TwoStageProvider()
        _ = try await transcriber(provider: rewriting)
            .transcribe(fileAt: recording, mode: .rewrite(.formal))
        let rewriteInstruction = try XCTUnwrap(rewriting.textRequests.first?.systemInstruction)

        XCTAssertNotEqual(summaryInstruction, rewriteInstruction)
        XCTAssertEqual(summaryInstruction, try prompt.summaryInstruction(style: .actions))
        XCTAssertEqual(rewriteInstruction, try prompt.rewriteInstruction(style: .formal))
    }

    /// Silence in, nothing out. Handing an empty transcript to a summariser is the one place this
    /// pipeline could produce words nobody said.
    func testEmptyTranscriptSkipsTheSecondStageEntirely() async throws {
        let provider = TwoStageProvider()
        provider.transcript = "   "
        let outcome = try await transcriber(provider: provider)
            .transcribe(fileAt: recording, mode: .summary(.brief))

        XCTAssertTrue(outcome.delivered.isEmpty)
        XCTAssertTrue(provider.textRequests.isEmpty, "nothing to summarise means no request")
        XCTAssertNil(outcome.secondStageSeconds)
    }

    // MARK: - Recognition backends

    func testRecogniserRefusesSecondStageModesUpFront() async throws {
        let recogniser = TwoStageProvider(name: "xai", grounding: .none)
        let subject = transcriber(provider: recogniser)

        XCTAssertTrue(subject.supports(.verbatim))
        XCTAssertFalse(subject.supports(.summary(.brief)))
        XCTAssertFalse(subject.supports(.rewrite(.formal)))

        do {
            _ = try await subject.transcribe(fileAt: recording, mode: .summary(.brief))
            XCTFail("a recogniser cannot summarise and must say so before uploading anything")
        } catch let error as ProviderError {
            guard case .audioRequired = error else { return XCTFail("wrong error: \(error)") }
            XCTAssertTrue(recogniser.requests.isEmpty, "it must refuse before spending the audio")
        }
    }

    /// The pairing that makes `--mode summary --provider xai` work: the fast recogniser transcribes,
    /// a model writes the summary.
    func testRecogniserPairedWithAModelSplitsTheWork() async throws {
        let recogniser = TwoStageProvider(name: "xai", grounding: .none)
        let model = TwoStageProvider(name: "gemini")
        let outcome = try await transcriber(provider: recogniser, secondStage: model)
            .transcribe(fileAt: recording, mode: .summary(.brief))

        XCTAssertEqual(recogniser.audioRequests.count, 1, "audio goes to the recogniser")
        XCTAssertTrue(recogniser.textRequests.isEmpty)
        XCTAssertEqual(model.textRequests.count, 1, "text goes to the model")
        XCTAssertTrue(model.audioRequests.isEmpty, "the model must not be billed for the audio")
        XCTAssertEqual(outcome.secondStageProvider, "gemini", "history has to say who wrote it")
        XCTAssertEqual(outcome.provider, "xai")
    }

    /// A model backend needs no second service, and adding one must not divert work away from it.
    func testModelBackendRunsBothStagesItself() async throws {
        let provider = TwoStageProvider()
        let outcome = try await transcriber(provider: provider)
            .transcribe(fileAt: recording, mode: .rewrite(.concise))
        XCTAssertNil(outcome.secondStageProvider, "nothing to report when one backend did it all")
        XCTAssertEqual(provider.requests.count, 2)
    }

    // MARK: - History

    func testHistoryRecordDescribesAnOfflineTranscription() async throws {
        let provider = TwoStageProvider()
        let outcome = try await transcriber(provider: provider)
            .transcribe(fileAt: recording, mode: .summary(.bullets))
        let record = outcome.historyRecord()

        XCTAssertEqual(record.status, .completed)
        XCTAssertEqual(record.text, provider.transcript, "the verbatim text is the stored text")
        XCTAssertEqual(record.styledText, provider.derived)
        XCTAssertEqual(record.mode, .summary(.bullets))
        XCTAssertNil(record.style, "a summary is not a rewrite style")
        XCTAssertEqual(record.sourceFileName, recording.lastPathComponent)
        XCTAssertEqual(record.deliveredText, provider.derived)
        XCTAssertEqual(record.usage?.audioTokens, 96)
    }

    func testProgressIsReportedForEveryStage() async throws {
        nonisolated(unsafe) var seen: [FileTranscriber.Progress] = []
        _ = try await transcriber(provider: TwoStageProvider()).transcribe(
            fileAt: recording, mode: .rewrite(.bullets),
            onProgress: { seen.append($0) })

        XCTAssertEqual(seen.first, .decoding(recording.lastPathComponent))
        XCTAssertTrue(seen.contains(.deriving(.rewrite(.bullets))))
    }

    func testMissingFileFailsBeforeAnyRequest() async {
        let provider = TwoStageProvider()
        let missing = recording.deletingLastPathComponent().appendingPathComponent("nope.wav")
        do {
            _ = try await transcriber(provider: provider).transcribe(fileAt: missing)
            XCTFail("a missing file must not reach the provider")
        } catch {
            XCTAssertTrue(provider.requests.isEmpty)
            XCTAssertTrue(
                error.localizedDescription.contains("Supported"),
                "the error should say what this app can read, got: \(error.localizedDescription)")
        }
    }
}

/// The decoder that lets any recording reach the pipeline.
/// What someone is told when the file is not a recording.
///
/// `docs/MANUAL-CHECKS.md` names the standard: the message should say what is wrong, not "The
/// operation couldn't be completed". CoreAudio's own answer is a four-character code printed as a
/// decimal, and every one of these used to produce it.
final class DecodeFailureMessageTests: XCTestCase {
    private var directory = URL(fileURLWithPath: "/tmp")

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func message(for url: URL) -> String {
        do {
            _ = try AudioDecoder.load(url)
            return "(it loaded)"
        } catch {
            return error.localizedDescription
        }
    }

    func testAFolderSaysItIsAFolder() {
        XCTAssertTrue(message(for: directory).contains("folder"), message(for: directory))
    }

    func testAnEmptyFileSaysItIsEmpty() throws {
        let url = directory.appendingPathComponent("cut-short.wav")
        try Data().write(to: url)
        XCTAssertTrue(message(for: url).contains("empty"), message(for: url))
    }

    func testSomethingThatIsNotAudioSaysSo() throws {
        let url = directory.appendingPathComponent("notes.wav")
        try Data("This is not a recording, it is a paragraph about one.".utf8).write(to: url)

        let result = message(for: url)
        XCTAssertTrue(result.contains("not a recording"), result)
        XCTAssertFalse(
            result.contains("couldn\u{2019}t be completed"),
            "the standard in docs/MANUAL-CHECKS.md is that this sentence never reaches a user")
    }

    func testAMissingFileSaysSo() {
        let result = message(for: directory.appendingPathComponent("nope.wav"))
        XCTAssertTrue(result.contains("no such file"), result)
    }
}

/// Where a batch of transcripts lands.
final class OutputNamingTests: XCTestCase {
    private func names(_ paths: [String]) -> [String] {
        FileTranscriber.outputNames(for: paths.map { URL(fileURLWithPath: $0) })
    }

    func testTheOrdinaryCaseIsTheObviousName() {
        XCTAssertEqual(names(["/tmp/meeting.wav"]), ["meeting.txt"])
        XCTAssertEqual(
            names(["/tmp/a.wav", "/tmp/b.mp3"]), ["a.txt", "b.txt"],
            "names that do not collide are not made ugly to prepare for the ones that would")
    }

    /// The bug. Both wanted `speech.txt`, the second overwrote the first, and "wrote speech.txt"
    /// printed twice as though both had landed.
    func testTheSameNameInTwoFormatsDoesNotOverwrite() {
        let result = names(["/a/speech.wav", "/b/speech.mp3"])
        XCTAssertEqual(result, ["speech.txt", "speech.mp3.txt"])
        XCTAssertEqual(Set(result).count, 2)
    }

    /// Nothing in the file name can separate these, so they are numbered by the order given —
    /// which is the order the "wrote …" lines print in.
    func testTheSameNameInTwoDirectoriesIsNumbered() {
        let result = names(["/monday/notes.wav", "/tuesday/notes.wav", "/wednesday/notes.wav"])
        XCTAssertEqual(result, ["notes.txt", "notes.wav.txt", "notes-2.txt"])
        XCTAssertEqual(Set(result).count, 3)
    }

    func testAFileListedTwiceStillGetsTwoNames() {
        let result = names(["/tmp/x.wav", "/tmp/x.wav"])
        XCTAssertEqual(Set(result).count, 2, "a repeated argument must not silently write once")
    }

    /// APFS is case-insensitive by default, so `Notes.txt` and `notes.txt` are one file and
    /// telling them apart by case brings the overwrite straight back.
    func testCaseAloneIsNotEnoughToTellTwoNamesApart() {
        let result = names(["/a/Notes.wav", "/b/notes.wav"])
        XCTAssertEqual(Set(result.map { $0.lowercased() }).count, 2)
    }

    func testNamesAreUniqueForAnyBatch() {
        let paths = (0..<50).map { "/dir\($0 % 3)/take\($0 % 5).\(["wav", "MP3"][$0 % 2])" }
        XCTAssertEqual(Set(names(paths).map { $0.lowercased() }).count, 50)
    }
}

final class AudioDecoderTests: XCTestCase {
    func testAlreadyTargetFormatIsPassedThroughByteForByte() throws {
        let wav = AudioChunker.wrapInWavContainer(
            Data(count: 16_000 * 2), format: AudioChunker.Format())
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).wav")
        try wav.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertTrue(AudioDecoder.isAlreadyTarget(wav))
        let loaded = try AudioDecoder.load(url)
        XCTAssertEqual(loaded.data, wav, "a re-encode here would be a lossy round trip for nothing")
        XCTAssertEqual(loaded.mimeType, "audio/wav")
    }

    /// The case that matters: a recording made by something other than this app. 44.1 kHz stereo is
    /// what every other tool produces, and everything downstream assumes 16 kHz mono.
    func testStereo44kIsConvertedToTheFormatTheChunkerNeeds() throws {
        let format = AudioChunker.Format(sampleRate: 44_100, channels: 2, bitsPerSample: 16)
        let seconds = 2
        let pcm = Data(count: format.bytesPerSecond * seconds)
        let wav = AudioChunker.wrapInWavContainer(pcm, format: format)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).wav")
        try wav.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertFalse(AudioDecoder.isAlreadyTarget(wav))
        let loaded = try AudioDecoder.load(url)

        XCTAssertTrue(AudioDecoder.isAlreadyTarget(loaded.data))
        XCTAssertEqual(
            loaded.durationSeconds ?? 0, Double(seconds), accuracy: 0.05,
            "the length has to survive the conversion, or every history row is wrong")
        XCTAssertNotNil(
            AudioChunker.pcmBody(of: loaded.data),
            "the chunker must be able to find silence in the result")
    }

    func testUnreadableFileExplainsWhatIsSupported() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).wav")
        try? Data("not audio at all".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try AudioDecoder.load(url)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Supported"))
        }
    }
}
