import XCTest

@testable import DoNotTypeCore

/// These run against the shipped `prompt/`, not a fixture.
///
/// The previous version of this class parsed a synthetic template, and that is exactly why it
/// passed for as long as the contract was one file: the fixture mentioned each marker once, so a
/// first-match search could not go wrong in it. The real file documented its own markers and every
/// request carried eight lines of that documentation. A test that cannot see the shipped bytes
/// cannot catch what happens to them.
final class PromptBuilderTests: XCTestCase {
    private func shipped() throws -> PromptBuilder {
        guard let url = PromptBuilder.findPromptDirectory() else {
            throw XCTSkip("prompt/ not found from the test working directory")
        }
        return PromptBuilder(directory: url)
    }

    func testShippedPromptBuildsForEveryFidelity() throws {
        let builder = try shipped()
        for fidelity in Fidelity.allCases {
            let instruction = try builder.systemInstruction(fidelity: fidelity)
            XCTAssertTrue(instruction.hasPrefix("You are a transcription engine."))
            XCTAssertTrue(instruction.contains("Context corrects SPELLING, never CONTENT"))
            XCTAssertFalse(instruction.contains("{{"), "an unfilled placeholder reached the model")
        }
    }

    /// The regression test for the bug the split ended: the assembled instruction must be the
    /// contract and nothing else. Documentation, markers and build instructions are not sent.
    func testNothingButTheContractIsSent() throws {
        let instruction = try shipped().systemInstruction(fidelity: .light)

        for leak in ["BEGIN SYSTEM", "END SYSTEM", "PromptBuilder", "dnt-eval", "changelog"] {
            XCTAssertFalse(instruction.contains(leak), "\(leak) reached the model")
        }
    }

    /// Substituting a clause must place it once. The fidelity rule appearing twice is measurable
    /// harm, not cosmetic — see the 2026-08-09 entry in PROMPT.md, where restating it moved
    /// substitution from 11/19 to 15/18.
    func testTheFidelityClauseAppearsExactlyOnce() throws {
        let builder = try shipped()
        let clause = try builder.text(for: .fidelity(.light))
        let instruction = try builder.systemInstruction(fidelity: .light)

        XCTAssertEqual(
            instruction.components(separatedBy: clause).count - 1, 1,
            "the fidelity clause is not in the instruction exactly once")
        XCTAssertFalse(instruction.contains("Fidelity is RAW"))
        XCTAssertFalse(instruction.contains("Fidelity is TIDY"))
    }

    /// A part file is sent in full, so anything that looks like an annotation in one is a mistake.
    func testNoPartContainsMarkupThatWasMeantToBeStripped() throws {
        let builder = try shipped()
        for part in PromptPart.allCases {
            let text = try builder.text(for: part)
            XCTAssertFalse(text.contains("<!--"), "\(part.id) contains a comment marker")
            XCTAssertFalse(text.contains("```"), "\(part.id) contains a code fence")
            if part.isClause {
                XCTAssertFalse(text.contains("\n"), "\(part.id) is a clause and must be one line")
            }
        }
    }

    /// Every part a picker can reach must exist, or choosing it fails at request time.
    func testEveryPartResolves() throws {
        try shipped().validate()

        let builder = try shipped()
        for style in RewriteStyle.allCases where style.isRewrite {
            let instruction = try builder.rewriteInstruction(style: style)
            XCTAssertFalse(instruction.contains("{{"), "\(style.rawValue) left a placeholder")
        }
        for style in SummaryStyle.allCases {
            let instruction = try builder.summaryInstruction(style: style)
            XCTAssertFalse(instruction.contains("{{"), "\(style.rawValue) left a placeholder")
        }
    }

