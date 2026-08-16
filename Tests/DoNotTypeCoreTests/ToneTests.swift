import Foundation
import XCTest

@testable import DoNotTypeCore

/// Checks the cues by listening to them rather than by hashing them.
///
/// What matters about these two sounds is the pitch of each note and the direction between them —
/// that is the whole reason there are two — so the assertions measure exactly that, with a Goertzel
/// filter over each note in turn. Comparing bytes against a stored copy would pass just as happily
/// on a pair of sounds that had become indistinguishable to a listener, and would fail on a change
/// to the envelope that nobody could hear.
///
/// The Windows port runs the same measurements against its own output. That is the point: the two
/// suites agreeing on 392 → 523 and 392 → 294 is what stops the desktops drifting apart, and CI is
/// the only machine that ever runs both.
final class ToneTests: XCTestCase {
    private let sampleRate = 48_000.0

    // MARK: - Reading a WAV back

    private func samples(_ wav: Data) throws -> [Double] {
        let body = try XCTUnwrap(dataChunk(wav), "no data chunk")
        return stride(from: 0, to: body.count - 1, by: 2).map { index in
            let low = UInt16(body[body.startIndex + index])
            let high = UInt16(body[body.startIndex + index + 1])
            return Double(Int16(bitPattern: low | (high << 8))) / 32768
        }
    }

    private func dataChunk(_ wav: Data) -> Data? {
        var cursor = 12
        while cursor + 8 <= wav.count {
            let id = wav.subdata(in: cursor..<(cursor + 4))
            let size = Int(read32(wav, at: cursor + 4))
            if id == Data("data".utf8) {
                let start = cursor + 8
                return wav.subdata(in: start..<min(start + size, wav.count))
            }
            cursor += 8 + size + (size % 2)
        }
        return nil
    }

    private func read32(_ data: Data, at offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { value, byte in
            value | UInt32(data[data.startIndex + offset + byte]) << (8 * UInt32(byte))
        }
    }

    private func read16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[data.startIndex + offset]) | UInt16(data[data.startIndex + offset + 1]) << 8
    }

    // MARK: - Measuring a note

    /// The strongest frequency in a window, to the nearest hertz.
    ///
    /// A Goertzel filter costs one pass per candidate and needs no FFT, which keeps this readable
    /// in all the languages that have to run it. Sweeping whole hertz across the range the cues
    /// occupy is precise enough to tell a fourth from a fifth several times over.
    private func dominantFrequency(_ window: ArraySlice<Double>, from: Int = 200, to: Int = 700)
        -> Int
    {
        var best = (frequency: 0, power: -1.0)
        for candidate in from...to {
            let power = goertzel(window, frequency: Double(candidate))
            if power > best.power { best = (candidate, power) }
        }
        return best.frequency
    }

    private func goertzel(_ window: ArraySlice<Double>, frequency: Double) -> Double {
        let coefficient = 2 * cos(2 * .pi * frequency / sampleRate)
        var previous = 0.0
        var beforeThat = 0.0
        for sample in window {
            let current = sample + coefficient * previous - beforeThat
            beforeThat = previous
            previous = current
        }
        return previous * previous + beforeThat * beforeThat - coefficient * previous * beforeThat
    }

    /// The first note alone, then the second while the first has largely decayed away.
    private func notes(_ wav: Data) throws -> (first: Int, second: Int) {
        let all = try samples(wav)
        let firstWindow = all[0..<Int(0.12 * sampleRate)]
        let secondWindow = all[Int(0.16 * sampleRate)..<Int(0.30 * sampleRate)]
        return (dominantFrequency(firstWindow), dominantFrequency(secondWindow))
    }

    // MARK: - The contract

    /// G4 up a fourth to C5. Tolerance is a hertz either way for the analysis, not the synthesis.
    func testStartRisesAFourth() throws {
        let (first, second) = try notes(Tone.start())
        XCTAssertEqual(first, 392, accuracy: 1, "first note should be G4")
        XCTAssertEqual(second, 523, accuracy: 1, "second note should be C5")
        XCTAssertGreaterThan(second, first, "starting rises")
    }

    /// The same G4 down a fourth to D4.
    func testStopFallsAFourth() throws {
        let (first, second) = try notes(Tone.stop())
        XCTAssertEqual(first, 392, accuracy: 1, "first note should be G4")
        XCTAssertEqual(second, 294, accuracy: 1, "second note should be D4")
        XCTAssertLessThan(second, first, "stopping falls")
    }

    /// Both cues open on the same note, which is what makes them a pair rather than two sounds.
    func testBothCuesShareAnAnchor() throws {
        XCTAssertEqual(try notes(Tone.start()).first, try notes(Tone.stop()).first)
    }

    /// A cue that outlasts what it reports is worse than none: it is still sounding while you talk.
    func testEachCueIsUnderHalfASecond() throws {
        for wav in [Tone.start(), Tone.stop()] {
            let duration = Double(try samples(wav).count) / sampleRate
            XCTAssertEqual(duration, 0.44, accuracy: 0.01)
        }
    }

    /// Quiet on purpose — see `Tone.peak`. The floor matters as much as the ceiling: a cue nobody
    /// can hear over a keyboard has failed in the direction that looks like nothing being wrong.
    func testLevelSitsWellBelowFullScale() throws {
        for wav in [Tone.start(), Tone.stop()] {
            let loudest = try samples(wav).map(abs).max() ?? 0
            XCTAssertEqual(loudest, 0.12, accuracy: 0.005)
        }
    }

    /// `NSSound` and `SoundPlayer` both reject anything they cannot parse, and both do it silently
    /// at the point of playback rather than where the bytes were made.
    func testHeaderIsMono16BitPcmAt48kHz() throws {
        for wav in [Tone.start(), Tone.stop()] {
            XCTAssertEqual(wav.subdata(in: 0..<4), Data("RIFF".utf8))
            XCTAssertEqual(wav.subdata(in: 8..<12), Data("WAVE".utf8))
            XCTAssertEqual(read16(wav, at: 20), 1, "PCM")
            XCTAssertEqual(read16(wav, at: 22), 1, "mono")
            XCTAssertEqual(read32(wav, at: 24), 48_000)
            XCTAssertEqual(read16(wav, at: 34), 16, "bits per sample")
            XCTAssertEqual(Int(read32(wav, at: 4)), wav.count - 8, "RIFF size counts what follows")
        }
    }

    /// The onset is ramped for four milliseconds because a sine wave that starts at full amplitude
    /// is a step change in pressure, and a step is a click. This is that ramp.
    func testNoticeableOnsetClickIsRampedAway() throws {
        let opening = try samples(Tone.start())[0]
        XCTAssertLessThan(abs(opening), 0.01)
    }
}
