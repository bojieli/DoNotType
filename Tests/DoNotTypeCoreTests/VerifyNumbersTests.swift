import Foundation
import XCTest

@testable import DoNotTypeCore

/// A provider that answers differently depending on whether screen context was sent, which is the
/// only thing the verification path actually depends on.
private final class ContextSensitiveProvider: TranscriptionProvider, @unchecked Sendable {
    let name = "stub"
    let grounded: String
    let audioOnly: String
    /// Thrown from the audio-only leg only, to test that a failed check cannot cost the transcript.
    let audioOnlyError: (any Error)?

    private let lock = NSLock()
    private(set) var requestCount = 0
    private(set) var groundedRequests = 0

    init(grounded: String, audioOnly: String, audioOnlyError: (any Error)? = nil) {
        self.grounded = grounded
        self.audioOnly = audioOnly
        self.audioOnlyError = audioOnlyError
    }

    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        let isGrounded = request.parts.contains {
            if case .text(let value) = $0 { value.contains(ContextEncoder.header) } else { false }
        }
        lock.withLock {
            requestCount += 1
            if isGrounded { groundedRequests += 1 }
        }

        if !isGrounded, let audioOnlyError { throw audioOnlyError }
        return TranscriptionResult(
            transcript: Transcript(transcript: isGrounded ? grounded : audioOnly),
            usage: TokenUsage(promptTokens: 10, audioTokens: isGrounded ? 100 : 90),
            rawOutput: "")
    }
}

final class VerifyNumbersTests: XCTestCase {
    private let audio = AudioFile(data: Data(repeating: 0, count: 2_000), mimeType: "audio/wav")
    private let context = ScreenContext(
        appName: "Safari", visibleText: String(repeating: "Gemini 2.5 Flash is current. ", count: 20))

    private func service(_ provider: any TranscriptionProvider) -> TranscriptionService {
        TranscriptionService(provider: provider, model: "m", systemInstruction: "s")
    }

    func testDigitsComeFromTheRunThatNeverSawTheScreen() async throws {
        let provider = ContextSensitiveProvider(
            grounded: "Use Gemini 2.5 Flash for this.",
            audioOnly: "Use Gemini 1.5 Flash for this.")

        let result = try await service(provider).transcribeLong(
            audio: audio, context: context, verifyNumbers: true)

        XCTAssertEqual(result.transcript.transcript, "Use Gemini 1.5 Flash for this.")
        XCTAssertEqual(provider.requestCount, 2)
    }

    /// The grounded run is kept precisely because it spells better; only digits are taken.
    func testWordingStaysGroundedEvenWhenTheAudioOnlyRunDiffers() async throws {
        let provider = ContextSensitiveProvider(
            grounded: "Deploy SwiftUI on port 8080.",
            audioOnly: "Deploy swift UI on port 9090.")

        let result = try await service(provider).transcribeLong(
            audio: audio, context: context, verifyNumbers: true)

        XCTAssertEqual(result.transcript.transcript, "Deploy SwiftUI on port 9090.")
    }

    /// Off by default, and off means one request — the whole reason it is opt-in is the second one.
    func testDisabledByDefaultAndCostsOnlyOneRequest() async throws {
        let provider = ContextSensitiveProvider(grounded: "grounded 2.5", audioOnly: "spoken 1.5")

        let result = try await service(provider).transcribeLong(audio: audio, context: context)

        XCTAssertEqual(result.transcript.transcript, "grounded 2.5")
        XCTAssertEqual(provider.requestCount, 1)
    }

    /// With no context there is nothing to verify against, so the second request would be waste.
    func testNoSecondRequestWhenThereIsNoContext() async throws {
        let provider = ContextSensitiveProvider(grounded: "g", audioOnly: "a")

        _ = try await service(provider).transcribeLong(
            audio: audio, context: nil, verifyNumbers: true)

        XCTAssertEqual(provider.requestCount, 1)
    }

    /// A failed verification must never cost the user their transcript: the grounded run already
    /// succeeded, and unverified numbers beat no text at all.
    func testAFailedVerificationPassKeepsTheGroundedTranscript() async throws {
        let provider = ContextSensitiveProvider(
            grounded: "Use Gemini 2.5 Flash.", audioOnly: "",
            audioOnlyError: ProviderError.http(status: 500, body: ""))

        let result = try await service(provider).transcribeLong(
            audio: audio, context: context, verifyNumbers: true)

        XCTAssertEqual(result.transcript.transcript, "Use Gemini 2.5 Flash.")
    }

    /// Both requests are billed, so both must be reported — otherwise the Stats screen would
    /// understate what this setting costs, which is the one thing the user turned it on to weigh.
    func testUsageFromBothRequestsIsReported() async throws {
        let provider = ContextSensitiveProvider(grounded: "a 1", audioOnly: "a 1")

        let result = try await service(provider).transcribeLong(
            audio: audio, context: context, verifyNumbers: true)

        XCTAssertEqual(result.usage.audioTokens, 190)
        XCTAssertEqual(result.usage.promptTokens, 20)
    }

    /// When the runs disagree on how many numbers there are, the guard declines and the grounded
    /// transcript survives untouched rather than being partly rewritten.
    func testMismatchedNumberCountsLeaveTheGroundedTranscriptIntact() async throws {
        let provider = ContextSensitiveProvider(
            grounded: "Ports 80 and 443 are open.",
            audioOnly: "Port 443 is open.")

        let result = try await service(provider).transcribeLong(
            audio: audio, context: context, verifyNumbers: true)

        XCTAssertEqual(result.transcript.transcript, "Ports 80 and 443 are open.")
    }
}
