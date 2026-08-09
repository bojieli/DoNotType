import Foundation

/// One near-miss test case.
///
/// The suite exists to catch substitution: the model hearing one thing, finding a near-match on
/// screen, and quietly writing the screen's version instead. Cases are deliberately adversarial —
/// the context should contain something that is *almost* what was said.
public struct EvalCase: Sendable, Codable {
    public var id: String
    /// Path to the recording, relative to the case file's directory.
    public var audio: String
    public var context: ScreenContext
    /// What the speaker actually said. The primary assertion.
    public var expectTranscript: String
    /// Optional note about what this case is probing.
    public var note: String?

    public func audioURL(relativeTo caseFile: URL) -> URL {
        URL(fileURLWithPath: audio, relativeTo: caseFile.deletingLastPathComponent())
    }
}

/// What screen context did to this transcript, judged against ground truth rather than against
/// the baseline alone.
///
/// The distinction matters because the no-context baseline is itself unstable — an ambiguous word
/// transcribes differently run to run. A large diff from a *wrong* baseline is grounding doing its
/// job; scoring on diff size alone would flag that as a failure and flag nothing when both runs
/// are wrong in the same way.
public enum GroundingEffect: String, Sendable {
    /// Baseline was wrong, context fixed it. The feature working.
    case improved
    /// Baseline was right, context broke it. **The bug this project exists to prevent.**
    case regressed
    case neutralCorrect
    case neutralWrong

    public var isBug: Bool { self == .regressed }
}

/// Outcome of running one case twice — with context and without.
public struct EvalOutcome: Sendable {
    public var caseID: String
    public var expected: String
    public var withContext: String
    public var withoutContext: String
    public var report: TranscriptDiff.Report
    public var audioTokens: Int?

    /// The gate: does the with-context transcript say what the speaker actually said?
    public var matchesExpectation: Bool {
        TranscriptDiff.normalize(withContext) == TranscriptDiff.normalize(expected)
    }

    var baselineMatchesExpectation: Bool {
        TranscriptDiff.normalize(withoutContext) == TranscriptDiff.normalize(expected)
    }

    public var effect: GroundingEffect {
        switch (baselineMatchesExpectation, matchesExpectation) {
        case (false, true): .improved
        case (true, false): .regressed
        case (true, true): .neutralCorrect
        case (false, false): .neutralWrong
        }
    }

    public var passed: Bool { matchesExpectation }
}

/// Runs cases against a provider.
public struct EvalRunner: Sendable {
    public var provider: any TranscriptionProvider
    public var model: String
    public var systemInstruction: String
    public var encoder: ContextEncoder

    public init(
        provider: any TranscriptionProvider,
        model: String,
        systemInstruction: String,
        encoder: ContextEncoder = ContextEncoder()
    ) {
        self.provider = provider
        self.model = model
        self.systemInstruction = systemInstruction
        self.encoder = encoder
    }

    /// Transcribes once. `context` of `nil` produces the no-context baseline.
    public func transcribe(audio: AudioFile, context: ScreenContext?) async throws
        -> TranscriptionResult
    {
        var parts: [InputPart] = []
        if let context {
            parts.append(contentsOf: encoder.encode(context))
        }
        parts.append(audio.part)
        return try await provider.transcribe(
            TranscriptionRequest(
                model: model, systemInstruction: systemInstruction, parts: parts))
    }

    public func run(_ testCase: EvalCase, caseFile: URL) async throws -> EvalOutcome {
        let audio = try AudioFile(contentsOf: testCase.audioURL(relativeTo: caseFile))
        // Sequential, not concurrent: gateways rate-limit, and a 429 mid-suite is a worse
        // failure than waiting.
        let withContext = try await transcribe(audio: audio, context: testCase.context)
        let withoutContext = try await transcribe(audio: audio, context: nil)

        return EvalOutcome(
            caseID: testCase.id,
            expected: testCase.expectTranscript,
            withContext: withContext.transcript.transcript,
            withoutContext: withoutContext.transcript.transcript,
            report: TranscriptDiff.compare(
                withoutContext: withoutContext.transcript.transcript,
                withContext: withContext.transcript.transcript),
            audioTokens: withContext.usage.audioTokens
        )
    }

    /// Loads every `*.json` in a directory.
    public static func loadCases(in directory: URL) throws -> [(EvalCase, URL)] {
        let files = try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        let decoder = JSONDecoder()
        return try files.map { url in
            (try decoder.decode(EvalCase.self, from: try Data(contentsOf: url)), url)
        }
    }
}
