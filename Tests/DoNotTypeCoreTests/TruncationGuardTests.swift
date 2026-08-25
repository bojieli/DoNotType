import XCTest

@testable import DoNotTypeCore

/// The thresholds, pinned against the measurements that chose them.
///
/// Every number here is from 2026-08-25: 350 real dictations for the legitimate floor, and one
/// 90-second Mandarin recording that `gemini-3.5-flash` truncated on 6 runs in 10 for the failure.
/// If a constant moves, these tests say what it was traded against.
final class TruncationGuardTests: XCTestCase {

    /// The observed failure: ~100 characters where ~310 belonged, 49 s of Silero-confirmed speech.
    func testTheMeasuredTruncationIsCaught() {
        let verdict = TruncationGuard.inspect(String(repeating: "字", count: 98), speechSeconds: 49)
        XCTAssertTrue(verdict.isSuspect)
        XCTAssertEqual(verdict, .suspectedTruncation(characters: 98, speechSeconds: 49))
    }

    /// A complete run of the same recording, which must not be flagged.
    func testACompleteTranscriptOfTheSameRecordingIsKept() {
        for characters in [309, 381] {
            XCTAssertEqual(
                TruncationGuard.inspect(
                    String(repeating: "字", count: characters), speechSeconds: 49),
                .kept, "\(characters) characters")
        }
    }

    /// The lowest rate any of 350 real dictations reached was 4.92 characters a second of speech,
    /// and the slowest of them are Mandarin. The floor has to sit below that with room, or the
    /// guard fires on somebody's ordinary dictation.
    func testTheSlowestRealDictationMeasuredIsNotFlagged() {
        // 109 characters in 22.2 s of speech — the corpus minimum, 4.92 ch/s.
        XCTAssertEqual(
            TruncationGuard.inspect(String(repeating: "字", count: 109), speechSeconds: 22.2),
            .kept)
        XCTAssertLessThan(
            TruncationGuard.minimumCharactersPerSecond, 4.92,
            "the floor must sit below the slowest dictation actually measured")
    }

    /// Short clips make the ratio wild in both directions, and truncation is a long-audio failure.
    func testAShortClipIsNeverJudged() {
        XCTAssertEqual(TruncationGuard.inspect("hi", speechSeconds: 3), .kept)
        XCTAssertEqual(TruncationGuard.inspect("hi", speechSeconds: 19.9), .kept)
    }

    /// No measurement, no accusation — the same rule `HallucinationGuard` follows for a compressed
    /// recording whose length would cost a decode to learn.
    func testUnknownSpeechLengthIsNotSuspicious() {
        XCTAssertEqual(TruncationGuard.inspect("short", speechSeconds: nil), .kept)
    }

    /// An empty transcript is the `[NO_SPEECH]` path's business, not this one. Flagging it here
    /// would make a correctly-empty answer look like a truncated one.
    func testAnEmptyTranscriptIsLeftToTheOtherGuard() {
        XCTAssertEqual(TruncationGuard.inspect("", speechSeconds: 60), .kept)
        XCTAssertEqual(TruncationGuard.inspect("   ", speechSeconds: 60), .kept)
    }

    /// The screen exists to keep Silero off the other nine tenths of transcripts. It must admit
    /// the failure case and reject an ordinary one.
    func testTheCheapScreenAdmitsTheFailureAndSkipsOrdinaryTranscripts() {
        // The truncated run: 98 characters, 90 s recording — 1.09 ch/s of audio.
        XCTAssertTrue(
            TruncationGuard.warrantsInspection(
                String(repeating: "字", count: 98), audioSeconds: 90))
        // A median dictation, 7.57 ch/s of audio.
        XCTAssertFalse(
            TruncationGuard.warrantsInspection(
                String(repeating: "x", count: 681), audioSeconds: 90))
        XCTAssertFalse(TruncationGuard.warrantsInspection("anything", audioSeconds: nil))
    }

    /// The summary is what a log reader gets, so it has to carry the working rather than a verdict.
    func testTheSummaryShowsItsArithmetic() {
        let summary = TruncationGuard.Verdict
            .suspectedTruncation(characters: 98, speechSeconds: 49).summary
        XCTAssertTrue(summary.contains("98"))
        XCTAssertTrue(summary.contains("2.00"))
        XCTAssertTrue(summary.contains("3.50"))
    }
}
