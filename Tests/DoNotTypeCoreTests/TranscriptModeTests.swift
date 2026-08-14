import XCTest

@testable import DoNotTypeCore

/// Modes, and the wall between rewriting and summarising.
final class TranscriptModeTests: XCTestCase {
    private var prompt: PromptBuilder {
        let url = PromptBuilder.findPromptFile()!
        return try! PromptBuilder(contentsOf: url)
    }

    // MARK: - Parsing

    func testParsesEverySpellingItAdvertises() {
        for spelling in TranscriptMode.acceptedSpellings {
            let parsed = TranscriptMode(rawValue: spelling)
            XCTAssertNotNil(parsed, "--mode \(spelling) is offered in help and must parse")
            XCTAssertEqual(parsed?.rawValue, spelling, "parsing must round trip")
        }
    }

    func testBareStageNamesTakeTheirDefault() {
        XCTAssertEqual(TranscriptMode(rawValue: "summary"), .summary(.brief))
        XCTAssertEqual(TranscriptMode(rawValue: "rewrite"), .rewrite(.formal))
        XCTAssertEqual(TranscriptMode(rawValue: "summarize"), .summary(.brief))
    }

    func testUnknownStylesAreRejectedRatherThanSilentlyDowngraded() {
        XCTAssertNil(TranscriptMode(rawValue: "summary:novel"))
        XCTAssertNil(TranscriptMode(rawValue: "rewrite:shakespeare"))
        XCTAssertNil(TranscriptMode(rawValue: "translate"))
        // `verbatim` is not a rewrite style, so asking for it as one is a mistake worth catching.
        XCTAssertNil(TranscriptMode(rawValue: "rewrite:verbatim"))
    }

    func testOnlyVerbatimAvoidsASecondRequest() {
        XCTAssertFalse(TranscriptMode.verbatim.needsSecondPass)
        XCTAssertTrue(TranscriptMode.rewrite(.formal).needsSecondPass)
        XCTAssertTrue(TranscriptMode.summary(.actions).needsSecondPass)
    }

    /// A summary is not a rewrite style, and a history row must not claim it is — that column feeds
    /// "revert to what you said", which means something different for the two.
    func testSummaryHasNoRewriteStyle() {
        XCTAssertNil(TranscriptMode.summary(.bullets).rewriteStyle)
        XCTAssertEqual(TranscriptMode.rewrite(.concise).rewriteStyle, .concise)
    }

    func testEveryChoiceIsOfferedExactlyOnce() {
        let choices = TranscriptMode.allChoices
        XCTAssertEqual(Set(choices).count, choices.count)
        XCTAssertTrue(choices.contains(.verbatim))
        XCTAssertFalse(
            choices.contains(.rewrite(.verbatim)),
            "verbatim must not appear as a rewrite style as well as a mode")
    }

    // MARK: - The prompt blocks

    func testSummaryInstructionResolvesForEveryStyle() throws {
        for style in SummaryStyle.allCases {
            let instruction = try prompt.summaryInstruction(style: style)
            XCTAssertFalse(instruction.contains("{{SUMMARY_RULE}}"), "the placeholder must be filled")
            XCTAssertFalse(instruction.contains("<!--"), "markers must not survive into the request")
            XCTAssertTrue(instruction.contains("summar"), "\(style) lost the summary framing")
        }
    }

    func testSummaryAndRewriteAreDifferentInstructions() throws {
        let summary = try prompt.summaryInstruction(style: .brief)
        let rewrite = try prompt.rewriteInstruction(style: .concise)
        XCTAssertNotEqual(summary, rewrite)

        // The rewrite block's first rule is the one this project exists to enforce; the summary
        // block must not carry it, because a summary that removes nothing has not summarised.
        XCTAssertTrue(rewrite.contains("Never remove"))
        XCTAssertFalse(summary.contains("Never remove"))
        // But both must keep the numbers rule, which is the failure grounding actually produces.
        XCTAssertTrue(summary.contains("unchanged"))
        XCTAssertTrue(rewrite.contains("unchanged"))
    }

