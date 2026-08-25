import XCTest

@testable import DoNotTypeCore

/// The specific mistake the distance penalty used to make, asserted through `bestBoundary` rather
/// than through the score, because the outcome is the contract and the formula is not.
///
/// Old form: `… - abs(seconds - target)`. Linear, unbounded, and in the same units as nothing else
/// in the score, so it dominated every quality term at any realistic target.
final class BoundaryScoreTests: XCTestCase {
    private let format = AudioChunker.Format()

    /// Speech at a steady level, with silent runs punched into it at chosen places.
    ///
    /// Ordinary pauses are added early on and never near a candidate position. They are not
    /// decoration: the floor is the 2nd percentile of frame energy, so a fixture whose only quiet
    /// is the pause under test estimates its floor from *speech* and then finds no speech at all.
    /// Real dictation is 39% to 86% pause — see the corpus figures in docs/INCREMENTAL.md — and a
    /// fixture with less than 2% cannot exercise this code.
    private func audio(seconds: Double, pauses: [(at: Double, length: Double)]) -> Data {
        let background: [(at: Double, length: Double)] = [
            (at: 4, length: 0.7), (at: 12, length: 0.7), (at: 22, length: 0.7),
            (at: 32, length: 0.7), (at: 90, length: 0.7),
        ]
        return render(seconds: seconds, pauses: pauses + background)
    }

    private func render(seconds: Double, pauses: [(at: Double, length: Double)]) -> Data {
        let total = Int(seconds * Double(format.bytesPerSecond)) / 2
        var samples = [Int16](repeating: 0, count: total)
        for index in 0..<total {
            // Deterministic and loud, so the 2nd-percentile floor sits well below it.
            samples[index] = Int16(truncatingIfNeeded: (index % 97) * 300 - 14_000)
        }
        for pause in pauses {
            let start = Int(pause.at * Double(format.sampleRate))
            let end = min(total, start + Int(pause.length * Double(format.sampleRate)))
            guard start < end else { continue }
            for index in start..<end { samples[index] = 0 }
        }
        return samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// A clean sentence break inside the window beats a shallow breath sitting on the target.
    ///
    /// Under the old scorer the 0.4 s pause at the target won, because being 12 s away cost the
    /// 1.4 s pause twelve points and nothing in the score could ever repay that.
    func testALongPauseInsideTheWindowBeatsAShortOneOnTheTarget() throws {
        let policy = AudioChunker.BoundaryPolicy()
        let body = audio(
            seconds: 100,
            pauses: [(at: 48, length: 1.4), (at: 60, length: 0.4)])
        let cut = try XCTUnwrap(
            AudioChunker.bestBoundary(in: body, format: format, policy: policy))
        let seconds = Double(cut) / Double(format.bytesPerSecond)
        XCTAssertEqual(seconds, 48.7, accuracy: 0.6, "expected the 1.4 s pause near 48 s")
    }

    /// Distance still breaks ties, so chunks stay evenly sized when quality is equal.
    func testAmongEquallyGoodPausesTheOneNearestTheTargetWins() throws {
        let policy = AudioChunker.BoundaryPolicy()
        let body = audio(
            seconds: 100,
            pauses: [(at: 47, length: 1.0), (at: 59, length: 1.0)])
        let cut = try XCTUnwrap(
            AudioChunker.bestBoundary(in: body, format: format, policy: policy))
        let seconds = Double(cut) / Double(format.bytesPerSecond)
        XCTAssertEqual(seconds, 59.5, accuracy: 0.6, "expected the pause nearest the 60 s target")
    }

    /// The window is what the policy already called acceptable; the penalty may not overrule a
    /// much better pause inside it, but it must not reach outside it either.
    func testAPauseBeforeTheMinimumIsStillIneligible() throws {
        let policy = AudioChunker.BoundaryPolicy()
        let body = audio(
            seconds: 100,
            pauses: [(at: 20, length: 3.0), (at: 58, length: 0.5)])
        let cut = try XCTUnwrap(
            AudioChunker.bestBoundary(in: body, format: format, policy: policy))
        let seconds = Double(cut) / Double(format.bytesPerSecond)
        XCTAssertGreaterThanOrEqual(
            seconds, policy.minimum, "a 3 s pause before the minimum is not a candidate")
    }

    /// No qualified pause, no cut — a latency optimisation may never manufacture a mid-word cut.
    func testSpeechWithNoQualifiedPauseYieldsNoBoundary() {
        let body = render(seconds: 100, pauses: [])
        XCTAssertNil(AudioChunker.bestBoundary(in: body, format: format))
    }
}
