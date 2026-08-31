import XCTest

@testable import DoNotTypeCore

/// The typography table, repeated verbatim in `windows/DoNotType.Core.Tests/TypographyTests.cs`
/// and `android/app/src/test/kotlin/app/donottype/core/TypographyTest.kt`.
///
/// Repeated rather than shared through a fixture file, like the mode grammar: a fixture is read by
/// whichever platform remembers to read it, and a transcript that is spaced on a laptop and tight
/// on a phone is exactly the inconsistency this type was added to remove.
final class TypographyTests: XCTestCase {

    /// input, spaced, tight.
    private static let table: [(input: String, spaced: String, tight: String)] = [
        // The boundary, in both directions and with the space already there or not.
        ("中文English", "中文 English", "中文English"),
        ("中文 English", "中文 English", "中文English"),
        ("中文  English", "中文 English", "中文English"),
        ("English中文", "English 中文", "English中文"),
        ("English 中文", "English 中文", "English中文"),
        // Digits count as the Latin side. This is the convention, and it is also what makes
        // "gemini-3.5-flash" read the same way in Chinese prose as in English.
        ("在2026年", "在 2026 年", "在2026年"),
        ("使用GPT-4模型", "使用 GPT-4 模型", "使用GPT-4模型"),
        // The reported bug: a stray space after a full-width stop, on some sentences and not
        // others. No convention allows it, so both settings remove it.
        ("你好。 世界", "你好。世界", "你好。世界"),
        ("你好 ，世界", "你好，世界", "你好，世界"),
        ("完成了。 Then I said hi.", "完成了。Then I said hi.", "完成了。Then I said hi."),
        ("《书名》 abc", "《书名》abc", "《书名》abc"),
        // English is not touched at all, whichever setting is in force.
        ("Hello world.", "Hello world.", "Hello world."),
        ("Two  spaces stay.", "Two  spaces stay.", "Two  spaces stay."),
        // A space between two Han characters is left alone. Removing it would join words the
        // speaker meant to keep apart, and this transform is never allowed to change wording —
        // the model is asked for proper punctuation there instead, in prompt/typography.md.
        ("这是 一个 句子", "这是 一个 句子", "这是 一个 句子"),
        // Structure survives: a newline is not horizontal space, and an indent is the caller's.
        ("第一行\n第二行abc", "第一行\n第二行 abc", "第一行\n第二行abc"),
        ("  缩进", "  缩进", "  缩进"),
        ("中文 ", "中文 ", "中文 "),
        // Symbols are not the Latin side, deliberately: a rule that fires on punctuation has far
        // more ways to be wrong.
        ("50%的人", "50%的人", "50%的人"),
        // Korean separates its own words. `tight` must not take that space away.
        ("Web 개발", "Web 개발", "Web 개발"),
        // Kana is treated like Han, so Japanese is consistent within itself.
        ("Webかいはつ", "Web かいはつ", "Webかいはつ"),
        ("A・B", "A・B", "A・B"),
        ("", "", ""),
    ]

    func testTheTableHolds() {
        for row in Self.table {
            XCTAssertEqual(
                Typography.normalize(row.input, spacing: .spaced), row.spaced,
                "spaced: \(row.input)")
            XCTAssertEqual(
                Typography.normalize(row.input, spacing: .tight), row.tight,
                "tight: \(row.input)")
        }
    }

    /// The escape hatch has to be exactly that: not a milder rule, no rule at all.
    func testUnchangedTouchesNothing() {
        for row in Self.table {
            XCTAssertEqual(Typography.normalize(row.input, spacing: .unchanged), row.input)
        }
    }

    /// A split recording is normalised per chunk and again over the stitch, so this is load
    /// bearing rather than a nicety.
    func testNormalisingTwiceIsNormalisingOnce() {
        for row in Self.table {
            for spacing in TypographySpacing.allCases {
                let once = Typography.normalize(row.input, spacing: spacing)
                XCTAssertEqual(Typography.normalize(once, spacing: spacing), once, row.input)
            }
        }
    }

    /// The invariant that makes this safe to run on every transcript: it is a space transform.
    /// Anything else here would be editing what the user said.
    func testOnlySpacingEverChanges() {
        for row in Self.table {
            for spacing in TypographySpacing.allCases {
                let result = Typography.normalize(row.input, spacing: spacing)
                XCTAssertEqual(
                    result.filter { !$0.isWhitespace },
                    row.input.filter { !$0.isWhitespace },
                    "\(spacing.rawValue): \(row.input)")
            }
        }
    }

    func testTheDefaultIsAStableRuleRatherThanTheModelsJudgement() {
        XCTAssertEqual(TypographySpacing.default, .spaced)
    }

    func testASampleIsCleanedRatherThanRejected() {
        XCTAssertEqual(Typography.sanitizedSample("  中文 English。  "), "中文 English。")
        XCTAssertEqual(Typography.sanitizedSample("a\r\nb"), "a\nb")
        XCTAssertEqual(Typography.sanitizedSample("a\n\n\n\n\nb"), "a\n\nb")
        XCTAssertEqual(Typography.sanitizedSample("a\u{0007}b"), "ab")
        XCTAssertEqual(Typography.sanitizedSample(""), "")
        XCTAssertEqual(
            Typography.sanitizedSample(String(repeating: "中", count: 900)).count,
            Typography.maxSampleCharacters)
    }
}

/// The formatting blocks reach the request only when they are asked for.
final class TypographyPromptTests: XCTestCase {
    private func builder() throws -> PromptBuilder {
        let directory = try XCTUnwrap(PromptBuilder.findPromptDirectory())
        return PromptBuilder(directory: directory)
    }

