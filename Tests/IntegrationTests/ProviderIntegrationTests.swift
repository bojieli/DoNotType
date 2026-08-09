import Foundation
import XCTest

@testable import DoNotTypeCore

/// Cross-provider and cross-model checks.
///
/// These exist because "it works" is provider-specific in ways that are easy to miss: one gateway
/// discarded audio while returning HTTP 200, and three Gemini releases transcribe the same clip
/// differently. Anything that varies by backend belongs here rather than in the pipeline suite.
final class ProviderIntegrationTests: XCTestCase {

    /// Every provider must either process the audio or fail loudly. Returning a confident
    /// transcript of nothing is the one outcome that must be impossible.
    func testEveryConfiguredProviderProcessesAudioOrThrows() async throws {
        try Harness.requireIntegration()
        let audio = try Harness.realAudio("real-talk-gemini15.wav")
        let instruction = try Harness.systemInstruction()

        var checked = 0
        for kind in ProviderKind.allCases {
            guard let key = ProcessInfo.processInfo.environment[kind.apiKeyEnvVar],
                !key.isEmpty
            else { continue }

            let provider = try ProviderFactory.make(
                kind, environment: [kind.apiKeyEnvVar: key])
            let service = TranscriptionService(
                provider: provider, model: kind.defaultModel, systemInstruction: instruction)

            let result = try await service.transcribe(audio: audio, context: nil)
            checked += 1

            XCTAssertFalse(
                result.transcript.transcript.trimmed.isEmpty,
                "\(kind.rawValue) returned an empty transcript for real speech")

            // If the provider reports usage at all, audio must be in it. A zero here is the
            // silent-drop failure and the guard should already have thrown.
            if let audioTokens = result.usage.audioTokens {
                XCTAssertGreaterThan(
                    audioTokens, 0, "\(kind.rawValue) billed no audio tokens")
            }
        }

        try XCTSkipIf(checked == 0, "no provider keys are set in the environment")
    }

    /// Two providers serving the same model should produce recognisably the same transcript.
    /// Divergence means one of them is doing something to the audio.
    func testProvidersAgreeOnTheSameRecording() async throws {
        try Harness.requireIntegration()
        guard let openRouterKey = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"],
            !openRouterKey.isEmpty
        else { throw XCTSkip("OPENROUTER_API_KEY is not set") }

        let audio = try Harness.realAudio("real-talk-gemini15.wav")
        let instruction = try Harness.systemInstruction()

        let native = try await TranscriptionService(
            provider: try Harness.provider(),
            model: ProviderKind.gemini.defaultModel,
            systemInstruction: instruction
        ).transcribe(audio: audio, context: nil).transcript.transcript

        let gateway = try await TranscriptionService(
            provider: try ProviderFactory.make(
                .openrouter, environment: ["OPENROUTER_API_KEY": openRouterKey]),
            model: ProviderKind.openrouter.defaultModel,
            systemInstruction: instruction
        ).transcribe(audio: audio, context: nil).transcript.transcript

        // Not equality — transcription is stochastic. Substantial overlap is the claim.
        let overlap = Self.tokenOverlap(native, gateway)
        XCTAssertGreaterThan(
            overlap, 0.5,
            "providers diverged on the same audio (overlap \(overlap)):\n  \(native)\n  \(gateway)")
    }

    /// A model bump can regress multimodal quality. This is the check that would notice.
    ///
    /// Majority of three rather than one run: the reference clip is genuinely hard — the version
    /// number is unstressed and mid-sentence — and even the current default gets it wrong roughly
    /// one run in four with no context at all. A single-run assertion here would fail for reasons
    /// that have nothing to do with a regression.
    func testCurrentDefaultModelTranscribesTheKnownClipCorrectly() async throws {
        try Harness.requireIntegration()
        let audio = try Harness.realAudio("real-talk-gemini15.wav")
        let service = try Harness.service()

        var correct = 0
        var samples: [String] = []
        for _ in 0..<3 {
            let text = try await service.transcribe(audio: audio, context: nil)
                .transcript.transcript
            samples.append(text)
            if text.contains("1.5") { correct += 1 }
        }

        // The speaker says "Gemini 1.5". Measured: 3.6 gets this right ~3 runs in 4 with no
        // context; 3.5-flash hears 2.4 and 3-flash-preview hears "Gimma 2.0" every time.
        XCTAssertGreaterThanOrEqual(
            correct, 2,
            "the default model no longer transcribes the reference clip reliably: \(samples)")
    }

    private static func tokenOverlap(_ a: String, _ b: String) -> Double {
        let left = Set(TranscriptDiff.tokenize(a).map(TranscriptDiff.normalize))
        let right = Set(TranscriptDiff.tokenize(b).map(TranscriptDiff.normalize))
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        return Double(left.intersection(right).count) / Double(max(left.count, right.count))
    }
}