    /// A checkout with CRLF must send the same bytes as one with LF.
    ///
    /// Git rewrites these files on Windows under the default `autocrlf`, so without normalisation
    /// the Windows app shipped a different contract than macOS did — four platforms sending four
    /// prompts, which is the drift the shared file exists to prevent, and it would not show up in
    /// any output a person reads.
    func testLineEndingsInTheCheckoutDoNotChangeWhatIsSent() throws {
        guard let shipped = PromptBuilder.findPromptDirectory() else {
            throw XCTSkip("prompt/ not found from the test working directory")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("prompt-crlf-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        for part in PromptPart.allCases {
            let destination = directory.appendingPathComponent(part.relativePath)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let text = try String(
                contentsOf: shipped.appendingPathComponent(part.relativePath), encoding: .utf8)
            try text.replacingOccurrences(of: "\n", with: "\r\n")
                .write(to: destination, atomically: true, encoding: .utf8)
        }

        let lf = PromptBuilder(directory: shipped)
        let crlf = PromptBuilder(directory: directory)
        for fidelity in Fidelity.allCases {
            XCTAssertEqual(
                try crlf.systemInstruction(fidelity: fidelity),
                try lf.systemInstruction(fidelity: fidelity),
                "a CRLF checkout sends a different \(fidelity.rawValue) contract")
        }
        for part in PromptPart.allCases {
            XCTAssertEqual(try crlf.text(for: part), try lf.text(for: part), part.id)
        }
    }

    func testAMissingPartNamesTheFileAndThePart() throws {
        let empty = PromptBuilder(directory: URL(fileURLWithPath: "/nonexistent-prompt-dir"))
        XCTAssertThrowsError(try empty.systemInstruction()) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("system.md"), "the message must name the file: \(message)")
            XCTAssertTrue(
                message.contains("/nonexistent-prompt-dir"),
                "the message must name where it looked: \(message)")
        }
    }
}

/// Per-part overrides, and the one-time split of the single-file format they replaced.
final class PromptStoreTests: XCTestCase {
    private var directory = URL(fileURLWithPath: "/tmp")

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("prompt-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func bundled() throws -> URL {
        guard let url = PromptBuilder.findPromptDirectory() else {
            throw XCTSkip("prompt/ not found from the test working directory")
        }
        return url
    }

    /// The reason for splitting, as a test: editing one part must not freeze the others.
    func testEditingOnePartLeavesTheRestShipped() throws {
        let store = PromptStore(directory: directory)
        try store.save("Fidelity is MINE.", for: .fidelity(.light))

        XCTAssertEqual(store.customParts, [.fidelity(.light)])

        let instruction = try store.builder(bundled: try bundled())
            .systemInstruction(fidelity: .light)
        XCTAssertTrue(instruction.contains("Fidelity is MINE."))
        // Still the shipped contract around it.
        XCTAssertTrue(instruction.hasPrefix("You are a transcription engine."))

        // And a fidelity they did not touch is untouched.
        let raw = try store.builder(bundled: try bundled()).systemInstruction(fidelity: .raw)
        XCTAssertTrue(raw.contains("Fidelity is RAW"))
    }

    func testAPartThatWouldDropItsClauseIsRejectedAndNotWritten() throws {
        let store = PromptStore(directory: directory)
        XCTAssertThrowsError(try store.save("No placeholder in here.", for: .system)) { error in
            XCTAssertTrue(error.localizedDescription.contains("{{FIDELITY_RULE}}"))
        }
        XCTAssertFalse(store.isCustom(.system), "a rejected part must not be written")
        XCTAssertThrowsError(try store.save("   ", for: .rewrite))
    }

    func testRestoringOnePartLeavesTheOthersEdited() throws {
        let store = PromptStore(directory: directory)
        try store.save("MINE. {{FIDELITY_RULE}}", for: .system)
        try store.save("Fidelity is MINE.", for: .fidelity(.tidy))

        try store.restore(.system)
        XCTAssertEqual(store.customParts, [.fidelity(.tidy)])

        try store.restoreAll()
        XCTAssertTrue(store.customParts.isEmpty)
    }

