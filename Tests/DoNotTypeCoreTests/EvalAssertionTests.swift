import XCTest

@testable import DoNotTypeCore

/// The scoring gate itself, which nothing tested until a case was found that could not fail.
///
/// `real-mandarin` asserted only `mustNotContain`, and `mustContain.allSatisfy` is vacuously true
/// on an empty list — so every backend scored a pass on it regardless of what it returned, empty
/// output included. Every accuracy number in `docs/EVALUATION.md` was inflated by that case.
final class EvalAssertionTests: XCTestCase {
    private func outcome(
        expected: String = "",
        mustContain: [String] = [],
        mustNotContain: [String] = [],
        script: EvalCase.Script? = nil,
        minCharacters: Int? = nil,
        text: String
    ) -> EvalOutcome {
        EvalOutcome(
            caseID: "t", expected: expected, mustContain: mustContain,
            mustNotContain: mustNotContain, mustBeScript: script, minCharacters: minCharacters,
            withContext: text, withoutContext: text,
            report: TranscriptDiff.compare(withoutContext: text, withContext: text))
    }

    /// The hole. A case asserting only forbidden fragments used to pass on nothing at all.
    func testNothingTranscribedIsNeverAPass() {
        XCTAssertFalse(outcome(mustNotContain: ["forbidden"], text: "").passed)
        XCTAssertFalse(outcome(mustNotContain: ["forbidden"], text: "   \n ").passed)
        XCTAssertFalse(outcome(mustContain: ["x"], text: "").passed)
        XCTAssertFalse(outcome(expected: "hello", text: "").passed)
    }

    /// A backend that returns the first two seconds of a twenty-second clip satisfies every
    /// `mustNotContain` by never reaching the words it would have got wrong.
    func testATruncatedTranscriptFailsTheLengthFloor() {
        XCTAssertFalse(
            outcome(mustNotContain: ["forbidden"], minCharacters: 40, text: "Okay.").passed)
        XCTAssertTrue(
            outcome(
                mustNotContain: ["forbidden"], minCharacters: 40,
                text: String(repeating: "a real transcript ", count: 4)
            ).passed)
    }

    /// Rule 6 — transcribe in the language spoken, never translate — asserted directly, rather
    /// than by writing down a Chinese fragment nobody verified by ear.
    func testScriptAssertionCatchesATranslation() {
        let translated = "Through AI you can add your own response to the storyline."
        XCTAssertFalse(outcome(script: .han, minCharacters: 20, text: translated).passed)

        let mandarin = "通过AI可以在其中去增加自己的response用户可以去选择一个自己的选择然后引入新的storyline"
        XCTAssertTrue(outcome(script: .han, minCharacters: 20, text: mandarin).passed)
    }

    /// Code-switched English inside Mandarin still satisfies the Han assertion, which is the
    /// point: the case is about not translating, not about excluding English entirely.
    func testCodeSwitchedEnglishStillSatisfiesTheHanAssertion() {
        let mixed = "我要把这几个串起来搞成一个 retrieval pipeline，这个是 4240 我印象里"
        XCTAssertTrue(
            outcome(
                mustContain: ["retrieval pipeline", "4240"], script: .han, minCharacters: 20,
                text: mixed
            ).passed)
    }

    func testACaseThatAssertsNothingIsAFailureRatherThanAFreeGreen() {
        XCTAssertFalse(outcome(text: "anything at all, it does not matter").passed)
    }

    /// The shipped corpus must not contain another case that cannot fail.
    func testEveryShippedCaseAssertsSomethingAnEmptyTranscriptWouldFail() throws {
        let directory = Self.repositoryRoot.appendingPathComponent("eval/nearmiss")
        let cases = try EvalRunner.loadCases(in: directory)
        XCTAssertFalse(cases.isEmpty)

        for (testCase, url) in cases {
            let asserted = (testCase.expectTranscript?.isEmpty == false)
                || !(testCase.mustContain ?? []).isEmpty
                || testCase.mustBeScript != nil
                || testCase.minCharacters != nil
            XCTAssertTrue(
                asserted,
                """
                \(url.lastPathComponent) asserts only forbidden fragments, so an empty transcript \
                would pass it. Add mustContain, mustBeScript or minCharacters.
                """)
        }
    }
}

extension EvalAssertionTests {
    /// Tests run from `.build`, so walk up to the directory holding prompt/.
    static var repositoryRoot: URL {
        PromptBuilder.findPromptDirectory(startingAt: URL(fileURLWithPath: #filePath))?
            .deletingLastPathComponent()
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }
}
