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

    /// Not requested means one request — the whole point of the policy is choosing when to spend
    /// the second one.
    func testNotRequestedCostsOnlyOneRequest() async throws {
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

/// The trigger is digits *near the caret*, and the reason is measured: the same contradicting
/// value substitutes 3/10 of the time from visible text and 7/10 from the caret window.
final class NumberCheckPolicyTests: XCTestCase {
    private func context(
        visible: String? = nil, before: String? = nil, after: String? = nil, selected: String? = nil
    ) -> ScreenContext {
        ScreenContext(
            appName: "App", visibleText: visible, textBeforeCaret: before,
            textAfterCaret: after, selectedText: selected)
    }

    func testCaretTextWithDigitsIsHighRisk() {
        XCTAssertTrue(NumericGuard.isHighRisk(context(before: "Upgrade to Gemini 2.5 because")))
        XCTAssertTrue(NumericGuard.isHighRisk(context(after: " — see the 3.5 migration notes")))
        XCTAssertTrue(NumericGuard.isHighRisk(context(selected: "port 8080")))
    }

    func testCaretTextWithoutDigitsIsNot() {
        XCTAssertFalse(NumericGuard.isHighRisk(context(before: "Replying to Kaelith: ")))
        XCTAssertFalse(NumericGuard.isHighRisk(nil))
    }

    /// Visible text routinely contains numbers with nothing to do with the utterance — a sidebar,
    /// a timestamp, a row count. Triggering on those makes the cost constant and the benefit rare.
    func testDigitsInVisibleTextAloneDoNotTrigger() {
        XCTAssertFalse(
            NumericGuard.isHighRisk(context(visible: "1,204 results · updated 3 minutes ago")))
    }

    func testPolicyNeverAndAlwaysIgnoreContent() {
        let risky = context(before: "Gemini 2.5")
        XCTAssertFalse(NumberCheckPolicy.never.applies(to: risky))
        XCTAssertTrue(NumberCheckPolicy.always.applies(to: risky))
        XCTAssertTrue(NumberCheckPolicy.always.applies(to: context(before: "no digits")))
    }

    func testPolicyWhenCaretHasNumbersFollowsTheMeasuredTrigger() {
        XCTAssertTrue(
            NumberCheckPolicy.whenCaretHasNumbers.applies(to: context(before: "version 2.5 of")))
        XCTAssertFalse(
            NumberCheckPolicy.whenCaretHasNumbers.applies(to: context(before: "version two of")))
    }

    /// Ordinary dictation into an empty field must never pay for the check.
    func testAnEmptyFieldIsNotRisky() {
        XCTAssertFalse(NumberCheckPolicy.whenCaretHasNumbers.applies(to: context()))
        XCTAssertFalse(NumberCheckPolicy.whenCaretHasNumbers.applies(to: nil))
    }

    /// Every option must be explicable in the UI, or the setting is a coin flip.
    func testEveryPolicyExplainsItself() {
        for policy in NumberCheckPolicy.allCases {
            XCTAssertFalse(policy.label.isEmpty)
            XCTAssertFalse(policy.detail.isEmpty)
        }
    }
}
