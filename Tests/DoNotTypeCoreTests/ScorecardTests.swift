import XCTest

@testable import DoNotTypeCore

/// The checks that make `dnt-eval rescore` worth running.
///
/// This file exists because its subject is a check that could not fail. The CI job it replaces
/// looked for a cassette filename nobody had committed, skipped itself when it was missing, and
/// reported success — and when finally pointed at a real cassette it found no take for any of 48
/// requests and still exited 0. A green tick meant nothing had been measured. So every assertion
/// here is about a failure path: an empty corpus, a renamed case, a moved count. A scorer whose
/// refusals are untested is the same promise in a smaller font.
final class ScorecardTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    /// One case asserting an exact transcript, which is the strictest thing the scorer does.
    private func writeCase(
        id: String = "a-case", expect: String = "port 8080", mustNotContain: [String]? = nil
    ) throws -> URL {
        let cases = directory.appendingPathComponent("nearmiss")
        try FileManager.default.createDirectory(at: cases, withIntermediateDirectories: true)
        var json: [String: Any] = [
            "id": id,
            "audio": "../audio/whatever.wav",
            "expectTranscript": expect,
            "context": ["appName": "Terminal"],
        ]
        if let mustNotContain {
            json["mustNotContain"] = mustNotContain
            json.removeValue(forKey: "expectTranscript")
        }
        try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
            .write(to: cases.appendingPathComponent("\(id).json"))
        return cases
    }

    private func scorecard(
        caseID: String = "a-case",
        entries: [(withContext: String, withoutContext: String)],
        summary: EvalScorecard.Summary? = nil,
        caseDirectory: String = "unused"
    ) -> EvalScorecard {
        let built = entries.enumerated().map { index, pair in
            EvalScorecard.Entry(
                caseID: caseID, pass: index,
                withContext: pair.withContext, withoutContext: pair.withoutContext)
        }
        return EvalScorecard(
            provenance: Cassette.Provenance(
                provider: "google", model: "m", fidelity: "light", recordedAt: Date(),
                promptDigest: "abc123"),
            caseDirectory: caseDirectory,
            summary: summary ?? EvalScorecard.Summary(
                runs: 0, passed: 0, improved: 0, regressed: 0, neutralCorrect: 0, neutralWrong: 0),
            entries: built)
    }

    // MARK: - The round trip

    func testStoredTranscriptsScoreTheSameWayALiveRunDid() throws {
        let cases = try writeCase()
        // Context fixed a wrong baseline: the definition of `improved`, and the reason the feature
        // is on by default.
        let card = scorecard(entries: [(withContext: "port 8080", withoutContext: "port 8081")])

        let byPass = try card.rescore(caseDirectory: cases)
        let all = byPass.flatMap { $0 }
        XCTAssertEqual(all.count, 1)
        XCTAssertTrue(all[0].passed)
        XCTAssertEqual(all[0].effect, .improved)
    }

    /// The per-pass spread is a number this suite reports; a scorecard that collapsed three passes
    /// into one list would report a spread of zero and look like a stable model.
    func testPassesSurviveTheRoundTripSeparately() throws {
        let cases = try writeCase()
        let card = scorecard(entries: [
            (withContext: "port 8080", withoutContext: "port 8081"),
            (withContext: "port 8081", withoutContext: "port 8081"),
            (withContext: "port 8080", withoutContext: "port 8080"),
        ])

        let byPass = try card.rescore(caseDirectory: cases)
        XCTAssertEqual(byPass.count, 3, "three recorded passes must re-score as three passes")
        XCTAssertEqual(byPass.map { $0.count }, [1, 1, 1])
        XCTAssertEqual(
            byPass.flatMap { $0 }.map(\.effect), [.improved, .neutralWrong, .neutralCorrect])
    }

    func testItSurvivesBeingWrittenAndReadBack() throws {
        let file = directory.appendingPathComponent("card.json")
        let original = scorecard(
            entries: [(withContext: "port 8080", withoutContext: "port 8081")],
            summary: EvalScorecard.Summary(
                runs: 1, passed: 1, improved: 1, regressed: 0, neutralCorrect: 0, neutralWrong: 0))
        try original.write(to: file)

        let read = try EvalScorecard.read(from: file)
        XCTAssertEqual(read.summary, original.summary)
        XCTAssertEqual(read.entries.count, 1)
        XCTAssertEqual(read.entries[0].withContext, "port 8080")
        XCTAssertEqual(read.provenance.promptDigest, "abc123")
    }

    // MARK: - The failures that were reported as passes

    /// The exact shape of the bug this replaces: nothing to score, and a green tick anyway.
    func testAnEmptyScorecardIsAFailureAndNotAVacuousPass() throws {
        let cases = try writeCase()
        let empty = scorecard(entries: [])

        XCTAssertThrowsError(try empty.rescore(caseDirectory: cases)) { error in
            let message = (error as? EvalScorecard.ScorecardError)?.errorDescription ?? ""
            XCTAssertTrue(
                message.contains("measures nothing"),
                "an empty scorecard must say why that is a failure, got: \(message)")
        }
    }

    /// Stored answers were graded against assertions that no longer exist, so they cannot be
    /// re-graded. Refusing is the only honest option — scoring them against a different case
    /// would produce a number with nothing behind it.
    func testARenamedCaseIsRefusedRatherThanSkipped() throws {
        let cases = try writeCase(id: "renamed-since")
        let card = scorecard(
            caseID: "the-old-name",
            entries: [(withContext: "port 8080", withoutContext: "port 8081")])

        XCTAssertThrowsError(try card.rescore(caseDirectory: cases)) { error in
            let message = (error as? EvalScorecard.ScorecardError)?.errorDescription ?? ""
            XCTAssertTrue(
                message.contains("the-old-name"),
                "the error must name the missing case, got: \(message)")
            XCTAssertTrue(
                message.contains("renamed-since"),
                "the error must list what is available, got: \(message)")
        }
    }

    /// The whole point: a change in how this project grades itself shows up as a changed count.
    func testAMovedCountIsDetectedAndNamed() throws {
        let recorded = EvalScorecard.Summary(
            runs: 3, passed: 2, improved: 1, regressed: 0, neutralCorrect: 1, neutralWrong: 1)
        let now = EvalScorecard.Summary(
            runs: 3, passed: 1, improved: 0, regressed: 1, neutralCorrect: 1, neutralWrong: 1)

        let differences = recorded.differences(from: now)
        XCTAssertEqual(differences, ["passed 2 → 1", "improved 1 → 0", "regressed 0 → 1"])
        XCTAssertTrue(recorded.differences(from: recorded).isEmpty)
    }

    /// A tightened assertion in a case file must move a count. If it does not, `rescore` is
    /// checking that the code runs and nothing more.
    func testTighteningACaseChangesTheVerdict() throws {
        let cases = try writeCase(expect: "port 8080")
        let card = scorecard(
            entries: [(withContext: "port 8080", withoutContext: "port 8081")],
            summary: EvalScorecard.Summary(
                runs: 1, passed: 1, improved: 1, regressed: 0, neutralCorrect: 0, neutralWrong: 0))
        XCTAssertTrue(
            card.summary.differences(
                from: EvalScorecard.Summary(outcomes: try card.rescore(caseDirectory: cases).flatMap { $0 })
            ).isEmpty)

        // Same stored transcripts, stricter ground truth. The pass must evaporate.
        _ = try writeCase(expect: "port 8080 exactly")
        let regraded = EvalScorecard.Summary(
            outcomes: try card.rescore(caseDirectory: cases).flatMap { $0 })
        XCTAssertEqual(
            card.summary.differences(from: regraded),
            ["passed 1 → 0", "improved 1 → 0", "neutral-wrong 0 → 1"])
    }

    /// An empty transcript is never a pass, whatever a case asserts. Guards the same hole the
    /// scorer already closed for live runs: `mustNotContain` alone is satisfied by no output at all.
    func testNoTranscriptIsNeverAPassEvenThroughAScorecard() throws {
        let cases = try writeCase(id: "fragments-only", mustNotContain: ["8081"])
        let card = scorecard(
            caseID: "fragments-only", entries: [(withContext: "", withoutContext: "")])

        let all = try card.rescore(caseDirectory: cases).flatMap { $0 }
        XCTAssertFalse(all[0].passed, "an empty transcript avoids every forbidden phrase")
        XCTAssertEqual(all[0].effect, .neutralWrong)
    }
}
