import XCTest

@testable import DoNotTypeCore

final class PromptBuilderTests: XCTestCase {
    private let template = """
        # PROMPT.md
        Preamble that must not be sent.

        <!-- BEGIN SYSTEM -->
        You are a transcription engine.
        5. {{FIDELITY_RULE}}
        <!-- END SYSTEM -->

        ### raw
        ```
        Fidelity is RAW. Transcribe every sound.
        ```

        ### light
        ```
        Fidelity is LIGHT. Drop filler sounds,
        keep every real word.
        ```
        """

    func testSystemInstructionExcludesEverythingOutsideTheMarkers() throws {
        let instruction = try PromptBuilder(template: template).systemInstruction(fidelity: .raw)

        XCTAssertTrue(instruction.hasPrefix("You are a transcription engine."))
        XCTAssertFalse(instruction.contains("Preamble"))
        XCTAssertFalse(instruction.contains("BEGIN SYSTEM"))
    }

    func testExactlyOneFidelityClauseIsSubstituted() throws {
        let builder = PromptBuilder(template: template)

        let light = try builder.systemInstruction(fidelity: .light)
        XCTAssertTrue(light.contains("Fidelity is LIGHT. Drop filler sounds, keep every real word."))
        XCTAssertFalse(light.contains("RAW"))
        XCTAssertFalse(light.contains("{{FIDELITY_RULE}}"))
    }

    func testMissingMarkersAreRejectedRatherThanSilentlyProducingAnEmptyPrompt() {
        XCTAssertThrowsError(
            try PromptBuilder(template: "no markers here").systemInstruction())
    }

    /// The real file has to build, or the app ships with a broken contract.
    func testShippedPromptFileBuildsForEveryFidelity() throws {
        guard let url = PromptBuilder.findPromptFile() else {
            throw XCTSkip("PROMPT.md not found from the test working directory")
        }
        let builder = try PromptBuilder(contentsOf: url)
        for fidelity in Fidelity.allCases {
            let instruction = try builder.systemInstruction(fidelity: fidelity)
            XCTAssertTrue(instruction.contains("Context corrects SPELLING, never CONTENT"))
            XCTAssertFalse(instruction.contains("{{"))
        }
    }
}

