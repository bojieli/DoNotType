import XCTest

@testable import DoNotTypeCore

/// The numbers here come from real dictations this app stored, not from invented examples — see
/// `HallucinationGuard`'s own notes for the recordings.
final class HallucinationGuardTests: XCTestCase {

    // MARK: - The marker

    func testTheExactMarkerIsRecognised() {
        XCTAssertTrue(HallucinationGuard.isNoSpeechMarker("[NO_SPEECH]"))
    }

    func testTheMarkerSurvivesTheDecorationModelsAddToIt() {
        for variant in ["[NO_SPEECH].", " [NO_SPEECH] ", "\"[NO_SPEECH]\"", "[no_speech]", "NO_SPEECH"] {
            XCTAssertTrue(HallucinationGuard.isNoSpeechMarker(variant), variant)
        }
    }

    /// The strictness is the point: a loose match on the words would delete a real dictation of
    /// somebody saying them.
    func testSpeechAboutNoSpeechIsNotTheMarker() {
        for real in [
            "No speech was detected in the recording.",
            "there was no speech",
            "The [NO_SPEECH] token is what the model writes.",
        ] {
            XCTAssertFalse(HallucinationGuard.isNoSpeechMarker(real), real)
        }
    }

    func testTheMarkerBecomesAnEmptyTranscript() {
        let (transcript, verdict) = HallucinationGuard.inspect(
            Transcript(transcript: "[NO_SPEECH]", language: "en"), audioSeconds: 0.7)
        XCTAssertEqual(transcript.transcript, "")
        XCTAssertEqual(verdict, .noSpeechMarker)
        XCTAssertEqual(transcript.language, "en", "the language is still what the model reported")
    }

    // MARK: - The rate ceiling

    /// 876 characters from 0.68 seconds of room tone: 1288 characters a second.
    func testTheMeasuredFabricationIsCaught() {
        let fabricated = String(repeating: "a", count: 876)
        XCTAssertTrue(
            HallucinationGuard.exceedsPlausibleRate(fabricated, audioSeconds: 0.68))
    }

    /// Every real dictation measured through this app, at its recorded length.
    func testRealDictationsAreKept() {
        let real: [(characters: Int, seconds: Double)] = [
            (27, 3.37), (72, 8.18), (100, 14.58), (221, 32.20), (244, 32.37), (30, 2.03),
        ]
        for sample in real {
            let text = String(repeating: "a", count: sample.characters)
            XCTAssertFalse(
                HallucinationGuard.exceedsPlausibleRate(text, audioSeconds: sample.seconds),
                "\(sample.characters) chars in \(sample.seconds)s should be plausible")
        }
    }

    /// A fast speaker is roughly 17 characters a second; the ceiling has to sit above them.
    func testAFastSpeakerIsNotSuppressed() {
        let text = String(repeating: "a", count: 170)
        XCTAssertFalse(HallucinationGuard.exceedsPlausibleRate(text, audioSeconds: 10))
    }

    /// One long word in one second is a high rate and completely real, which is what the length
    /// floor exists for.
    func testAShortClipWithOneLongWordIsKept() {
        XCTAssertFalse(
            HallucinationGuard.exceedsPlausibleRate("internationalisation", audioSeconds: 1))
    }

    /// The case that caught the first threshold: an ordinary sentence over two seconds of audio is
    /// 35 characters a second and entirely real. Six of this project's own fixtures look like this.
    func testAnOrdinarySentenceOverShortAudioIsKept() {
        let sentence = "I said the version is three point five, and Kaelith owns the rollout."
        XCTAssertTrue(Double(sentence.count) > HallucinationGuard.maximumCharactersPerSecond * 2)
        XCTAssertFalse(HallucinationGuard.exceedsPlausibleRate(sentence, audioSeconds: 2))
    }

    func testUnknownDurationIsNeverSuspicious() {
        let fabricated = String(repeating: "a", count: 2000)
        XCTAssertFalse(HallucinationGuard.exceedsPlausibleRate(fabricated, audioSeconds: nil))
        XCTAssertFalse(HallucinationGuard.exceedsPlausibleRate(fabricated, audioSeconds: 0))
    }

    func testTheVerdictCarriesTheMeasurement() {
        let (transcript, verdict) = HallucinationGuard.inspect(
            Transcript(transcript: String(repeating: "a", count: 625), language: "en"),
            audioSeconds: 0.76)
        XCTAssertEqual(transcript.transcript, "")
        guard case .impossibleRate(let characters, let seconds) = verdict else {
            return XCTFail("expected an impossibleRate verdict, got \(verdict)")
        }
        XCTAssertEqual(characters, 625)
        XCTAssertEqual(seconds, 0.76, accuracy: 0.001)
        XCTAssertTrue(verdict.summary.contains("822"), "summary should show the rate: \(verdict.summary)")
    }

    func testAnOrdinaryTranscriptPassesThroughUntouched() {
        let original = Transcript(transcript: "Could you rebuild and reinstall the app?", language: "en")
        let (transcript, verdict) = HallucinationGuard.inspect(original, audioSeconds: 8.18)
        XCTAssertEqual(transcript, original)
        XCTAssertEqual(verdict, .kept)
    }
}
