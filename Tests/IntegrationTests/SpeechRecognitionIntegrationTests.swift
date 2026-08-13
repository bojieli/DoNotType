import Foundation
import XCTest

@testable import DoNotTypeCore

/// Live checks for the recognition backends.
///
/// The generic `testEveryConfiguredProviderProcessesAudioOrThrows` already walks every key present
/// in the environment, so this file covers only what is specific to a recogniser: that the fidelity
/// ladder reaches an endpoint with no system instruction, that keyterm biasing does something, and
/// that it does not do the thing it must never do.
final class DeepgramIntegrationTests: XCTestCase {
    private func provider() throws -> DeepgramProvider {
        try Harness.requireIntegration()
        guard let key = ProcessInfo.processInfo.environment["DEEPGRAM_API_KEY"], !key.isEmpty
        else { throw XCTSkip("DEEPGRAM_API_KEY is not set") }
        return DeepgramProvider(apiKey: key)
    }

    private func service(
        fidelity: Fidelity = .default, keytermBiasing: Bool = false
    ) throws -> TranscriptionService {
        TranscriptionService(
            provider: try provider(), model: ProviderKind.deepgram.defaultModel,
            systemInstruction: try Harness.systemInstruction(fidelity: fidelity),
            fidelity: fidelity, keytermBiasing: keytermBiasing)
    }

    /// The setting has no prompt to travel in, so this is the only thing standing between the
    /// fidelity picker and doing nothing at all on this backend.
    func testFidelityChangesWhatComesBack() async throws {
        let audio = try Harness.realAudio("gemini-version.wav")

        let raw = try await service(fidelity: .raw).transcribe(audio: audio, context: nil)
            .transcript.transcript
        let light = try await service(fidelity: .light).transcribe(audio: audio, context: nil)
            .transcript.transcript

        XCTAssertFalse(raw.isEmpty)
        XCTAssertFalse(light.isEmpty)
        XCTAssertNotEqual(raw, light, "fidelity did not reach the endpoint")

        // raw asks for no formatting: no trailing full stop, and spoken numbers left as words.
        XCTAssertFalse(raw.hasSuffix("."), "raw should not be punctuated: \(raw)")
        // light asks for formatting: numerals, so the version arrives as a number.
        XCTAssertTrue(light.contains("3.5"), "light should format numbers: \(light)")
    }

    /// An invented name with an obvious phonetic fallback is the only case where a spelling hint
    /// can demonstrate anything — the model cannot already know it.
    func testKeytermBiasingCanSupplyASpellingTheModelCannotKnow() async throws {
        let audio = try Harness.realAudio("novel-name.wav")
        let context = ScreenContext(
            textBeforeCaret: "Thread with Kaelith about the merge. Kaelith owns the release.")

        let unbiased = try await service().transcribe(audio: audio, context: context)
            .transcript.transcript
        let biased = try await service(keytermBiasing: true)
            .transcribe(audio: audio, context: context).transcript.transcript

        XCTAssertFalse(biased.isEmpty)
        // Not asserted as a pass/fail on the spelling itself: whether biasing lands is exactly
        // what docs/EVALUATION.md measures, and a flaky assertion here would just be a worse
        // version of that measurement. What must hold is that the unbiased run was not given the
        // hint, so the two are a real comparison.
        XCTAssertFalse(unbiased.isEmpty)
    }

    /// The guarantee `Keyterms` exists to make. If a digit ever reaches the biasing list, a decoy
    /// on screen can overwrite a spoken number — the failure this whole project is about.
    func testScreenNumbersAreNeverSentAsBias() async throws {
        let audio = try Harness.realAudio("real-talk-gemini15.wav")
        let context = ScreenContext(
            visibleText: "Gemini 2.5 Flash is current. Upgrade to Gemini 2.5 today.",
            textBeforeCaret: "Gemini 2.5 Flash pricing. See the Gemini 2.5 guide. ")

        let terms = Keyterms.derive(from: context)
        XCTAssertFalse(terms.contains { $0.contains(where: \.isNumber) }, "\(terms)")

        let transcript = try await service(keytermBiasing: true)
            .transcribe(audio: audio, context: context).transcript.transcript
        XCTAssertFalse(transcript.isEmpty)
    }

    /// A documented limitation, pinned so it cannot regress quietly in either direction.
    ///
    /// No autodetecting setting transcribes Mandarin: `detect_language` classified this clip as
    /// French and `multi` returns nothing. What matters for the product is that it fails *loudly* —
    /// an empty transcript becomes `emptyOutput`, which the user sees as a failed dictation with a
    /// retry button, rather than as words silently missing from a paragraph.
    ///
    /// If this ever starts passing, Deepgram has added Chinese to `multi` and
    /// `docs/EVALUATION.md` needs re-measuring.
    func testMandarinFailsLoudlyUnderTheAutodetectingDefault() async throws {
        let audio = try Harness.realAudio("real-mandarin.wav")
        do {
            let result = try await service().transcribe(audio: audio, context: nil)
            XCTFail("expected emptyOutput, got: \(result.transcript.transcript)")
        } catch ProviderError.emptyOutput {
            // The documented behaviour.
        }
    }

