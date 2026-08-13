import XCTest

@testable import DoNotTypeCore

/// A provider that records what it was handed instead of sending it.
private final class RecordingProvider: TranscriptionProvider, @unchecked Sendable {
    let name = "recording"
    var groundingSupport: GroundingSupport = .multimodal
    private(set) var lastRequest: TranscriptionRequest?

    init(grounding: GroundingSupport) { self.groundingSupport = grounding }

    func grounding(forModel model: String) -> GroundingSupport { groundingSupport }

    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        lastRequest = request
        return TranscriptionResult(
            transcript: Transcript(transcript: "ok", language: "en"), usage: TokenUsage(),
            rawOutput: "ok")
    }
}

/// The guarantee that makes a recognition backend safe to offer: it is sent only what it can use,
/// and a dictation it produced is never recorded as though the screen had been read.
final class GroundingRoutingTests: XCTestCase {
    private let audio = AudioFile(data: Data("fake wav".utf8), mimeType: "audio/wav")
    /// Long enough to clear `ContextEncoder`'s thin-text threshold, below which visible text is
    /// dropped in favour of the screenshot path — a short fixture would silently test nothing.
    private let context = ScreenContext(
        appName: "Xcode",
        visibleText: """
            Migrating Brindlewood to quillmark-sync before the 3.5 release. The migration notes \
            say the OpenRouter handler still calls the old endpoint, and the HTTP retry budget \
            needs raising before we cut over. Kaelith owns the rollout and has asked for the \
            snake_case_helper rename to land first, so the diff stays readable for review.
            """,
        textBeforeCaret: "Ask Kaelith about ")

    private func service(
        _ grounding: GroundingSupport, keytermBiasing: Bool = false
    ) -> (TranscriptionService, RecordingProvider) {
        let provider = RecordingProvider(grounding: grounding)
        return (
            TranscriptionService(
                provider: provider, model: "m", systemInstruction: "instruction",
                keytermBiasing: keytermBiasing),
            provider
        )
    }

    func testMultimodalProviderStillReceivesTheEncodedScreenText() async throws {
        let (service, provider) = service(.multimodal)
        _ = try await service.transcribe(audio: audio, context: context)

        let parts = try XCTUnwrap(provider.lastRequest?.parts)
        let text = parts.compactMap { if case .text(let value) = $0 { value } else { nil } }
        XCTAssertFalse(text.isEmpty, "grounding must be unchanged for model providers")
        XCTAssertTrue(text.joined().contains("Brindlewood"))
        XCTAssertTrue(provider.lastRequest?.keyterms.isEmpty ?? false)
    }

    /// The failure this routing exists to prevent: ten thousand characters of screen text uploaded
    /// to an endpoint whose request body is raw audio, producing a request that looks grounded and
    /// is not.
    func testRecognitionProviderNeverReceivesScreenTextParts() async throws {
        let (service, provider) = service(.keyterms(maxTerms: 100, maxCharsPerTerm: 50))
        _ = try await service.transcribe(audio: audio, context: context)

        let parts = try XCTUnwrap(provider.lastRequest?.parts)
        XCTAssertEqual(parts.count, 1, "audio only")
        guard case .audio = parts[0] else { return XCTFail("expected the audio part") }
    }

    func testKeytermsAreWithheldUnlessBiasingIsTurnedOn() async throws {
        let (off, offProvider) = service(.keyterms(maxTerms: 100, maxCharsPerTerm: 50))
        _ = try await off.transcribe(audio: audio, context: context)
        XCTAssertEqual(offProvider.lastRequest?.keyterms, [], "off by default")

        let (on, onProvider) = service(
            .keyterms(maxTerms: 100, maxCharsPerTerm: 50), keytermBiasing: true)
        _ = try await on.transcribe(audio: audio, context: context)
        let terms = try XCTUnwrap(onProvider.lastRequest?.keyterms)
        XCTAssertTrue(terms.contains("Kaelith"))
        XCTAssertTrue(terms.contains("Brindlewood"))
        XCTAssertFalse(terms.contains { $0.contains(where: \.isNumber) })
    }