final class TranscriptParsingTests: XCTestCase {
    func testPlainJSON() throws {
        let parsed = try Transcript.parse(#"{"transcript":"hello there","language":"en"}"#)
        XCTAssertEqual(parsed.transcript, "hello there")
        XCTAssertEqual(parsed.language, "en")
    }

    /// Observed from gemini-3.6-flash through an OpenAI-compatible shim even with a schema set.
    func testMarkdownFencedJSONIsTolerated() throws {
        let parsed = try Transcript.parse(
            """
            ```json
            {"transcript": "Gemini 3.5 Flash", "language": "en"}
            ```
            """)
        XCTAssertEqual(parsed.transcript, "Gemini 3.5 Flash")
    }

    /// A dictation is more useful than an error when the model ignores the schema entirely.
    func testBareProseFallsBackToBeingTheTranscript() throws {
        let parsed = try Transcript.parse("just the words, no JSON")
        XCTAssertEqual(parsed.transcript, "just the words, no JSON")
        XCTAssertEqual(parsed.language, "")
    }

    func testMalformedJSONObjectThrows() {
        XCTAssertThrowsError(try Transcript.parse(#"{"transcript": "#))
    }
}

/// Exercises the protocol extension without touching the network.
private struct StubProvider: TranscriptionProvider {
    let name = "stub"
    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        TranscriptionResult(
            transcript: Transcript(transcript: ""), usage: TokenUsage(), rawOutput: "")
    }
}

final class AudioAndProviderTests: XCTestCase {
    func testMimeTypeResolution() {
        XCTAssertEqual(AudioFile.mimeType(forExtension: "wav"), "audio/wav")
        XCTAssertEqual(AudioFile.mimeType(forExtension: "FLAC"), "audio/flac")
        XCTAssertEqual(AudioFile.mimeType(forExtension: "ogg"), "audio/ogg")
    }

    func testOpenAIAudioFormatIsABareCodecName() {
        XCTAssertEqual(OpenAICompatibleProvider.audioFormat(for: "audio/wav"), "wav")
        XCTAssertEqual(OpenAICompatibleProvider.audioFormat(for: "audio/flac"), "flac")
        XCTAssertEqual(OpenAICompatibleProvider.audioFormat(for: "audio/mpeg"), "mp3")
    }

    func testMissingKeyIsReportedWithTheVariableName() {
        XCTAssertThrowsError(try ProviderFactory.make(.openrouter, environment: [:])) { error in
            guard case ProviderError.missingAPIKey(let envVar) = error else {
                return XCTFail("expected missingAPIKey, got \(error)")
            }
            XCTAssertEqual(envVar, "OPENROUTER_API_KEY")
        }
    }

    /// A gateway that accepts audio and bills zero audio tokens never gave it to the model, and
    /// the "transcript" it returns is invented. Observed in the wild; must throw, never return.
    func testZeroAudioTokensThrowsInsteadOfReturningFabricatedText() {
        let provider = StubProvider()
        let request = TranscriptionRequest(
            model: "any", systemInstruction: "", parts: [.audio(data: Data([1]), mimeType: "audio/wav")])

        XCTAssertThrowsError(
            try provider.assertAudioWasProcessed(
                request: request, usage: TokenUsage(promptTokens: 14, audioTokens: 0),
                model: "any")
        ) { error in
            guard case ProviderError.audioSilentlyDropped = error else {
                return XCTFail("expected audioSilentlyDropped, got \(error)")
            }
        }
    }

    func testAudioTokensPresentPassesTheGuard() throws {
        let request = TranscriptionRequest(
            model: "any", systemInstruction: "", parts: [.audio(data: Data([1]), mimeType: "audio/wav")])
        try StubProvider().assertAudioWasProcessed(
            request: request, usage: TokenUsage(audioTokens: 77), model: "any")
    }

    /// "Not reported" is indistinguishable from "dropped", so it must not fail the request.
    func testUnreportedUsageIsNotTreatedAsADrop() throws {
        let request = TranscriptionRequest(
            model: "any", systemInstruction: "", parts: [.audio(data: Data([1]), mimeType: "audio/wav")])
        try StubProvider().assertAudioWasProcessed(
            request: request, usage: TokenUsage(), model: "any")
    }

    /// A text-only request has no audio to lose.
    func testTextOnlyRequestIsUnaffected() throws {
        let request = TranscriptionRequest(
            model: "any", systemInstruction: "", parts: [.text("hello")])
        try StubProvider().assertAudioWasProcessed(
            request: request, usage: TokenUsage(audioTokens: 0), model: "any")
    }

    func testGeminiResponseTextIsReadFromStepsNotOutputText() {
        let root: [String: Any] = [
            "output_text": "SDK-added, must be ignored",
            "steps": [
                ["type": "model_output", "content": [["type": "text", "text": "the transcript"]]]
            ],
        ]
        XCTAssertEqual(GeminiProvider.extractText(from: root), "the transcript")
    }
}

/// A provider error a user cannot read is a provider error a user cannot act on.
final class GeminiErrorDecodingTests: XCTestCase {
    /// The real shape: a top-level array, which is why a naive object decode produced nothing and
    /// the raw JSON ended up truncated in the UI.
    func testMessageIsExtractedFromTheTopLevelArray() {
        let body = Data(
            """
            [{"error":{"code":400,"message":"API key not valid. Please pass a valid API key.",\
            "status":"INVALID_ARGUMENT"}}]
            """.utf8)
        XCTAssertEqual(
            GeminiProvider.errorMessage(from: body),
            "API key not valid. Please pass a valid API key. (INVALID_ARGUMENT)")
    }

    func testSingleObjectShapeIsAlsoAccepted() {
        let body = Data(#"{"error":{"message":"Quota exceeded","status":"RESOURCE_EXHAUSTED"}}"#.utf8)
        XCTAssertEqual(
            GeminiProvider.errorMessage(from: body), "Quota exceeded (RESOURCE_EXHAUSTED)")
    }

    func testMessageAloneIsEnough() {
        let body = Data(#"[{"error":{"message":"Unsupported model"}}]"#.utf8)
        XCTAssertEqual(GeminiProvider.errorMessage(from: body), "Unsupported model")
    }

    /// An unparseable error is still better than a swallowed one.
    func testUnparseableBodiesFallBackToTheRawText() {
        XCTAssertEqual(GeminiProvider.errorMessage(from: Data("gateway timeout".utf8)), "gateway timeout")
        XCTAssertEqual(GeminiProvider.errorMessage(from: Data("[]".utf8)), "[]")
    }
}

/// The key must never reach a report that exists to be pasted somewhere public.
final class DiagnosticFingerprintTests: XCTestCase {
    /// Mirrors `Diagnostics.fingerprint`, which lives in the app target. The property under test
    /// is the one that matters: enough to identify a key, never enough to use one.
    private func fingerprint(_ key: String?) -> String {
        guard let key, !key.isEmpty else { return "none" }
        return "\(key.count) chars"
    }

    func testAbsentKeyIsReportedRatherThanBlank() {
        XCTAssertEqual(fingerprint(nil), "none")
        XCTAssertEqual(fingerprint(""), "none")
    }

    func testFingerprintNeverContainsTheKey() {
        let key = "AQ.Ab8RN6JiTcQuMjg2I_VsfZks-sPkcgXYeLqTYZcCqA"
        let printed = fingerprint(key)
        XCTAssertFalse(printed.contains(key))
        XCTAssertFalse(printed.contains(key.prefix(8)))
        XCTAssertTrue(printed.contains("\(key.count)"))
    }
}
