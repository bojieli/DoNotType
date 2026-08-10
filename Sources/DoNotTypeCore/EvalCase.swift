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
    /// What the speaker actually said, for cases short enough to assert exactly.
    ///
    /// Leave empty for real speech. A 22-second clip transcribed by a stochastic model will differ
    /// run to run on wording that has nothing to do with grounding — "observed" versus "observe" —
    /// so demanding an exact match would fail for reasons the suite is not measuring.
    /// Optional so a real-speech case can omit it entirely; synthesized `Decodable` does not
    /// apply default values to missing keys.
    public var expectTranscript: String?

    /// Fragments that must appear. The right assertion for real speech: name the few tokens the
    /// case actually turns on and ignore the rest.
    public var mustContain: [String]?

    /// Fragments that must not appear — typically the decoy value sitting in the screen context.
    public var mustNotContain: [String]?

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
    /// Fragments required and forbidden, for cases where an exact match is unreasonable.
    public var mustContain: [String] = []
    public var mustNotContain: [String] = []
    public var withContext: String
    public var withoutContext: String
    public var report: TranscriptDiff.Report
    public var audioTokens: Int?

    /// The gate: does the with-context transcript say what the speaker actually said?
    public var matchesExpectation: Bool { satisfies(withContext) }

    var baselineMatchesExpectation: Bool { satisfies(withoutContext) }

    private func satisfies(_ text: String) -> Bool {
        if !expected.isEmpty {
            return TranscriptDiff.normalize(text) == TranscriptDiff.normalize(expected)
        }
        // Real-speech cases assert fragments instead. An empty case asserts nothing and would
        // silently pass, so it counts as a failure rather than a free green.
        guard !mustContain.isEmpty || !mustNotContain.isEmpty else { return false }
        return mustContain.allSatisfy { text.containsLoosely($0) }
            && mustNotContain.allSatisfy { !text.containsLoosely($0) }
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
    ///
    /// Retries transient failures rather than aborting. A suite run costs twenty minutes and real
    /// money, and losing it to one dropped connection is a harness defect, not a finding.
    public func transcribe(audio: AudioFile, context: ScreenContext?) async throws
        -> TranscriptionResult
    {
        var parts: [InputPart] = []
        if let context {
            parts.append(contentsOf: encoder.encode(context))
        }
        parts.append(audio.part)

        var delay = Duration.milliseconds(800)
        var lastError: any Error = ProviderError.emptyOutput

        for attempt in 1...4 {
            do {
                return try await provider.transcribe(
                    TranscriptionRequest(
                        model: model, systemInstruction: systemInstruction, parts: parts))
            } catch {
                lastError = error
                guard attempt < 4, TranscriptionService.isTransient(error) else { throw error }
                try? await Task.sleep(for: delay)
                delay = delay * 2
            }
        }
        throw lastError
    }

    public func run(_ testCase: EvalCase, caseFile: URL) async throws -> EvalOutcome {
        let audio = try AudioFile(contentsOf: testCase.audioURL(relativeTo: caseFile))
        // Sequential, not concurrent: gateways rate-limit, and a 429 mid-suite is a worse
        // failure than waiting.
        let withContext = try await transcribe(audio: audio, context: testCase.context)
        let withoutContext = try await transcribe(audio: audio, context: nil)

        return EvalOutcome(
            caseID: testCase.id,
            expected: testCase.expectTranscript ?? "",
            mustContain: testCase.mustContain ?? [],
            mustNotContain: testCase.mustNotContain ?? [],
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
