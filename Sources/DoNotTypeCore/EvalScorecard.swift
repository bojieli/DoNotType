import Foundation

/// Every transcript a suite run produced, in a form that can be scored again with no audio.
///
/// ## Why this exists when cassettes already do
///
/// A cassette is keyed by a hash of the request, and the audio is part of that hash — so replaying
/// one needs the clips. Seven of the sixteen near-miss clips are cut from the maintainer's own
/// recordings and `eval/audio/*.wav` is gitignored for that reason, which means the cassettes in
/// this repository cannot be replayed by anybody who clones it, CI included. The CI job that
/// claimed to re-score them was looking for a filename that was never committed, so it skipped
/// itself and reported success; when pointed at a real cassette it found nothing for any request
/// and still exited 0. Two layers of green over a check that had never once run.
///
/// A scorecard is the other half of the cassette. It drops the request — no audio, no key, nothing
/// derived from the recording — and keeps only what the provider said, labelled by case and pass.
/// That is enough to rebuild every `EvalOutcome` and re-run the part of this project that is
/// actually ours: the assertions, the diff classification, the pass/fail rule, the counts. It is
/// checkable by anyone, in CI, for free.
///
/// ## What it deliberately does not do
///
/// **It is not evidence about a model.** Neither is a cassette replay. Re-scoring stored answers
/// tells you the scorer still classifies them the same way and nothing whatever about the backend.
/// The counts a scorecard carries are the counts from the paid run that produced it, and they are
/// quotable only as that run.
///
/// **It does not replace the cassette.** A cassette re-runs the whole harness including the request
/// path, prompt assembly and keying; a scorecard starts after the answer came back. For anyone
/// holding the audio the cassette is the stronger check, so both are written by the same run.
public struct EvalScorecard: Codable, Sendable {
    /// One case, run once, both arms.
    public struct Entry: Codable, Sendable {
        public var caseID: String
        /// Which pass of `--repeat-count` produced it, so re-scoring reproduces the per-pass
        /// spread rather than flattening it into one number.
        public var pass: Int
        public var withContext: String
        public var withoutContext: String
        public var audioTokens: Int?

        public init(
            caseID: String, pass: Int, withContext: String, withoutContext: String,
            audioTokens: Int? = nil
        ) {
            self.caseID = caseID
            self.pass = pass
            self.withContext = withContext
            self.withoutContext = withoutContext
            self.audioTokens = audioTokens
        }
    }

    /// The verdict the run that wrote this file reached.
    ///
    /// Stored rather than recomputed on read, because it is the whole point: re-scoring compares
    /// what the scorer says now against what it said then, and a change in any count is a change
    /// in how this project grades itself. Without these numbers in the file, re-scoring could only
    /// confirm that the code runs.
    public struct Summary: Codable, Sendable, Equatable {
        public var runs: Int
        public var passed: Int
        public var improved: Int
        public var regressed: Int
        public var neutralCorrect: Int
        public var neutralWrong: Int

        public init(
            runs: Int, passed: Int, improved: Int, regressed: Int, neutralCorrect: Int,
            neutralWrong: Int
        ) {
            self.runs = runs
            self.passed = passed
            self.improved = improved
            self.regressed = regressed
            self.neutralCorrect = neutralCorrect
            self.neutralWrong = neutralWrong
        }

        public init(outcomes: [EvalOutcome]) {
            self.init(
                runs: outcomes.count,
                passed: outcomes.count(where: \.passed),
                improved: outcomes.count(where: { $0.effect == .improved }),
                regressed: outcomes.count(where: { $0.effect == .regressed }),
                neutralCorrect: outcomes.count(where: { $0.effect == .neutralCorrect }),
                neutralWrong: outcomes.count(where: { $0.effect == .neutralWrong }))
        }

        /// Every count that moved, named. Printed on a mismatch instead of "scores differ",
        /// because the caller's next question is always which one.
        public func differences(from other: Summary) -> [String] {
            var differences: [String] = []
            func compare(_ label: String, _ mine: Int, _ theirs: Int) {
                if mine != theirs { differences.append("\(label) \(mine) → \(theirs)") }
            }
            compare("runs", runs, other.runs)
            compare("passed", passed, other.passed)
            compare("improved", improved, other.improved)
            compare("regressed", regressed, other.regressed)
            compare("neutral-correct", neutralCorrect, other.neutralCorrect)
            compare("neutral-wrong", neutralWrong, other.neutralWrong)
            return differences
        }
    }