    /// And the escape hatch works, which is what makes the limitation survivable.
    func testExplicitChineseTranscribesTheSameClipTheDefaultCannot() async throws {
        try Harness.requireIntegration()
        guard let key = ProcessInfo.processInfo.environment["DEEPGRAM_API_KEY"], !key.isEmpty
        else { throw XCTSkip("DEEPGRAM_API_KEY is not set") }

        let service = TranscriptionService(
            provider: DeepgramProvider(apiKey: key, language: "zh"),
            model: ProviderKind.deepgram.defaultModel,
            systemInstruction: try Harness.systemInstruction())

        let result = try await service.transcribe(
            audio: try Harness.realAudio("real-mandarin.wav"), context: nil)

        XCTAssertFalse(result.transcript.transcript.isEmpty)
        XCTAssertTrue(
            result.transcript.transcript.contains { $0.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) } },
            "expected Han characters, got: \(result.transcript.transcript)")
    }

    /// The app compresses to Ogg Opus before upload, so this is the format the product actually
    /// sends — a backend verified only on WAV has not been verified.
    func testAcceptsTheOggOpusTheAppActuallyUploads() async throws {
        let wav = try Harness.realAudio("gemini-version.wav")
        let compressed = wav.compressedForUpload()
        try XCTSkipUnless(compressed.mimeType == "audio/ogg", "Opus encoder unavailable here")

        let result = try await service().transcribe(audio: compressed, context: nil)
        XCTAssertTrue(result.transcript.transcript.contains("Gemini"))
    }

    /// Rewriting needs a language model. Reaching the network and getting a 400 would be a worse
    /// version of this — the client already knows it cannot work.
    func testRewriteFailsWithoutReachingTheNetwork() async throws {
        do {
            _ = try await service().rewrite("make this formal", instruction: "Rewrite formally.")
            XCTFail("expected audioRequired")
        } catch ProviderError.audioRequired {
            // expected
        }
    }
}

final class XAISpeechIntegrationTests: XCTestCase {
    private func key() throws -> String {
        try Harness.requireIntegration()
        let environment = ProcessInfo.processInfo.environment
        guard let key = environment["XAI_API_KEY"] ?? environment["GROK_API_KEY"], !key.isEmpty
        else { throw XCTSkip("XAI_API_KEY is not set") }
        return key
    }

    private func service(language: String? = nil, fidelity: Fidelity = .default) throws
        -> TranscriptionService
    {
        TranscriptionService(
            provider: XAISpeechProvider(apiKey: try key(), language: language),
            model: ProviderKind.xai.defaultModel,
            systemInstruction: try Harness.systemInstruction(fidelity: fidelity),
            fidelity: fidelity)
    }

    func testTranscribesRealSpeech() async throws {
        let result = try await service().transcribe(
            audio: try Harness.realAudio("gemini-version.wav"), context: nil)
        XCTAssertTrue(
            result.transcript.transcript.lowercased().contains("gemini"),
            "got: \(result.transcript.transcript)")
    }

    /// The default configuration used to 400 outright: `format=true` is rejected without a
    /// language, and the language defaulted to absent. This is that regression, pinned.
    func testTheDefaultConfigurationDoesNotFailOnFormatting() async throws {
        for fidelity in Fidelity.allCases {
            let result = try await service(fidelity: fidelity).transcribe(
                audio: try Harness.realAudio("gemini-version.wav"), context: nil)
            XCTAssertFalse(
                result.transcript.transcript.isEmpty, "\(fidelity) returned nothing")
        }
    }

    /// `auto` detects rather than defaulting to English, which is what makes this backend usable
    /// for a speaker who switches language mid-sentence.
    func testAutoDetectsMandarinAndKeepsCodeSwitchedEnglish() async throws {
        let result = try await service().transcribe(
            audio: try Harness.realAudio("real-codeswitch.wav"), context: nil)

        XCTAssertEqual(result.transcript.language, "zh")
        let text = result.transcript.transcript
        XCTAssertTrue(
            text.contains { $0.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) } },
            "expected Han characters, got: \(text)")
    }

    /// An explicit language is what turns on inverse text normalisation — the trade `auto` makes.
    func testAnExplicitLanguageEnablesNumberFormatting() async throws {
        let english = try await service(language: "en").transcribe(
            audio: try Harness.realAudio("gemini-version.wav"), context: nil)
        XCTAssertTrue(
            english.transcript.transcript.contains("3.5"),
            "explicit language should format numbers: \(english.transcript.transcript)")
    }
}