    func testSecondStageRoutesEachModeToItsOwnBlock() throws {
        XCTAssertNil(try prompt.secondStageInstruction(for: .verbatim))
        XCTAssertEqual(
            try prompt.secondStageInstruction(for: .rewrite(.formal)),
            try prompt.rewriteInstruction(style: .formal))
        XCTAssertEqual(
            try prompt.secondStageInstruction(for: .summary(.actions)),
            try prompt.summaryInstruction(style: .actions))
    }

    /// A prompt edited before summaries existed is still a valid prompt for dictation. It must fail
    /// on summaries with a message that says what to do, not with a generic parse error.
    func testPromptWithoutASummaryBlockFailsHelpfully() throws {
        let template = try String(contentsOf: PromptBuilder.findPromptFile()!, encoding: .utf8)
        let stripped = template.replacingOccurrences(of: "<!-- BEGIN SUMMARY -->", with: "")
        let builder = PromptBuilder(template: stripped)

        XCTAssertNoThrow(try builder.systemInstruction(fidelity: .light), "dictation still works")
        XCTAssertThrowsError(try builder.summaryInstruction(style: .brief)) { error in
            let message = (error as? PromptBuilder.Error)?.errorDescription ?? ""
            XCTAssertTrue(
                message.contains("restore the shipped prompt"),
                "the error has to say how to fix it, got: \(message)")
        }
    }

    /// `PromptStore.validate` gates saving an edited prompt. It must not start rejecting prompts
    /// that were fine before summaries existed.
    func testValidationDoesNotRequireTheOptionalBlocks() throws {
        let template = try String(contentsOf: PromptBuilder.findPromptFile()!, encoding: .utf8)
        let stripped = template.replacingOccurrences(of: "<!-- BEGIN SUMMARY -->", with: "")
            .replacingOccurrences(of: "<!-- BEGIN REWRITE -->", with: "")
        XCTAssertNoThrow(try PromptStore.validate(stripped))
    }

    // MARK: - History

    func testOldRecordsResolveToTheModeTheyActuallyRan() {
        let dictation = DictationRecord(
            status: .completed, text: "hello", provider: "gemini", model: "m", fidelity: .light)
        XCTAssertEqual(dictation.resolvedMode, .verbatim)

        let rewritten = DictationRecord(
            status: .completed, text: "hello", styledText: "Hello.", style: .formal,
            provider: "gemini", model: "m", fidelity: .light)
        XCTAssertEqual(rewritten.resolvedMode, .rewrite(.formal))
        XCTAssertFalse(rewritten.isFromFile)
    }

    func testRecordSurvivesACodableRoundTripWithTheNewFields() throws {
        let record = DictationRecord(
            status: .completed, text: "what was said", styledText: "the gist",
            provider: "gemini", model: "m", fidelity: .light,
            mode: .summary(.bullets), sourceFileName: "meeting.m4a")

        let data = try JSONEncoder.history.encode([record])
        let decoded = try JSONDecoder.history.decode([DictationRecord].self, from: data)

        XCTAssertEqual(decoded.first?.mode, .summary(.bullets))
        XCTAssertEqual(decoded.first?.sourceFileName, "meeting.m4a")
        XCTAssertTrue(decoded.first?.isFromFile ?? false)
    }

    /// History written before this change has no `mode` key at all. Decoding it must not fail —
    /// that would empty someone's history on upgrade.
    func testHistoryFromBeforeModesExistedStillDecodes() throws {
        let json = """
            [{
              "id": "\(UUID().uuidString)",
              "createdAt": "2026-08-01T10:00:00Z",
              "status": "completed",
              "text": "an older dictation",
              "provider": "gemini",
              "model": "gemini-3.6-flash",
              "fidelity": "light",
              "durationSeconds": 3,
              "retryCount": 0
            }]
            """
        let decoded = try JSONDecoder.history.decode(
            [DictationRecord].self, from: Data(json.utf8))
        XCTAssertEqual(decoded.count, 1)
        XCTAssertNil(decoded[0].mode)
        XCTAssertEqual(decoded[0].resolvedMode, .verbatim)
    }
}
