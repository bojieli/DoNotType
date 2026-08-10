import Foundation
import XCTest

@testable import DoNotTypeCore

/// Swift is the reference implementation, so this suite's job is narrower than the other three:
/// it catches a change to `ContextEncoder` that was not meant to change the contract.
///
/// Regenerate deliberately with `swift run dnt-eval conformance --write`, then run the Kotlin and
/// C# suites before committing. A golden file that rewrites itself on mismatch records the bug
/// instead of catching it, which is why nothing here offers to do that for you.
final class ConformanceTests: XCTestCase {
    private func fixtures() throws -> (cases: [ConformanceFixture.Case],
                                       expected: [ConformanceFixture.Expectation])
    {
        guard let directory = ConformanceFixture.directory() else {
            throw XCTSkip("eval/conformance not found from the test working directory")
        }
        return (
            try ConformanceFixture.loadCases(from: directory.appendingPathComponent("contexts.json")),
            try ConformanceFixture.loadExpectations(
                from: directory.appendingPathComponent("golden.json"))
        )
    }

    func testEncoderMatchesTheGoldenFile() throws {
        let (cases, expected) = try fixtures()
        let produced = ConformanceFixture.encode(cases)

        XCTAssertEqual(produced.count, expected.count, "fixture and golden are out of step")

        for (actual, want) in zip(produced, expected) {
            XCTAssertEqual(actual.id, want.id)
            XCTAssertEqual(
                actual.parts, want.parts,
                "\(want.id): \(want.why)\n"
                    + "If this change was intended, regenerate with "
                    + "`swift run dnt-eval conformance --write` and re-run the Kotlin and C# suites.")
        }
    }

    /// The properties the other ports are most likely to get wrong, asserted against the golden
    /// rather than against the encoder — so a port author can read them as a specification.
    func testGoldenEncodesTheRulesThePortsMustFollow() throws {
        let (_, expected) = try fixtures()
        func golden(_ id: String) throws -> ConformanceFixture.Expectation {
            try XCTUnwrap(expected.first { $0.id == id })
        }

        // Context first, and the header opens it.
        let identity = try golden("02-full-identity")
        XCTAssertTrue(identity.parts[0].text?.hasPrefix(ContextEncoder.header) == true)

        // Nothing worth sending produces no parts at all, not an empty header.
        XCTAssertTrue(try golden("12-empty").parts.isEmpty)

        // Thin accessibility text is dropped without a screenshot and kept with one — the
        // screenshot is the reason the text is thin.
        XCTAssertFalse(
            try golden("05-thin-text-no-screenshot").parts[1].text?.contains("VISIBLE TEXT") == true)
        let withShot = try golden("06-thin-text-with-screenshot")
        XCTAssertEqual(withShot.parts[1].type, "image", "the image sits between the two text parts")
        XCTAssertTrue(withShot.parts[2].text?.contains("VISIBLE TEXT") == true)

        // Clipping keeps the tail of what precedes the caret: the end is the part nearest it.
        let long = try golden("11-long-visible-text")
        let body = try XCTUnwrap(long.parts[1].text)
        XCTAssertTrue(body.contains("line 400:"), "the tail must survive")
        XCTAssertFalse(body.contains("line 1:"), "the head is what gets dropped")

        // Whitespace is not content.
        let blank = try golden("10-whitespace-only-fields")
        XCTAssertFalse(blank.parts[0].text?.contains("URL:") == true)
        XCTAssertFalse(blank.parts[1].text?.contains("SELECTED TEXT") == true)

        // The footer restates the content rule immediately before the audio, and must never name a
        // concrete value — an earlier version that did made substitution worse.
        for expectation in expected where !expectation.parts.isEmpty {
            let last = try XCTUnwrap(expectation.parts.last?.text)
            XCTAssertTrue(last.hasSuffix("The audio that follows is the ONLY thing to transcribe."))
        }
    }

    /// Every case must justify itself, or the fixture set decays into cases nobody dares delete.
    func testEveryFixtureExplainsWhatItIsFor() throws {
        let (cases, _) = try fixtures()
        for testCase in cases {
            XCTAssertFalse(testCase.why.isEmpty, "\(testCase.id) has no rationale")
        }
    }
}
