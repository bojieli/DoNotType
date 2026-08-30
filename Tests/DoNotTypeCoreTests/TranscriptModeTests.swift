import XCTest

@testable import DoNotTypeCore

/// Modes, and the wall between rewriting and summarising.
final class TranscriptModeTests: XCTestCase {
    private var prompt: PromptBuilder {
        PromptBuilder(directory: PromptBuilder.findPromptDirectory()!)
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
        XCTAssertEqual(TranscriptMode(rawValue: "rewrite"), .rewrite(.casual))
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
        XCTAssertTrue(TranscriptMode.translate("English").needsSecondPass)
    }

    /// A translation is not a rewrite style, and a history row must not record it as one — that
    /// column drives "revert to what you said", and the two mean different things.
    func testATranslationIsNotRecordedAsARewriteStyle() {
        XCTAssertNil(TranscriptMode.translate("English").rewriteStyle)
        XCTAssertEqual(TranscriptMode.rewrite(.formal).rewriteStyle, .formal)
    }

    /// A picker has nothing to offer until a language exists, so the translation appears in the
    /// list only when there is one.
    func testTheModeListOffersATranslationOnlyWhenALanguageIsSet() {
        XCTAssertFalse(TranscriptMode.allChoices.contains { if case .translate = $0 { true } else { false } })
        XCTAssertEqual(TranscriptMode.allChoices(translatingInto: "  ").count, TranscriptMode.allChoices.count)
        XCTAssertEqual(
            TranscriptMode.allChoices(translatingInto: "English").last, .translate("English"))
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

    func testDefaultRewriteRemovesFillersAndRequestsConciseProse() throws {
        let rewrite = try prompt.rewriteInstruction(style: .formal)
        for phrase in [
            "vocal fillers", "\"um\"", "\"ah\"", "\"actually\"", "\"basically\"", "false starts",
            "repetition", "self-corrections", "final wording", "superseded wording",
            "clear, concise, professional prose",
        ] {
            XCTAssertTrue(rewrite.contains(phrase), "default rewrite lost: \(phrase)")
        }
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

    /// A user who edited the contract before summaries existed used to break the summary stage
    /// outright: their override was the whole file, so it had no summary block and nothing could
    /// fall back. Per-part overrides make that unreachable — an edited `system.md` says nothing
    /// about `summary.md`, which is still the shipped one.
    func testEditingOnePartCannotBreakAStageItSaysNothingAbout() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dnt-mode-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = PromptStore(directory: directory)
        try store.save("MY ENGINE. {{FIDELITY_RULE}}", for: .system)
        let builder = store.builder(bundled: PromptBuilder.findPromptDirectory()!)

        XCTAssertTrue(try builder.systemInstruction(fidelity: .light).hasPrefix("MY ENGINE."))
        for style in SummaryStyle.allCases {
            XCTAssertNoThrow(try builder.summaryInstruction(style: style))
        }
        for style in RewriteStyle.allCases where style.isRewrite {
            XCTAssertNoThrow(try builder.rewriteInstruction(style: style))
        }
    }

    /// `PromptStore.validate` gates saving an edited part, and each part is judged on its own
    /// terms — a clause has no placeholder to require.
    func testValidationJudgesEachPartOnItsOwnTerms() {
        XCTAssertNoThrow(try PromptStore.validate("Fidelity is MINE.", for: .fidelity(.light)))
        XCTAssertNoThrow(try PromptStore.validate("Summarise. {{SUMMARY_RULE}}", for: .summary))
        XCTAssertThrowsError(try PromptStore.validate("Summarise.", for: .summary))
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

    /// The `--mode` parity table, duplicated verbatim in every language's test suite.
    ///
    /// Four implementations of one grammar, and the failure mode is not a crash: it is a phone and
    /// a laptop disagreeing about what `summary` means, which nobody would think to look for. The
    /// table is duplicated in each language on purpose — a shared fixture file would be read by
    /// whichever platform remembered to read it.
    func testTheModeGrammarIsIdenticalOnEveryPlatform() {
        let table: [(String, String?)] = [
        ("verbatim", "verbatim"),
        ("raw", "verbatim"),
        ("transcribe", "verbatim"),
        ("none", "verbatim"),
        ("rewrite", "rewrite:casual"),
        ("rewrite:formal", "rewrite:formal"),
        ("rewrite:concise", "rewrite:concise"),
        ("rewrite:casual", "rewrite:casual"),
        ("rewrite:", "rewrite:casual"),
        ("rewrite:verbatim", nil),
        ("summary", "summary:brief"),
        ("summary:", "summary:brief"),
        ("summary:brief", "summary:brief"),
        ("summary:bullets", "summary:bullets"),
        ("summary:actions", "summary:actions"),
        ("summarise", "summary:brief"),
        ("summarize", "summary:brief"),
        ("SUMMARY:Bullets", "summary:bullets"),
        ("  summary  ", "summary:brief"),
        ("", nil),
        ("nonsense", nil),
        ("rewrite:nonsense", nil),
        ("summary:nonsense", nil),
        // A language is free text, so there is no wrong one to reject — only a missing one. The
        // case is preserved because a language is a name, and the value survives lowercasing that
        // every other tail goes through.
        ("translate:English", "translate:English"),
        ("translate:简体中文", "translate:简体中文"),
        ("translate:Brazilian Portuguese", "translate:Brazilian Portuguese"),
        ("  translate:English  ", "translate:English"),
        ("TRANSLATE:English", "translate:English"),
        ("translate", nil),
        ("translate:", nil),
        ("translate:   ", nil),
        ]
        for (typed, expected) in table {
            XCTAssertEqual(
                TranscriptMode(rawValue: typed)?.rawValue, expected,
                "`\(typed)` must parse the same here as on Windows, Android and iOS")
        }
    }

    /// The word shown while the second request is in flight, which is the one thing on screen
    /// during the slowest part of a two-request mode. Four interfaces read it, so it is in the
    /// table with everything else that must not drift.
    func testTheProgressLabelIsIdenticalOnEveryPlatform() {
        let table: [(String, String)] = [
            ("verbatim", "Finishing…"),
            ("rewrite:formal", "Rewriting…"),
            ("rewrite:concise", "Tightening…"),
            ("rewrite:casual", "Loosening…"),
            ("summary:brief", "Summarising…"),
            ("summary:bullets", "Summarising into bullets…"),
            ("summary:actions", "Picking out the actions…"),
            ("translate:English", "Translating…"),
        ]
        for (typed, expected) in table {
            XCTAssertEqual(TranscriptMode(rawValue: typed)?.progressLabel, expected, typed)
        }
    }
}

/// The target-language field, whose rules are repeated in
/// `windows/DoNotType.Core.Tests/TranscriptModeTests.cs` and
/// `android/app/src/test/kotlin/app/donottype/core/TranslationTargetTest.kt`.
final class TranslationTargetTests: XCTestCase {
    func testTheSanitiserIsIdenticalOnEveryPlatform() {
        let table: [(String, String)] = [
            ("English", "English"),
            ("  English  ", "English"),
            ("Traditional  Chinese", "Traditional Chinese"),
            ("Brazilian\nPortuguese", "Brazilian Portuguese"),
            ("a\tb", "a b"),
            ("", ""),
            ("   ", ""),
        ]
        for (typed, expected) in table {
            XCTAssertEqual(TranslationTarget.sanitized(typed), expected, typed)
        }
        XCTAssertEqual(
            TranslationTarget.sanitized(String(repeating: "x", count: 200)).count,
            TranslationTarget.maxCharacters)
    }

    /// Empty is off rather than invalid, which is the difference between a field you can clear and
    /// one that shouts at you for clearing it.
    func testAnEmptyFieldIsNotAnError() {
        XCTAssertNil(TranslationTarget.validationMessage(""))
        XCTAssertNil(TranslationTarget.validationMessage("   "))
        XCTAssertNil(TranslationTarget.validationMessage(nil))
        XCTAssertNil(TranslationTarget.validationMessage("简体中文"))
        XCTAssertEqual(
            TranslationTarget.validationMessage(String(repeating: "x", count: 200)),
            "A language name is at most 60 characters.")
    }

    /// Not a whitelist, and the suite says so: a language that is not in the list must still be
    /// accepted, because the model is the authority on what it can write.
    func testTheSuggestionsAreNotAWhitelist() {
        XCTAssertNil(TranslationTarget.validationMessage("Klingon"))
        XCTAssertEqual(TranscriptMode(rawValue: "translate:Klingon"), .translate("Klingon"))
        XCTAssertTrue(TranslationTarget.suggestions.contains("English"))
    }
}
