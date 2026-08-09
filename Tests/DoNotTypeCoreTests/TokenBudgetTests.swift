import XCTest

@testable import DoNotTypeCore

final class TokenBudgetTests: XCTestCase {
    func testEstimateIsZeroForEmpty() {
        XCTAssertEqual(TokenBudget.estimate(""), 0)
    }

    func testProseUsesWordAndCharBounds() {
        // 5 words, 23 chars -> max(6.5, 5.75) = 7
        XCTAssertEqual(TokenBudget.estimate("the quick brown fox jumps"), 7)
    }

    func testCJKDenseTextUsesTheDenserBranch() {
        let han = String(repeating: "中", count: 100)
        // 100 / 1.3 = 77 tokens, far denser than the 25 the prose branch would give.
        XCTAssertEqual(TokenBudget.estimate(han), 77)
    }

    func testMixedTextBelowThresholdStaysOnProseBranch() {
        // 2 Han in 20 chars is 10%, under the 30% cutoff.
        let mixed = "hello world 中文 abcd"
        XCTAssertEqual(TokenBudget.estimate(mixed), TokenBudget.estimate(mixed))
        XCTAssertLessThan(TokenBudget.estimate(mixed), 20)
    }

    /// The direction that matters: the caret is at the end, so the end is what we keep.
    func testTruncationKeepsTheTail() {
        let text = (1...200).map { "word\($0)" }.joined(separator: " ")
        let cut = TokenBudget.truncateKeepingTail(text, maxTokens: 20)

        XCTAssertTrue(cut.hasSuffix("word200"), "must keep the end nearest the caret")
        XCTAssertFalse(cut.contains("word1 "), "must drop the far beginning")
        XCTAssertLessThanOrEqual(TokenBudget.estimate(cut), 20)
    }

    func testTruncationIsIdentityWhenAlreadyUnderBudget() {
        XCTAssertEqual(TokenBudget.truncateKeepingTail("short", maxTokens: 100), "short")
    }

    func testTruncationToZeroBudgetIsEmpty() {
        XCTAssertEqual(TokenBudget.truncateKeepingTail("anything", maxTokens: 0), "")
    }

    func testClipDirections() {
        XCTAssertEqual(TokenBudget.clipKeepingTail("abcdefgh", maxChars: 3), "fgh")
        XCTAssertEqual(TokenBudget.clipKeepingHead("abcdefgh", maxChars: 3), "abc")
        XCTAssertEqual(TokenBudget.clipKeepingTail("ab", maxChars: 10), "ab")
    }
}
