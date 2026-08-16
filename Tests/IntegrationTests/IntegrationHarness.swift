import Foundation
import XCTest

@testable import DoNotTypeCore

/// Shared setup for tests that hit the live API.
///
/// These are opt-in for two reasons: they cost money, and they fail when the network does, which
/// would make an ordinary `swift test` unreliable. Everything here skips unless `DNT_INTEGRATION=1`.
enum Harness {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["DNT_INTEGRATION"] == "1"
    }

    static func apiKey() throws -> String {
        guard let key = ProcessInfo.processInfo.environment["GEMINI_API_KEY"], !key.isEmpty else {
            throw XCTSkip("GEMINI_API_KEY is not set")
        }
        return key
    }

    static func requireIntegration() throws {
        guard isEnabled else {
            throw XCTSkip("Set DNT_INTEGRATION=1 to run tests that call the live API")
        }
    }

    static var repositoryRoot: URL {
        // Tests run from .build, so walk up to the directory holding prompt/.
        PromptBuilder.findPromptDirectory(startingAt: URL(fileURLWithPath: #filePath))?
            .deletingLastPathComponent()
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    /// A real recording extracted from the user's own media, not synthesized speech.
    ///
    /// `say` enunciates far more clearly than a person, so a suite built on it measures the easy
    /// case. See eval/extract-real-audio.sh.
    static func realAudio(_ name: String) throws -> AudioFile {
        let url = repositoryRoot
            .appendingPathComponent("eval/audio")
            .appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("\(name) is missing — run eval/extract-real-audio.sh")
        }
        return try AudioFile(contentsOf: url)
    }

    static func systemInstruction(fidelity: Fidelity = .light) throws -> String {
        let url = repositoryRoot.appendingPathComponent("prompt")
        return try PromptBuilder(directory: url).systemInstruction(fidelity: fidelity)
    }

    static func provider() throws -> GeminiProvider {
        GeminiProvider(apiKey: try apiKey())
    }

    static func service(fidelity: Fidelity = .light) throws -> TranscriptionService {
        TranscriptionService(
            provider: try provider(),
            model: ProviderKind.google.defaultModel,
            systemInstruction: try systemInstruction(fidelity: fidelity))
    }

    static func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("dnt-integration-\(UUID().uuidString)")
    }
}

/// A provider that fails a fixed number of times before delegating, for exercising retry.
struct FlakyProvider: TranscriptionProvider {
    let name = "flaky"
    let inner: any TranscriptionProvider
    let failures: Int
    let error: any Error

    private let counter = Counter()

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func next() -> Int {
            lock.lock()
            defer { lock.unlock() }
            value += 1
            return value
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    init(inner: any TranscriptionProvider, failures: Int, error: any Error) {
        self.inner = inner
        self.failures = failures
        self.error = error
    }

    var attempts: Int { counter.count }

    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        if counter.next() <= failures { throw error }
        return try await inner.transcribe(request)
    }
}

/// A provider that always succeeds with a fixed transcript, for tests that need no network.
struct StubProvider: TranscriptionProvider {
    let name = "stub"
    var text = "stub transcript"
    var audioTokens: Int? = 77

    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        let usage = TokenUsage(promptTokens: 10, completionTokens: 5, audioTokens: audioTokens)
        try assertAudioWasProcessed(request: request, usage: usage, model: request.model)
        return TranscriptionResult(
            transcript: Transcript(transcript: text, language: "en"),
            usage: usage,
            rawOutput: text)
    }
}