    /// Reuses the cassette's provenance verbatim: the same fields matter for the same reasons, and
    /// two spellings of "what produced this" is one more than a reader should have to reconcile.
    public var provenance: Cassette.Provenance
    /// Which case directory the entries name, so re-scoring reads the same definitions.
    public var caseDirectory: String
    public var summary: Summary
    public var entries: [Entry]

    public init(
        provenance: Cassette.Provenance, caseDirectory: String, summary: Summary, entries: [Entry]
    ) {
        self.provenance = provenance
        self.caseDirectory = caseDirectory
        self.summary = summary
        self.entries = entries
    }

    /// Writes it out sorted and pretty-printed, because this file is committed and a reviewer
    /// should be able to read a diff of it.
    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    public static func read(from url: URL) throws -> EvalScorecard {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(EvalScorecard.self, from: try Data(contentsOf: url))
    }

    public enum ScorecardError: LocalizedError {
        case unknownCase(String, available: [String])
        case empty(URL)
        case regraded(URL, [String])

        public var errorDescription: String? {
            switch self {
            case .unknownCase(let id, let available):
                """
                The scorecard names a case '\(id)' that is not in the case directory. \
                Cases found: \(available.joined(separator: ", ")).

                A renamed or deleted case makes an existing scorecard unscoreable, which is \
                correct — the stored answers were produced against assertions that no longer \
                exist. Re-record the suite.
                """
            case .empty(let url):
                """
                The scorecard at \(url.path) has no entries, so re-scoring it measures nothing. \
                A file that grades an empty list passes every check by vacuum; that is the exact \
                failure this command exists to make impossible.
                """
            case .regraded(let url, let differences):
                """
                Re-scoring \(url.path) does not reproduce the verdict recorded in it: \
                \(differences.joined(separator: ", ")).

                Nothing about a model changed here — these are the same stored answers. What \
                changed is how this project grades them: an assertion in the case files, the \
                diff classification, the pass rule, or the effect table. That is either the point \
                of your change, in which case re-record the suite so the committed numbers match \
                what the scorer now says, or it is a regression in the scorer and the numbers in \
                docs/EVALUATION.md no longer describe the code that produced them.
                """
            }
        }
    }

    /// Rebuilds every outcome from the stored transcripts, through the same scoring code a live
    /// run uses.
    ///
    /// Grouped by pass, in the same shape the suite reports, so the spread between passes survives
    /// a round trip through this file.
    public func rescore(caseDirectory directory: URL) throws -> [[EvalOutcome]] {
        let cases = try EvalRunner.loadCases(in: directory)
        let byID = Dictionary(uniqueKeysWithValues: cases.map { ($0.0.id, $0.0) })
        guard !entries.isEmpty else { throw ScorecardError.empty(directory) }

        let passCount = (entries.map(\.pass).max() ?? 0) + 1
        var byPass = [[EvalOutcome]](repeating: [], count: passCount)
        for entry in entries.sorted(by: { ($0.pass, $0.caseID) < ($1.pass, $1.caseID) }) {
            guard let testCase = byID[entry.caseID] else {
                throw ScorecardError.unknownCase(
                    entry.caseID, available: byID.keys.sorted())
            }
            byPass[entry.pass].append(
                EvalOutcome(
                    caseID: testCase.id,
                    expected: testCase.expectTranscript ?? "",
                    mustContain: testCase.mustContain ?? [],
                    mustNotContain: testCase.mustNotContain ?? [],
                    mustBeScript: testCase.mustBeScript,
                    minCharacters: testCase.minCharacters,
                    withContext: entry.withContext,
                    withoutContext: entry.withoutContext,
                    report: TranscriptDiff.compare(
                        withoutContext: entry.withoutContext,
                        withContext: entry.withContext),
                    audioTokens: entry.audioTokens))
        }
        return byPass
    }
}