    /// Migrating a copy of the *shipped* file must produce no overrides at all.
    ///
    /// Someone who opened the prompt editor, saved without changing anything, and thereby got a
    /// verbatim copy of the contract should come out of this with zero edited parts — not twelve
    /// pinned to whatever the contract said that day.
    func testMigratingAnUnchangedCopyProducesNoOverrides() throws {
        let store = PromptStore(directory: directory)
        try legacyFile(fromShipped: try bundled()).write(
            to: store.legacyURL, atomically: true, encoding: .utf8)

        let migration = try XCTUnwrap(try store.migrateLegacyPrompt(bundled: try bundled()))
        XCTAssertTrue(
            migration.migrated.isEmpty,
            "an unchanged copy became overrides: \(migration.migrated.map(\.id))")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.legacyURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: migration.archivedAt.path))
    }

    func testMigrationKeepsOnlyTheEditedParts() throws {
        let store = PromptStore(directory: directory)
        let legacy = try legacyFile(fromShipped: try bundled())
            .replacingOccurrences(of: "Fidelity is TIDY.", with: "Fidelity is CUSTOM.")
        try legacy.write(to: store.legacyURL, atomically: true, encoding: .utf8)

        let migration = try XCTUnwrap(try store.migrateLegacyPrompt(bundled: try bundled()))
        XCTAssertEqual(migration.migrated, [.fidelity(.tidy)])
        XCTAssertTrue(try store.builder(bundled: try bundled())
            .systemInstruction(fidelity: .tidy).contains("Fidelity is CUSTOM."))
    }

    /// The migrator must not repeat the bug it is migrating away from.
    ///
    /// A user's custom prompt was usually a copy of the shipped file, and the shipped file quoted
    /// `<!-- BEGIN SYSTEM -->` in a sentence above the real marker. Splitting with the original
    /// first-match rule would carry that sentence into their new system.md forever.
    func testMigrationIgnoresAMarkerQuotedInProse() throws {
        let store = PromptStore(directory: directory)
        let legacy = """
            # PROMPT.md

            `PromptBuilder` reads everything below the `<!-- BEGIN SYSTEM -->` marker, substitutes
            `{{FIDELITY_RULE}}` with the active fidelity clause.

            <!-- BEGIN SYSTEM -->
            You are a transcription engine.
            5. {{FIDELITY_RULE}}
            <!-- END SYSTEM -->

            ### light
            ```
            Fidelity is LIGHT.
            ```
            """
        try legacy.write(to: store.legacyURL, atomically: true, encoding: .utf8)

        _ = try store.migrateLegacyPrompt(bundled: try bundled())

        let system = try String(contentsOf: store.url(for: .system), encoding: .utf8)
        XCTAssertTrue(system.hasPrefix("You are a transcription engine."))
        XCTAssertFalse(system.contains("PromptBuilder"))
        XCTAssertFalse(system.contains("BEGIN SYSTEM"))
    }

    func testNothingToMigrateIsNotAnError() throws {
        let store = PromptStore(directory: directory)
        XCTAssertNil(try store.migrateLegacyPrompt(bundled: try bundled()))
    }

    /// Rebuilds the old single-file format out of the shipped parts, for the migration tests.
    private func legacyFile(fromShipped url: URL) throws -> String {
        let source = PromptSource(bundled: url)
        func fenced(_ heading: String, _ part: PromptPart) throws -> String {
            "### \(heading)\n```\n\(try source.editableText(for: part))\n```\n"
        }
        var text = "# PROMPT.md\n\nPreamble.\n\n"
        text += "<!-- BEGIN SYSTEM -->\n\(try source.editableText(for: .system))\n<!-- END SYSTEM -->\n\n"
        text += "<!-- BEGIN REWRITE -->\n\(try source.editableText(for: .rewrite))\n<!-- END REWRITE -->\n\n"
        text += "<!-- BEGIN SUMMARY -->\n\(try source.editableText(for: .summary))\n<!-- END SUMMARY -->\n\n"
        for fidelity in Fidelity.allCases {
            text += try fenced(fidelity.rawValue, .fidelity(fidelity)) + "\n"
        }
        for style in RewriteStyle.allCases where style.isRewrite {
            text += try fenced("style: \(style.rawValue)", .style(style)) + "\n"
        }
        for style in SummaryStyle.allCases {
            text += try fenced("summary: \(style.rawValue)", .summaryStyle(style)) + "\n"
        }
        return text
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
