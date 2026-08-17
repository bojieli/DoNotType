import Foundation
import XCTest

@testable import DoNotTypeCore

/// Silero is asserted against recordings rather than mocked probabilities. These fixtures are
/// shared with the other clients, so a model/runtime/normalisation mistake cannot pass as long as
/// the post-processing state machine happens to be correct.
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

    func testNothingWithoutSpeechIsEverSent() throws {
        for name in ["digital-silence", "room-tone", "steady-noise", "hum", "too-short"] {
            let reading = try SpeechActivity.measure(wav: silence(name))
            XCTAssertFalse(
                reading.hasSpeech,
                "\(name) would have been sent to a model — \(reading.summary)")
            XCTAssertEqual(reading.speechMilliseconds, 0, reading.summary)
            XCTAssertLessThan(reading.maximumProbability, 0.2, reading.summary)
        }
    }

    func testKeyboardAndMouseClicksAreNotSentences() throws {
        for name in ["click", "mouse-click-quiet-room"] {
            let reading = try SpeechActivity.measure(wav: silence(name))
            XCTAssertFalse(reading.hasSpeech, "\(name) — \(reading.summary)")
            XCTAssertLessThan(reading.maximumProbability, 0.2, reading.summary)
        }
    }

    // MARK: - Everything that is speech gets through

    func testAOneWordAnswerIsStillASentence() throws {
        let reading = try SpeechActivity.measure(wav: fixture("eval/audio/short-word.wav"))
        XCTAssertTrue(reading.hasSpeech, reading.summary)
        XCTAssertGreaterThan(reading.maximumProbability, 0.9, reading.summary)
        XCTAssertGreaterThanOrEqual(
            reading.speechMilliseconds, SpeechActivity.minimumSpeechMilliseconds,
            reading.summary)
    }

    func testRealSpeechIsAlwaysSent() throws {
        let reading = try SpeechActivity.measure(pcm: speechPCM())
        XCTAssertTrue(reading.hasSpeech, reading.summary)
        XCTAssertGreaterThan(reading.maximumProbability, 0.9, reading.summary)
    }

    /// Level-independent behaviour is a model property now, rather than something approximated
    /// by defining a threshold relative to the recording itself.
    func testQuietSpeechIsStillSpeech() throws {
        let speech = try speechPCM()
        for attenuation in [12, 20, 32, 40, 46, 52] {
            let reading = try SpeechActivity.measure(
                pcm: attenuated(speech, byDecibels: Double(attenuation)))
            XCTAssertTrue(
                reading.hasSpeech,
                "speech at −\(attenuation) dB would have been dropped — \(reading.summary)")
        }
    }

    /// The production failure this replacement is for. Aggressive microphone gain control can
    /// leave no quiet tenth of a recording: the old detector called the quieter parts of the voice
    /// its noise floor and rejected the whole utterance. Companding a real speech fixture emulates
    /// that narrow dynamic range while preserving its temporal and spectral shape.
    func testContinuousGainControlledSpeechNeedsNoQuietFloor() throws {
        let reading = try SpeechActivity.measure(pcm: companded(try speechPCM()))
        XCTAssertTrue(reading.hasSpeech, reading.summary)
        XCTAssertGreaterThan(reading.maximumProbability, 0.9, reading.summary)
    }

    // MARK: - Shape and diagnostics

    func testAnEmptyRecordingIsNotSpeech() throws {
        XCTAssertFalse(try SpeechActivity.measure(pcm: Data()).hasSpeech)
        XCTAssertThrowsError(try SpeechActivity.measure(wav: Data()))
    }

    func testAFragmentShorterThanTheMinimumIsNotSpeech() throws {
        let tenMilliseconds = Data(count: 16_000 / 100 * 2)
        XCTAssertFalse(try SpeechActivity.measure(pcm: tenMilliseconds).hasSpeech)
    }

    func testSummaryNamesTheDetectorAndCarriesProbabilities() throws {
        let summary = try SpeechActivity.measure(pcm: speechPCM()).summary
        XCTAssertTrue(summary.contains("silero"), summary)
        XCTAssertTrue(summary.contains("speech="), summary)
        XCTAssertTrue(summary.contains("max="), summary)
        XCTAssertTrue(summary.contains("mean="), summary)
    }

    // MARK: - Helpers

    private func speechPCM() throws -> Data {
        let wav = try fixture("eval/audio/formats/speech.wav")
        return try XCTUnwrap(AudioChunker.pcmBody(of: wav))
    }

    private func attenuated(_ pcm: Data, byDecibels decibels: Double) -> Data {
        let factor = pow(10.0, -decibels / 20.0)
        return mapSamples(pcm) { Double($0) * factor }
    }

    private func companded(_ pcm: Data) -> Data {
        mapSamples(pcm) { sample in
            let normalised = abs(Double(sample)) / 32_768
            let magnitude = pow(normalised, 0.2) * 12_000
            return sample < 0 ? -magnitude : magnitude
        }
    }

    private func mapSamples(_ pcm: Data, _ transform: (Int16) -> Double) -> Data {
        var out = Data(capacity: pcm.count)
        pcm.withUnsafeBytes { raw in
            for index in 0..<(pcm.count / 2) {
                let source = Int16(littleEndian: raw.loadUnaligned(
                    fromByteOffset: index * 2, as: Int16.self))
                let transformed = transform(source).rounded()
                let mapped = Int16(min(32_767, max(-32_768, transformed)))
                withUnsafeBytes(of: mapped.littleEndian) { out.append(contentsOf: $0) }
            }
        }
        return out
    }
}
