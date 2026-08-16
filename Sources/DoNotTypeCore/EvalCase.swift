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

    /// Which script the transcript has to be in.
    ///
    /// Exists so a case whose point is *"transcribe in the language spoken, never translate"* can
    /// assert that directly. The alternative was a `mustContain` fragment of Chinese, which would
    /// mean writing down a transcript nobody verified by ear — machine-generated ground truth,
    /// scoring machines. This asserts only the thing the case is actually about.
    public enum Script: String, Sendable, Codable {
        /// Han characters, i.e. the output is Chinese rather than an English translation.
        case han
        /// Latin letters, for the inverse check.
        case latin

        public func matches(_ text: String) -> Bool {
            switch self {
            case .han:
                return text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
            case .latin:
                return text.contains { $0.isLetter && $0.isASCII }
            }
        }
    }

    /// Script the transcript must be written in. See `Script`.
    public var mustBeScript: Script?

    /// Shortest transcript that could plausibly be this clip.
    ///
    /// Guards the failure fragments cannot see: a backend that returns the first two seconds of a
    /// twenty-second recording satisfies every `mustNotContain` by never reaching the words it
    /// would have got wrong. Set well below the real length — this is a floor for "did it
    /// transcribe at all", not an accuracy assertion.
    public var minCharacters: Int?

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
    /// Script the transcript must be written in, for cases whose point is *which language*.
    public var mustBeScript: EvalCase.Script?
    /// Floor on transcript length, to catch a backend that returned a fragment of the clip.
    public var minCharacters: Int?
    public var withContext: String
    public var withoutContext: String
    public var report: TranscriptDiff.Report
    public var audioTokens: Int?

    /// The gate: does the with-context transcript say what the speaker actually said?
    public var matchesExpectation: Bool { satisfies(withContext) }

    var baselineMatchesExpectation: Bool { satisfies(withoutContext) }

    private func satisfies(_ text: String) -> Bool {
        // Nothing transcribed is never a pass, whatever the case asserts.
        //
        // This is not defensive coding, it is a hole that was open. `mustContain.allSatisfy` is
        // vacuously true on an empty list, so a case asserting only `mustNotContain` — as
        // `real-mandarin` did — passed on *any* output that avoided two forbidden phrases,
        // including no output at all. A backend that silently returned nothing scored a green.
        guard !text.trimmed.isEmpty else { return false }

        if !expected.isEmpty {
            return TranscriptDiff.normalize(text) == TranscriptDiff.normalize(expected)
        }

        // Real-speech cases assert fragments instead. An empty case asserts nothing and would
        // silently pass, so it counts as a failure rather than a free green.
        guard !mustContain.isEmpty || !mustNotContain.isEmpty || mustBeScript != nil else {
            return false
        }

        // A twenty-second clip that comes back as "Okay." did not transcribe, and no fragment
        // assertion catches that on its own — a truncated transcript can satisfy every
        // `mustNotContain` by simply not reaching the words it would have got wrong.
        if let minCharacters, text.trimmed.count < minCharacters { return false }

        if let mustBeScript, !mustBeScript.matches(text) { return false }

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
    /// Carried as well as baked into `systemInstruction`, because a recognition backend has no
    /// system instruction to read it out of. Without this the harness would measure every
    /// `--fidelity` setting as though it were the default on Deepgram and xAI.
    public var fidelity: Fidelity
    public var keytermBiasing: Bool

    /// Recorded answers, when the run is recording or replaying. Nil is the live path.
    public var cassette: CassetteStore?

    public init(
        provider: any TranscriptionProvider,
        model: String,
        systemInstruction: String,
        encoder: ContextEncoder = ContextEncoder(),
        fidelity: Fidelity = .default,
        keytermBiasing: Bool = false,
        cassette: CassetteStore? = nil
    ) {
        self.provider = provider
        self.model = model
        self.systemInstruction = systemInstruction
        self.encoder = encoder
        self.fidelity = fidelity
        self.keytermBiasing = keytermBiasing
        self.cassette = cassette
    }

    /// What this run's backend can do with the screen, so a report can say whether the
    /// "with context" arm was grounded at all.
    public var grounding: GroundingSupport { provider.grounding(forModel: model) }

    /// The exact object the app dictates through.
    ///
    /// The harness used to build its own request and call the provider directly, which meant it
    /// could — and twice did — measure something the product does not do: once uploading raw PCM
    /// after the app had moved to Opus, and once bypassing compression entirely. Both times every
    /// number improved and no user saw any of it.
    ///
    /// Routing through `TranscriptionService` makes that class of bug impossible rather than
    /// merely fixed. Anything added to the request — a codec, a header, a part — reaches the
    /// measurement automatically, because there is only one place that builds one.
    private var service: TranscriptionService {
        TranscriptionService(
            provider: provider, model: model, systemInstruction: systemInstruction,
            encoder: encoder, fidelity: fidelity, keytermBiasing: keytermBiasing,
            // The one place the stall hedge is unwanted. A suite is hundreds of requests against a
            // backend that may be having a slow hour, and quietly doubling that spend is a harness
            // defect. Nothing here measures latency either — the numbers in `docs/EVALUATION.md`
            // come from the dictation benchmark, which runs the product path hedge and all.
            hedgeStalledRequests: false)
    }

    /// Transcribes once. `context` of `nil` produces the no-context baseline.
    ///
    /// Retries transient failures rather than aborting. A suite run costs twenty minutes and real
    /// money, and losing it to one dropped connection is a harness defect, not a finding.
    ///
    /// Deliberately *not* `transcribeLong`: chunking would split a long fixture across requests
    /// and stitch the results, and a suite that measured stitched output could not attribute a
    /// difference to grounding. The eval clips are all well under the chunking threshold anyway.
    public func transcribe(audio: AudioFile, context: ScreenContext?) async throws
        -> TranscriptionResult
    {
        guard let cassette else {
            return try await service.transcribeWithRetry(
                audio: audio, context: context, attempts: 4, initialDelay: .milliseconds(800))
        }

        // Keyed on what goes into the request rather than on the bytes that leave, so a cassette
        // recorded on one machine replays on another. See `CassetteKey`.
        let key = CassetteKey.make(
            model: model, fidelity: fidelity, systemInstruction: systemInstruction,
            context: context, keyterms: derivedKeyterms(for: context), audio: audio.data)

        if await cassette.isReplaying {
            return try await cassette.take(
                for: key,
                hint: context == nil ? "no context" : "with context")
        }

        let result = try await service.transcribeWithRetry(
            audio: audio, context: context, attempts: 4, initialDelay: .milliseconds(800))
        await cassette.record(result, for: key)
        return result
    }

    /// The keyterm list this run would send, which is part of the request and therefore of the key.
    private func derivedKeyterms(for context: ScreenContext?) -> [String] {
        guard keytermBiasing, let context, !context.isEmpty,
            case .keyterms(let maxTerms, let maxChars) = grounding
        else { return [] }
        return Keyterms.derive(from: context, maxTerms: maxTerms, maxCharsPerTerm: maxChars)
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
            mustBeScript: testCase.mustBeScript,
            minCharacters: testCase.minCharacters,
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