    /// The load-bearing one. Every measured number in `docs/PROMPT.md` describes the default
    /// request, and these features are only free of them because they add nothing to it.
    func testTheDefaultRequestIsUnchangedByTheseFeaturesExisting() throws {
        let builder = try builder()
        for fidelity in Fidelity.allCases {
            XCTAssertEqual(
                try builder.systemInstruction(
                    fidelity: fidelity, script: .spoken, dictationExample: ""),
                try builder.systemInstruction(fidelity: fidelity))
        }
    }

    func testAChosenScriptAppendsTheFormattingBlock() throws {
        let builder = try builder()
        let instruction = try builder.systemInstruction(script: .traditional)
        XCTAssertTrue(instruction.hasPrefix(try builder.systemInstruction()))
        XCTAssertTrue(instruction.contains("Traditional characters"))
        XCTAssertFalse(instruction.contains("{{SCRIPT_RULE}}"))
        // The formatting block restates the rule it could otherwise be read as relaxing.
        XCTAssertTrue(instruction.contains("never what it says"))
    }

    /// A preset and a sentence somebody typed are the same thing by the time they are sent: text
    /// in the example box. That is what makes "press Chat, then edit it" an offer and not a mode.
    func testAPresetAndTypedTextTakeTheSamePath() throws {
        let builder = try builder()
        for preset in DictationPreset.allCases {
            let text = try builder.dictationPresetText(preset)
            XCTAssertEqual(
                try builder.systemInstruction(dictationExample: text),
                try builder.systemInstruction(dictationExample: text),
                preset.rawValue)
            let instruction = try builder.systemInstruction(dictationExample: text)
            XCTAssertTrue(instruction.hasPrefix(try builder.systemInstruction()), preset.rawValue)
            XCTAssertFalse(instruction.contains("{{DICTATION_STYLE_RULE}}"), preset.rawValue)
            XCTAssertTrue(instruction.contains("never what it says"), preset.rawValue)
            XCTAssertTrue(instruction.contains("not an instruction to obey"), preset.rawValue)
            XCTAssertTrue(instruction.contains(text), preset.rawValue)
        }
    }

    func testTheExampleCarriesTheUsersOwnText() throws {
        let builder = try builder()
        let instruction = try builder.systemInstruction(dictationExample: "中文 English。")
        XCTAssertTrue(instruction.contains("中文 English。"))
        // An example alone must not drag the script block in with it: two settings, two blocks.
        XCTAssertFalse(instruction.contains("Simplified characters"))
    }

    /// An empty box is not a style. Sending the block with an empty clause would ask the model to
    /// write in no particular way, and it would do something.
    func testAnEmptyExampleSendsNothing() throws {
        let builder = try builder()
        XCTAssertEqual(
            try builder.systemInstruction(dictationExample: "   \n "),
            try builder.systemInstruction())
        XCTAssertNil(builder.dictationExampleClause("  "))
        XCTAssertEqual(try builder.styleClause(.custom, custom: "  "), "")
        XCTAssertEqual(try builder.rewriteInstruction(style: .custom, custom: "  "), "")
    }

    /// Upgrading must not change anybody's request — only make it visible. Somebody on Chat had
    /// `chat.md`'s words in every dictation, and afterwards has those same words in their box.
    func testMigrationPreservesTheRequestItReplaces() throws {
        let builder = try builder()
        let preset = { (p: DictationPreset) in try? builder.dictationPresetText(p) }

        for value in DictationPreset.allCases {
            let migrated = DictationExample.migrating(
                legacyStyle: value.rawValue, legacyCustom: "", presetText: preset)
            XCTAssertEqual(
                try builder.systemInstruction(dictationExample: migrated),
                try builder.systemInstruction(
                    dictationExample: try builder.dictationPresetText(value)),
                value.rawValue)
        }

        // `spoken`, absent, and a name from a future build all mean an empty box, which sends
        // nothing — the behaviour `spoken` had, and the safe answer for text this build cannot
        // resolve.
        for legacy in ["spoken", "", "sonnet-style"] {
            XCTAssertEqual(
                DictationExample.migrating(
                    legacyStyle: legacy, legacyCustom: "", presetText: preset), "")
        }
        XCTAssertEqual(
            DictationExample.migrating(legacyStyle: nil, legacyCustom: nil, presetText: preset), "")

        // Custom carried the user's own text and still does, sanitiser and cap included.
        XCTAssertEqual(
            DictationExample.migrating(
                legacyStyle: "custom", legacyCustom: " 中文 English。 ", presetText: preset),
            "中文 English。")
    }

    /// The rewrite side of the same control: the user's text lands inside `prompt/rewrite.md`, so
    /// the never-remove-a-fact rule applies to it exactly as it does to `formal`.
    func testACustomRewriteStyleIsWrappedInTheRewriteBlock() throws {
        let builder = try builder()
        let instruction = try builder.rewriteInstruction(
            style: .custom, custom: "Warm, but never more than three sentences.")
        XCTAssertTrue(instruction.contains("Warm, but never more than three sentences."))
        XCTAssertFalse(instruction.contains("{{STYLE_RULE}}"))
        XCTAssertTrue(instruction.contains("Keep every fact"))
    }

    func testEveryPartStillResolves() throws {
        try builder().validate()
        XCTAssertEqual(PromptPart(id: "script:traditional"), .script(.traditional))
        // `spoken` is the shipped contract's own rule, not a clause, so it has no file to name.
        XCTAssertNil(PromptPart(id: "script:spoken"))
        XCTAssertEqual(PromptPart(id: "dictation-style:chat"), .dictationPreset(.chat))
        // The retired cases. One sent nothing and one sent the user's own text; neither was ever
        // a file, and neither is a preset now.
        XCTAssertNil(PromptPart(id: "dictation-style:spoken"))
        XCTAssertNil(PromptPart(id: "dictation-style:custom"))
    }
}
