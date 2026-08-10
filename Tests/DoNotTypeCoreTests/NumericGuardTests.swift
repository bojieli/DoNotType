import Foundation
import XCTest

@testable import DoNotTypeCore

final class NumericGuardTests: XCTestCase {
    /// The exact failure the suite keeps producing: the screen's version number wins over the
    /// speaker's.
    func testTheGroundedVersionNumberIsReplacedByTheSpokenOne() {
        let result = NumericGuard.reconcile(
            grounded: "We should use Gemini 2.5 Flash for this.",
            audioOnly: "We should use Gemini 1.5 Flash for this.")

        XCTAssertEqual(result.text, "We should use Gemini 1.5 Flash for this.")
        XCTAssertEqual(result.corrections.map(\.0), ["2.5"])
        XCTAssertEqual(result.corrections.map(\.1), ["1.5"])
    }

    /// The measured code-switch regression, verbatim from the suite output.
    func testTheCodeSwitchRegressionIsRepaired() {
        let result = NumericGuard.reconcile(
            grounded: "比如說這個是1024吧我印象里",
            audioOnly: "比如說這個是4240我印象裡")
        XCTAssertEqual(result.text, "比如說這個是4240吧我印象里")
    }

    /// Everything that is not a number must survive untouched — the grounded run is kept precisely
    /// because it spells names and jargon better.
    func testWordsAreNeverTakenFromTheAudioOnlyRun() {
        let result = NumericGuard.reconcile(
            grounded: "Deploy SwiftUI to Kubernetes on port 8080.",
            audioOnly: "Deploy swift UI to kubernetes on port 8080.")
        XCTAssertEqual(result.text, "Deploy SwiftUI to Kubernetes on port 8080.")
        XCTAssertTrue(result.corrections.isEmpty)
    }

    func testTranscriptsWithoutNumbersAreReturnedUnchanged() {
        let result = NumericGuard.reconcile(
            grounded: "Ship the pricing page", audioOnly: "ship the pricing page")
        XCTAssertEqual(result.text, "Ship the pricing page")
        XCTAssertFalse(result.skippedForMismatch)
    }

    /// The safety rule. If the two runs disagree about how many numbers there are, one of them
    /// dropped or invented a figure, and aligning by index would move a value somewhere it was
    /// never spoken — a worse failure than the one being fixed.
    func testMismatchedCountsLeaveTheTranscriptAlone() {
        let result = NumericGuard.reconcile(
            grounded: "Ports 80 and 443 are open.",
            audioOnly: "Port 443 is open.")

        XCTAssertEqual(result.text, "Ports 80 and 443 are open.")
        XCTAssertTrue(result.skippedForMismatch)
        XCTAssertTrue(result.corrections.isEmpty)
    }

    func testMultipleNumbersAreReplacedPositionally() {
        let result = NumericGuard.reconcile(
            grounded: "Scale from 2 to 16 replicas by 5 p.m.",
            audioOnly: "Scale from 2 to 12 replicas by 4 p.m.")
        XCTAssertEqual(result.text, "Scale from 2 to 12 replicas by 4 p.m.")
        XCTAssertEqual(result.corrections.count, 2, "the unchanged 2 is not a correction")
    }

    /// A trailing full stop is punctuation, not part of the number, or the sentence would lose it.
    func testSentencePunctuationIsNotSwallowedIntoTheNumber() {
        XCTAssertEqual(NumericGuard.numbers(in: "It costs 42."), ["42"])
        XCTAssertEqual(NumericGuard.numbers(in: "Use 3.5, not 3."), ["3.5", "3"])
    }

    func testSeparatorsInsideNumbersSurvive() {
        XCTAssertEqual(NumericGuard.numbers(in: "1,024 at 16:9 over 2024-01"),
                       ["1,024", "16:9", "2024-01"])
    }

    func testNumbersAttachedToWordsAreStillFound() {
        XCTAssertEqual(NumericGuard.numbers(in: "gpt-4o and v2 on port8080"), ["4", "2", "8080"])
    }

    /// The guard must be a no-op when both runs agree, or it would be adding risk for nothing.
    func testIdenticalTranscriptsAreUnchanged() {
        let text = "Deploy 3 replicas on port 8080 at 9:30."
        let result = NumericGuard.reconcile(grounded: text, audioOnly: text)
        XCTAssertEqual(result.text, text)
        XCTAssertTrue(result.corrections.isEmpty)
        XCTAssertFalse(result.skippedForMismatch)
    }

    /// An audio-only run that failed entirely must not be allowed to strip numbers from a good
    /// grounded transcript.
    func testAnEmptyAudioOnlyRunCannotDamageTheTranscript() {
        let result = NumericGuard.reconcile(grounded: "Use port 8080.", audioOnly: "")
        XCTAssertEqual(result.text, "Use port 8080.")
        XCTAssertTrue(result.skippedForMismatch)
    }
}
