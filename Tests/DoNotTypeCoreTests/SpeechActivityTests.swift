import Foundation
import XCTest

@testable import DoNotTypeCore

/// The gate that stops silence reaching a model.
///
/// Asserted against real files rather than synthesised arrays inside the test, because the claim
/// being made is about recordings — and the fixtures are shared with the other platforms, so all
/// four are held to the same numbers. See `eval/audio/silence/README.md`.
final class SpeechActivityTests: XCTestCase {
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

    private func silence(_ name: String) throws -> Data {
        try fixture("eval/audio/silence/\(name).wav")
    }

    // MARK: - Nothing that is not speech gets through

    /// The whole point. Each of these, handed to a model, is an invitation to invent a sentence.
    func testNothingWithoutSpeechIsEverSent() throws {
        for name in ["digital-silence", "room-tone", "steady-noise", "hum", "too-short"] {
            let reading = SpeechActivity.measure(wav: try silence(name))
            XCTAssertFalse(
                reading.hasSpeech,
                "\(name) would have been sent to a model — \(reading.summary)")
            XCTAssertEqual(
                reading.speechMilliseconds, 0,
                "\(name) should register no speech at all — \(reading.summary)")
        }
    }

    /// A hum is loud — louder than quiet speech — and still not speech. Gating on volume would
    /// send this and drop somebody talking softly, which is the wrong way round.
    func testALoudHumIsStillNotSpeech() throws {
        let hum = SpeechActivity.measure(wav: try silence("hum"))
        let quiet = SpeechActivity.measure(pcm: attenuated(try speechPCM(), byDecibels: 30))

        XCTAssertFalse(hum.hasSpeech, hum.summary)
        XCTAssertTrue(quiet.hasSpeech, quiet.summary)
        XCTAssertGreaterThan(
            hum.peakDecibels, quiet.noiseFloorDecibels,
            "the hum really is the louder recording, which is what makes this test worth having")
    }

    /// One keyboard click has enormous dynamic range and lasts 20 ms. Duration is what separates
    /// it from speech, not level.
    func testAKeyboardClickIsNotASentence() throws {
        let reading = SpeechActivity.measure(wav: try silence("click"))
        XCTAssertFalse(reading.hasSpeech, reading.summary)
        XCTAssertLessThan(reading.speechMilliseconds, 100, reading.summary)
    }

    /// The recording that this gate was rebuilt around: one mouse click in a very quiet room.
    ///
    /// It defeats every structural test. 380 ms above the floor is past the 200 ms threshold, and
    /// a −37 dB transient over a −63 dB floor is 26 dB of dynamic range — in a silent room any
    /// sound clears a relative margin. What it does not have is a voice's spectrum.
    func testAMouseClickInAQuietRoomIsNotASentence() throws {
        let reading = SpeechActivity.measure(wav: try silence("mouse-click-quiet-room"))
        XCTAssertGreaterThan(
            reading.speechMilliseconds, SpeechActivity.minimumSpeechMilliseconds,
            "the premise of this test is that duration alone lets it through — \(reading.summary)")
        XCTAssertFalse(reading.hasSpeech, reading.summary)
    }

    // MARK: - Everything that is speech gets through

    /// The constraint on the spectral test, and the reason it only runs on short clips.
    ///
    /// "Yes." is a single 320 ms burst — the same duration and the same shape as the mouse click
    /// above. Any rule that separated them by length or by burst count would drop this, which is
    /// the unforgivable failure rather than the annoying one.
    func testAOneWordAnswerIsStillASentence() throws {
        let reading = SpeechActivity.measure(wav: try fixture("eval/audio/short-word.wav"))
        XCTAssertLessThan(
            reading.speechMilliseconds, SpeechActivity.strongSpeechMilliseconds,
            "this has to be short enough that the spectral test is what admits it — \(reading.summary)")
        XCTAssertTrue(reading.hasSpeech, reading.summary)
    }

    /// Stated as a number so narrowing it has to be an argument rather than an edit. Calibrated on
    /// two voices and two clicks, which is why the gap is the whole of the evidence.
    func testTheVoiceBandSeparatesAClickFromAVoice() throws {
        let click = SpeechActivity.measure(wav: try silence("mouse-click-quiet-room"))
        let word = SpeechActivity.measure(wav: try fixture("eval/audio/short-word.wav"))

        XCTAssertLessThan(click.voiceBandRatio, SpeechActivity.minimumVoiceBandRatio, click.summary)
        XCTAssertGreaterThan(word.voiceBandRatio, SpeechActivity.minimumVoiceBandRatio, word.summary)
        XCTAssertGreaterThan(
            word.voiceBandRatio - click.voiceBandRatio, 0.08,
            "the threshold is only defensible while these are far apart")
    }