    func testProviderCapsAreHonouredWhenDerivingTerms() async throws {
        let (service, provider) = service(
            .keyterms(maxTerms: 1, maxCharsPerTerm: 50), keytermBiasing: true)
        _ = try await service.transcribe(audio: audio, context: context)
        XCTAssertEqual(provider.lastRequest?.keyterms.count, 1)
    }

    func testProviderWithNoBiasingChannelGetsNeitherTextNorTerms() async throws {
        let (service, provider) = service(.none, keytermBiasing: true)
        _ = try await service.transcribe(audio: audio, context: context)

        XCTAssertEqual(provider.lastRequest?.parts.count, 1)
        XCTAssertEqual(provider.lastRequest?.keyterms, [])
    }

    /// Fidelity travels on the request because a recogniser has no system instruction to read it
    /// out of. Without this the setting would silently do nothing on Deepgram and xAI.
    func testFidelityReachesTheProvider() async throws {
        let provider = RecordingProvider(grounding: .none)
        let service = TranscriptionService(
            provider: provider, model: "m", systemInstruction: "i", fidelity: .raw)
        _ = try await service.transcribe(audio: audio, context: nil)

        XCTAssertEqual(provider.lastRequest?.fidelity, .raw)
    }

    // MARK: - Rewriting

    /// The rewrite hotkey sends text with no audio. A recogniser cannot serve it, and the error
    /// has to say what to do rather than surfacing as a raw 400.
    func testRewriteThroughARecognitionBackendFailsWithAnActionableError() async {
        let provider = DeepgramProvider(apiKey: "k")
        let service = TranscriptionService(
            provider: provider, model: "nova-3", systemInstruction: "i")

        do {
            _ = try await service.rewrite("some text", instruction: "make it formal")
            XCTFail("expected audioRequired")
        } catch let error as ProviderError {
            guard case .audioRequired = error else {
                return XCTFail("expected audioRequired, got \(error)")
            }
            let message = try? XCTUnwrap(error.errorDescription)
            XCTAssertTrue(message?.contains("cannot rewrite") ?? false)
        } catch {
            XCTFail("expected ProviderError, got \(error)")
        }
    }

    func testRewriteFailureIsNotRetried() {
        XCTAssertFalse(
            TranscriptionService.isTransient(ProviderError.audioRequired(provider: "deepgram")))
    }

    func testRewriteFailureTellsTheUserToChangeProvider() {
        let guidance = FailureAdvice.describe(ProviderError.audioRequired(provider: "deepgram"))
        XCTAssertTrue(guidance.needsUserAction)
        XCTAssertFalse(guidance.isRetryable)
        XCTAssertFalse(guidance.isQueued)
    }

    /// The number check spends a second request to compare a grounded run against a screen-blind
    /// one. Against a backend that never saw the screen both runs are the same run, so it must not
    /// fire — it would double the bill and compare a transcript with itself.
    func testNumberVerificationIsSkippedForBackendsThatCannotSeeTheScreen() async throws {
        let provider = RecordingProvider(grounding: .keyterms(maxTerms: 100, maxCharsPerTerm: 50))
        let service = TranscriptionService(
            provider: provider, model: "m", systemInstruction: "i")

        let wav = try wavFixture(seconds: 1)
        _ = try await service.transcribeLong(
            audio: AudioFile(data: wav, mimeType: "audio/wav"), context: context,
            verifyNumbers: true)

        // One request reached the provider, not two.
        XCTAssertEqual(provider.lastRequest?.parts.count, 1)
    }

    private func wavFixture(seconds: Int) throws -> Data {
        let sampleRate = 16_000
        let bytes = sampleRate * 2 * seconds
        var wav = Data()
        func text(_ value: String) { wav.append(Data(value.utf8)) }
        func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) } }
        func u16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) } }

        text("RIFF"); u32(UInt32(36 + bytes)); text("WAVEfmt ")
        u32(16); u16(1); u16(1); u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        text("data"); u32(UInt32(bytes))
        wav.append(Data(repeating: 0, count: bytes))
        return wav
    }
}