/// The subsystems added for production use: history search, prompt overrides, failure guidance.
///
/// No network needed — these are about behaviour the user depends on being right, not about the
/// model.
final class SubsystemIntegrationTests: XCTestCase {
    private func makeStore() -> (HistoryStore, URL) {
        let directory = Harness.temporaryDirectory()
        return (HistoryStore(directory: directory), directory)
    }

    /// The queue has to survive a relaunch, or "it will send itself later" is a lie.
    func testOfflineQueueSurvivesRestartAndDrains() async throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        await store.configure(retention: .forever, keepAudioForCompleted: false)

        let queued = DictationRecord(
            status: .pending, errorMessage: "Offline when recorded.",
            provider: "gemini", model: "m", fidelity: .light)
        await store.insert(queued, audio: Data([1, 2, 3]))

        // A fresh store, as after a relaunch.
        let reopened = HistoryStore(directory: directory)
        await reopened.configure(retention: .forever, keepAudioForCompleted: false)
        let pending = await reopened.retryable()

        XCTAssertEqual(pending.count, 1)
        XCTAssertTrue(pending[0].canRetry, "a queued dictation must still have its audio")

        let coordinator = RetryCoordinator(
            service: TranscriptionService(
                provider: StubProvider(text: "drained"), model: "m",
                systemInstruction: "instruction"),
            store: reopened)
        let outcome = await coordinator.retryAll()

        XCTAssertEqual(outcome.succeeded.count, 1)
        let after = await reopened.retryable()
        XCTAssertTrue(after.isEmpty, "the queue should be empty once drained")
    }

    /// Search has to work over what the store actually persisted, not just an in-memory array.
    func testSearchWorksAgainstPersistedRecords() async throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        await store.configure(retention: .forever, keepAudioForCompleted: false)

        await store.insert(
            DictationRecord(
                status: .completed, text: "Ship the pricing page", provider: "gemini",
                model: "m", fidelity: .light, appName: "Slack"),
            audio: nil)
        await store.insert(
            DictationRecord(
                status: .failed, errorMessage: "Rate limited — saved", provider: "gemini",
                model: "m", fidelity: .light, appName: "Xcode"),
            audio: Data([1]))

        var query = HistoryQuery()
        query.text = "pricing"
        let byText = await store.search(query)
        XCTAssertEqual(byText.count, 1)

        query = HistoryQuery()
        query.status = .needsAttention
        let failing = await store.search(query)
        XCTAssertEqual(failing.count, 1)
        XCTAssertEqual(failing.first?.appName, "Xcode")
    }

    /// An edited prompt has to actually reach the request, or the editor is decorative.
    func testCustomPromptOverridesTheBundledOne() throws {
        let directory = Harness.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = PromptStore(directory: directory)
        let bundled = try XCTUnwrap(PromptBuilder.findPromptFile())

        // Default first.
        let shipped = try store.builder(default: bundled).systemInstruction(fidelity: .light)
        XCTAssertTrue(shipped.contains("Context corrects SPELLING, never CONTENT"))

        try store.save(
            """
            <!-- BEGIN SYSTEM -->
            CUSTOM ENGINE. {{FIDELITY_RULE}}
            <!-- END SYSTEM -->

            ### raw
            ```
            R
            ```
            ### light
            ```
            L
            ```
            ### tidy
            ```
            T
            ```
            """)

        let custom = try store.builder(default: bundled).systemInstruction(fidelity: .light)
        XCTAssertTrue(custom.hasPrefix("CUSTOM ENGINE."))
        XCTAssertFalse(custom.contains("Context corrects SPELLING"))
    }

    /// Every error a user can hit must produce guidance, not a raw string.
    func testEveryProviderErrorProducesActionableGuidance() {
        let errors: [any Error] = [
            ProviderError.http(status: 401, body: ""),
            ProviderError.http(status: 429, body: ""),
            ProviderError.http(status: 503, body: ""),
            ProviderError.missingAPIKey(envVar: "GEMINI_API_KEY"),
            ProviderError.audioSilentlyDropped(provider: "x", model: "y"),
            ProviderError.emptyOutput,
            NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet),
        ]

        for error in errors {
            let advice = FailureAdvice.describe(error)
            XCTAssertFalse(advice.message.isEmpty)
            XCTAssertTrue(
                advice.isQueued || advice.needsUserAction,
                "\(error) leaves the user with nothing to do and nothing saved")
        }
    }
}

extension StubProvider {
    init(text: String) {
        self.init()
        self.text = text
    }
}