    /// A long dictation must never reach the spectral test at all — that is what confines a
    /// heuristic calibrated on two voices to the cases where the other evidence is already weak.
    func testRealDictationNeverReachesTheSpectralTest() throws {
        let reading = SpeechActivity.measure(pcm: try speechPCM())
        XCTAssertGreaterThanOrEqual(
            reading.speechMilliseconds, SpeechActivity.strongSpeechMilliseconds, reading.summary)
    }

    /// The failure that would matter more than the one this prevents. A stray "Thank you." is
    /// annoying; dropping a sentence somebody said is unforgivable.
    func testRealSpeechIsAlwaysSent() throws {
        let reading = SpeechActivity.measure(pcm: try speechPCM())
        XCTAssertTrue(reading.hasSpeech, reading.summary)
        XCTAssertGreaterThan(reading.speechMilliseconds, 800, reading.summary)
    }

    /// Somebody dictating quietly in an open-plan office, or a microphone with its gain low.
    func testQuietSpeechIsStillSpeech() throws {
        let speech = try speechPCM()
        for attenuation in [12, 20, 32, 40, 46] {
            let reading = SpeechActivity.measure(
                pcm: attenuated(speech, byDecibels: Double(attenuation)))
            XCTAssertTrue(
                reading.hasSpeech,
                "speech at −\(attenuation) dB would have been dropped — \(reading.summary)")
        }
    }

    /// The margin between the two, stated as a number so a change to the threshold has to argue
    /// with it rather than quietly narrow it.
    func testTheMarginBetweenSpeechAndNoiseIsWide() throws {
        let loudestNoise = try ["digital-silence", "room-tone", "steady-noise", "hum", "click"]
            .map { SpeechActivity.measure(wav: try silence($0)).speechMilliseconds }
            .max() ?? 0
        let quietestSpeech = SpeechActivity.measure(
            pcm: attenuated(try speechPCM(), byDecibels: 46)).speechMilliseconds

        XCTAssertLessThanOrEqual(loudestNoise, 100)
        XCTAssertGreaterThanOrEqual(quietestSpeech, 400)
        XCTAssertGreaterThan(
            quietestSpeech, loudestNoise * 4,
            "the threshold is only defensible while these are far apart")
    }

    // MARK: - Shape

    func testAnEmptyRecordingIsNotSpeech() {
        XCTAssertFalse(SpeechActivity.measure(pcm: Data()).hasSpeech)
        XCTAssertFalse(SpeechActivity.measure(wav: Data()).hasSpeech)
    }

    /// A recording shorter than one frame cannot be measured, and must not be assumed to be speech.
    func testAFragmentShorterThanAFrameIsNotSpeech() {
        let tenMilliseconds = Data(count: 16_000 / 100 * 2)
        XCTAssertFalse(SpeechActivity.measure(pcm: tenMilliseconds).hasSpeech)
    }

    func testTheSummaryCarriesTheNumbersSomebodyWouldArgueWith() throws {
        let summary = SpeechActivity.measure(pcm: try speechPCM()).summary
        XCTAssertTrue(summary.contains("speech="), summary)
        XCTAssertTrue(summary.contains("floor="), summary)
        XCTAssertTrue(summary.contains("peak="), summary)
    }

    // MARK: - Helpers

    private func speechPCM() throws -> Data {
        let wav = try fixture("eval/audio/formats/speech.wav")
        return try XCTUnwrap(AudioChunker.pcmBody(of: wav))
    }

    private func attenuated(_ pcm: Data, byDecibels decibels: Double) -> Data {
        let factor = pow(10.0, -decibels / 20.0)
        var out = Data(capacity: pcm.count)
        pcm.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for index in 0..<(pcm.count / 2) {
                let scaled = Int16(
                    (Double(Int16(littleEndian: samples[index])) * factor)
                        .rounded()
                        .clamped(to: -32_768...32_767))
                withUnsafeBytes(of: scaled.littleEndian) { out.append(contentsOf: $0) }
            }
        }
        return out
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
