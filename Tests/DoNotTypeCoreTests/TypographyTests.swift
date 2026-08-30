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
    /// request, and this feature is only free of them because it adds nothing to it.
    func testTheDefaultRequestIsUnchangedByThisFeatureExisting() throws {
        let builder = try builder()
        for fidelity in Fidelity.allCases {
            XCTAssertEqual(
                try builder.systemInstruction(fidelity: fidelity, script: .spoken, sample: ""),
                try builder.systemInstruction(fidelity: fidelity))
        }
    }

    func testAChosenScriptAppendsTheFormattingBlock() throws {
        let builder = try builder()
        let instruction = try builder.systemInstruction(script: .traditional, sample: "")
        XCTAssertTrue(instruction.hasPrefix(try builder.systemInstruction()))
        XCTAssertTrue(instruction.contains("Traditional characters"))
        XCTAssertFalse(instruction.contains("{{SCRIPT_RULE}}"))
        // The formatting block restates the rule it could otherwise be read as relaxing.
        XCTAssertTrue(instruction.contains("never what it says"))
    }

    func testASampleIsFramedAsAnExampleRatherThanAsSpeech() throws {
        let builder = try builder()
        let instruction = try builder.systemInstruction(script: .spoken, sample: "中文 English。")
        XCTAssertTrue(instruction.contains("中文 English。"))
        XCTAssertFalse(instruction.contains("{{SAMPLE}}"))
        XCTAssertTrue(instruction.contains("It is not speech"))
        // A sample alone must not drag the script block in with it: two settings, two blocks.
        XCTAssertFalse(instruction.contains("Simplified characters"))
    }

    func testAWhitespaceOnlySampleIsNoSample() throws {
        let builder = try builder()
        XCTAssertEqual(
            try builder.systemInstruction(script: .spoken, sample: "   \n  "),
            try builder.systemInstruction())
    }

    func testEveryPartStillResolves() throws {
        try builder().validate()
        XCTAssertEqual(PromptPart(id: "script:traditional"), .script(.traditional))
        // `spoken` is the shipped contract's own rule, not a clause, so it has no file to name.
        XCTAssertNil(PromptPart(id: "script:spoken"))
    }
}
