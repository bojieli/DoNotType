import XCTest

@testable import DoNotTypeCore

final class TranscriptDiffTests: XCTestCase {
    /// The case this whole project is designed around.
    func testVersionNumberSubstitutionIsContentChanged() {
        let report = TranscriptDiff.compare(
            withoutContext: "We should switch to Gemini 3.5 Flash for this.",
            withContext: "We should switch to Gemini 3 Flash for this.")

        XCTAssertEqual(report.count(.contentChanged), 1)
        XCTAssertFalse(report.isClean)
    }

    func testCorrectSpellingOfAJargonTermIsNotABug() {
        let report = TranscriptDiff.compare(
            withoutContext: "install coffee from homebrew",
            withContext: "install koffi from homebrew")

        XCTAssertEqual(report.count(.spellingFixed), 1)
        XCTAssertTrue(report.isClean)
    }

    /// A merge across a word boundary must surface as one span, not an insert plus a delete.
    func testWordBoundaryFixIsSpellingNotInsertion() {
        let report = TranscriptDiff.compare(
            withoutContext: "use swift UI for the settings",
            withContext: "use SwiftUI for the settings")

        XCTAssertEqual(report.spans.count, 1)
        XCTAssertEqual(report.spans.first?.classification, .spellingFixed)
    }

    func testCapitalisationAloneProducesNoSpan() {
        let report = TranscriptDiff.compare(
            withoutContext: "ship it now",
            withContext: "Ship it, now")

        XCTAssertTrue(report.spans.isEmpty)
        XCTAssertTrue(report.isClean)
    }

    func testWordsAppearingOnlyWithContextAreInsertions() {
        let report = TranscriptDiff.compare(
            withoutContext: "let us ship",
            withContext: "let us ship the pricing page")

        XCTAssertEqual(report.count(.inserted), 1)
        XCTAssertFalse(report.isClean)
    }

    func testUnrelatedWordSwapIsContentChanged() {
        let report = TranscriptDiff.compare(
            withoutContext: "send it to Marcus",
            withContext: "send it to Priya")

        XCTAssertEqual(report.count(.contentChanged), 1)
    }

    func testIdenticalTranscriptsAreClean() {
        let report = TranscriptDiff.compare(
            withoutContext: "nothing changed here", withContext: "nothing changed here")
        XCTAssertTrue(report.spans.isEmpty)
    }

    // MARK: - Primitives

    func testDigitRunsDistinguishVersionNumbers() {
        XCTAssertEqual(TranscriptDiff.digitRuns("Gemini 3.5 Flash"), ["3", "5"])
        XCTAssertEqual(TranscriptDiff.digitRuns("Gemini 3 Flash"), ["3"])
    }

    func testPhoneticKeyCollapsesSpellingVariants() {
        XCTAssertEqual(
            TranscriptDiff.phoneticKey("coffee"), TranscriptDiff.phoneticKey("koffi"))
        XCTAssertEqual(
            TranscriptDiff.phoneticKey("cuber netties"), TranscriptDiff.phoneticKey("kubernetes"))
        XCTAssertEqual(
            TranscriptDiff.phoneticKey("swift UI"), TranscriptDiff.phoneticKey("SwiftUI"))
    }

    /// Vowels are folded rather than dropped so genuinely different words stay different.
    func testPhoneticKeyKeepsDistinctWordsDistinct() {
        XCTAssertNotEqual(
            TranscriptDiff.phoneticKey("Marcus"), TranscriptDiff.phoneticKey("Priya"))
        XCTAssertNotEqual(
            TranscriptDiff.phoneticKey("staging"), TranscriptDiff.phoneticKey("production"))
    }
}
