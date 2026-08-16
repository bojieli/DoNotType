import Foundation
import XCTest

@testable import DoNotTypeCore

/// The bars in the recording pill.
///
/// Asserted against the same recordings the rest of the pipeline is asserted against, because the
/// claim being made is about what a voice looks like on this scale — and a meter argued from
/// invented arrays would prove only that arithmetic works. See `eval/audio/MANIFEST.md`.
final class AudioLevelMeterTests: XCTestCase {
    /// Every fixture with somebody talking in it.
    private static let speechFixtures = [
        "eval/audio/gemini-version.wav",
        "eval/audio/git-command.wav",
        "eval/audio/jargon-spelling.wav",
        "eval/audio/novel-codename.wav",
        "eval/audio/novel-name.wav",
        "eval/audio/novel-repo.wav",
        "eval/audio/person-name.wav",
        "eval/audio/port-number.wav",
        "eval/audio/real-acronym-chain.wav",
        "eval/audio/real-acronym.wav",
        "eval/audio/real-brand.wav",
        "eval/audio/real-codeswitch.wav",
        "eval/audio/real-jargon.wav",
        "eval/audio/real-mandarin.wav",
        "eval/audio/real-talk-gemini15.wav",
        "eval/audio/formats/speech.wav",
    ]

    private func fixture(_ path: String) throws -> Data {
        var directory = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 {
            directory.deleteLastPathComponent()
            let candidate = directory.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try Data(contentsOf: candidate)
            }
        }
        throw XCTSkip("fixture \(path) not found")
    }

    /// The bars a whole recording would draw, in order.
    private func bars(of path: String) throws -> [AudioLevelMeter.Bar] {
        let wav = try fixture(path)
        guard let body = AudioChunker.pcmBody(of: wav) else {
            throw XCTSkip("\(path) is not a WAV this test can read")
        }
        var meter = AudioLevelMeter()
        return meter.append(samples(of: body))
    }

    private func samples(of pcm: Data) -> [Int16] {
        pcm.withUnsafeBytes { raw in
            raw.bindMemory(to: Int16.self).map { Int16(littleEndian: $0) }
        }
    }

    private func percentile(_ values: [Double], _ fraction: Double) -> Double {
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * fraction))]
    }

    // MARK: - The scale

    /// The table in `AudioLevelMeter`'s documentation, which is where the span came from.
    func testTheScaleIsTheDocumentedTable() {
        let expected: [(decibels: Double, level: Double)] = [
            (-240, 0.00),  // digital silence
            (-58, 0.04),  // room tone
            (-44, 0.30),  // quiet speech
            (-21, 0.72),  // conversational speech
            (-14, 0.85),  // loud speech
            (-5, 1.00),  // the loudest frame in any fixture
        ]
        for (decibels, level) in expected {
            XCTAssertEqual(
                AudioLevelMeter.bar(decibels: decibels).level, level, accuracy: 0.01,
                "\(decibels) dBFS should draw \(level) of a bar")
        }
    }

    func testTheScaleIsClampedAtBothEnds() {
        XCTAssertEqual(AudioLevelMeter.bar(decibels: -120).level, 0)
        XCTAssertEqual(AudioLevelMeter.bar(decibels: AudioLevelMeter.floorDecibels).level, 0)
        XCTAssertEqual(AudioLevelMeter.bar(decibels: AudioLevelMeter.ceilingDecibels).level, 1)
        XCTAssertEqual(AudioLevelMeter.bar(decibels: 0).level, 1)
    }

    /// Full scale is where the recording is being damaged, and only there.
    func testClippingIsMarkedOnlyAtTheTop() {
        XCTAssertTrue(AudioLevelMeter.bar(decibels: 0).isClipping)
        XCTAssertTrue(AudioLevelMeter.bar(decibels: AudioLevelMeter.clippingDecibels).isClipping)
        XCTAssertFalse(AudioLevelMeter.bar(decibels: -4).isClipping)
        // Loud speech is not clipping, or the warning would mean nothing.
        XCTAssertFalse(AudioLevelMeter.bar(decibels: -14).isClipping)
    }

    func testFullScaleAudioClips() {
        var meter = AudioLevelMeter()
        let loud = [Int16](repeating: 32_000, count: 16_000)
        let bars = meter.append(loud)
        XCTAssertFalse(bars.isEmpty)
        XCTAssertTrue(bars.allSatisfy { $0.isClipping && $0.level == 1 })
    }

    // MARK: - What a voice looks like

    /// The failure the decibel scale exists to fix.
    ///
    /// The old meter was `min(1, rms * 6)`, which pinned 4–77% of the speaking frames of these
    /// same fixtures flat against the ceiling — so it could say "sound is arriving" and nothing
    /// else. A voice recorded at a sane level should reach the top of the meter rarely enough that
    /// arriving there still means something: measured, one bar in 333 in the loudest fixture, and
    /// none at all in the other fifteen.
    func testSpeechBarelyEverPinsTheMeter() throws {
        for path in Self.speechFixtures {
            let levels = try bars(of: path).map(\.level)
            let pinned = Double(levels.filter { $0 >= 0.999 }.count) / Double(levels.count)
            XCTAssertLessThan(
                pinned, 0.01,
                "\(path) spends \(String(format: "%.0f%%", pinned * 100)) of itself at full scale")
            XCTAssertFalse(
                try bars(of: path).contains { $0.isClipping },
                "\(path) is a normally-recorded voice and should not be reported as clipping")
        }
    }

    /// Speech lives in the top of the meter, so the bars are tall enough to read at a glance.
    func testSpeechUsesTheTopOfTheMeter() throws {
        for path in Self.speechFixtures {
            let loudest = percentile(try bars(of: path).map(\.level), 0.90)
            XCTAssertGreaterThan(
                loudest, 0.6,
                "\(path) draws only \(String(format: "%.2f", loudest)) of a bar when it is loud")
        }
    }

    /// And moves inside it: a meter that is tall but static answers "is the mic on", not "how
    /// loud". Measured spread across these fixtures is 0.25–0.77 of the meter's height.
    func testTheMeterMovesWithTheVoice() throws {
        for path in Self.speechFixtures {
            let levels = try bars(of: path).map(\.level)
            let spread = percentile(levels, 0.90) - percentile(levels, 0.10)
            XCTAssertGreaterThan(
                spread, 0.20,
                "\(path) moves through only \(String(format: "%.2f", spread)) of the meter")
        }
    }

    /// A quiet room is flat. It is not *empty* — the meter reports level, and a room has one —
    /// but nothing in it should read as somebody speaking.
    func testAQuietRoomIsFlat() throws {
        for name in ["digital-silence", "room-tone", "too-short"] {
            let levels = try bars(of: "eval/audio/silence/\(name).wav").map(\.level)
            let loudest = levels.max() ?? 0
            XCTAssertLessThan(
                loudest, 0.10,
                "\(name) draws \(String(format: "%.2f", loudest)) of a bar")
        }
    }

    /// Steady noise is *not* flat, and should not be.
    ///
    /// `hum` and `steady-noise` sit at −34 dBFS, which is louder than quiet speech and reads as
    /// roughly half a bar. That is the honest answer to "how loud is the input", and it is exactly
    /// why the decision about whether to send a recording is `SpeechActivity`'s rather than this
    /// meter's: one measures volume, the other measures whether anybody spoke.
    func testSteadyNoiseIsShownAsTheVolumeItIs() throws {
        for name in ["hum", "steady-noise"] {
            let levels = try bars(of: "eval/audio/silence/\(name).wav").map(\.level)
            XCTAssertGreaterThan(levels.max() ?? 0, 0.3, "\(name) should be visible")
            XCTAssertFalse(
                try bars(of: "eval/audio/silence/\(name).wav").contains { $0.isClipping })
        }
    }

    // MARK: - Framing

    /// The audio tap hands over whatever size buffer it has, never a whole number of frames.
    func testPartialFramesAreCarriedAcrossCalls() throws {
        let wav = try fixture("eval/audio/formats/speech.wav")
        let pcm = try XCTUnwrap(AudioChunker.pcmBody(of: wav))
        let all = samples(of: pcm)

        var whole = AudioLevelMeter()
        let expected = whole.append(all)

        var chunked = AudioLevelMeter()
        var actual: [AudioLevelMeter.Bar] = []
        var index = 0
        // Deliberately coprime with the 320-sample frame, so every boundary lands mid-frame.
        for size in [7, 971, 4_099, 63].cycled(upTo: all.count) {
            let end = min(index + size, all.count)
            actual += chunked.append(all[index..<end])
            index = end
            if index == all.count { break }
        }

        XCTAssertEqual(actual, expected)
        XCTAssertFalse(expected.isEmpty)
    }

    func testAudioShorterThanOneBarDrawsNothingYet() {
        var meter = AudioLevelMeter()
        // Two frames of a three-frame bar.
        XCTAssertTrue(meter.append([Int16](repeating: 8_000, count: 640)).isEmpty)
        XCTAssertEqual(meter.append([Int16](repeating: 8_000, count: 320)).count, 1)
    }
}

extension Array where Element == Int {
    /// Repeats the sizes until they cover `total`, so the chunking test does not depend on the
    /// fixture's length.
    fileprivate func cycled(upTo total: Int) -> [Int] {
        var out: [Int] = []
        var covered = 0
        while covered < total {
            for size in self {
                out.append(size)
                covered += size
                if covered >= total { break }
            }
        }
        return out
    }
}
