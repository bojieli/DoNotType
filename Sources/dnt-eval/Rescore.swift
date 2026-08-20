import ArgumentParser
import DoNotTypeCore
import Foundation

/// Re-grades a committed scorecard. The one eval check CI can actually run.
///
/// This exists because the job that claimed to do it could not. Replaying a cassette needs the
/// audio, and `eval/audio/*.wav` is gitignored — seven of the sixteen near-miss clips are cut from
/// the maintainer's own recordings — so no runner and no contributor has ever been able to replay
/// one. The CI job looked for a cassette filename that was never committed and skipped itself when
/// it did not find one, which is why the failure survived: a skipped step and a passing step are
/// the same colour.
///
/// A scorecard drops the audio and keeps the answers, so this runs anywhere, in seconds, for free.
/// What it checks is narrow and worth checking: that this project still grades the same transcripts
/// the same way. Every assertion in `eval/nearmiss/`, the diff classification, the pass rule and
/// the effect table are exercised; nothing about any model is.
struct Rescore: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rescore",
        abstract: "Re-grade committed transcripts and check the verdict still matches.",
        discussion: """
            Needs no audio, no key and no network. Reads the transcripts a paid run wrote with \
            `dnt-eval suite --scorecard`, scores them again, and fails if any count moved.

            A change here is a change in how this project grades itself. If it was intended, \
            re-record the suite so the committed numbers describe the code that produced them.
            """)

    @Argument(help: "Scorecard files to re-grade. Defaults to every one committed.")
    var scorecards: [String] = []

    @Option(
        name: .long,
        help: "Directory of case JSON files. Defaults to the one each scorecard names.")
    var directory: String?

    /// Where scorecards live when none is named. A directory rather than a filename, so adding a
    /// backend to the corpus does not need this command taught about it — the last CI job to hard
    /// code an eval filename spent a week reporting success about a file that did not exist.
    static let defaultDirectory = "eval/scorecards"

    mutating func run() async throws {
        let paths = try resolvePaths()
        print("re-scoring \(paths.count) scorecard(s)\n")

        var failures: [String] = []

        for path in paths {
            let url = URL(fileURLWithPath: path)
            let scorecard = try EvalScorecard.read(from: url)
            let caseDirectory = URL(fileURLWithPath: directory ?? scorecard.caseDirectory)

            let byPass = try scorecard.rescore(caseDirectory: caseDirectory)
            let all = byPass.flatMap { $0 }
            let now = EvalScorecard.Summary(outcomes: all)
            let differences = scorecard.summary.differences(from: now)

            let provenance = scorecard.provenance
            print("\(url.lastPathComponent)")
            print(
                "  recorded  \(provenance.provider) · \(provenance.model) · "
                    + "\(provenance.fidelity) · prompt \(provenance.promptDigest) · "
                    + ISO8601DateFormatter().string(from: provenance.recordedAt))
            print(
                "  scored    \(now.runs) runs · \(now.passed) matched ground truth · "
                    + "\(now.improved) improved · \(now.regressed) regressed")

            if differences.isEmpty {
                // Deliberately not "✓ passed". This command answers one question — does the
                // scorer still grade these transcripts the same way — and a bare tick would be
                // read as the suite passing, which it does not say and must not imply. The
                // recorded run's own verdict is a separate matter, reported next.
                print("  ✓ scoring unchanged — every count reproduces")
                if now.regressed > 0 {
                    // A green tick above a recorded regression is the exact shape of the failure
                    // this command replaced. `suite` exits non-zero for these; this command is
                    // not the gate, so it says so rather than quietly disagreeing.
                    print(
                        "  ! but the recorded run itself did not meet the suite's gate: "
                            + "\(now.regressed) run(s) regressed, and that count must be 0. "
                            + "Re-scoring cannot fix that — it is a property of the run, not of "
                            + "the scoring. See docs/EVALUATION.md.")
                }
                print("")
            } else {
                // Named in full, both here and in the thrown error: the counts are the finding,
                // and a reader who has to re-run the command to see which one moved has been
                // told nothing.
                print("  ✗ \(differences.joined(separator: ", "))\n")
                failures.append(
                    EvalScorecard.ScorecardError.regraded(url, differences).errorDescription ?? "")
            }
        }

        guard failures.isEmpty else {
            for failure in failures { print(failure) }
            throw ExitCode.failure
        }
        print("✓ \(paths.count) scorecard(s) re-scored, every count unchanged")
        print(
            "  This checked the scoring, not any model: the transcripts are stored, so nothing "
                + "here is new evidence about a backend.")
    }

    private func resolvePaths() throws -> [String] {
        if !scorecards.isEmpty { return scorecards }

        let directory = URL(fileURLWithPath: Self.defaultDirectory)
        let found =
            (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "json" }
            .map(\.path)
            .sorted() ?? []

        // A run that scored nothing must never report success — that is the bug this command was
        // written to replace, and it would be a poor joke to reintroduce it here.
        guard !found.isEmpty else {
            throw ValidationError(
                """
                No scorecards found in \(Self.defaultDirectory)/, so there is nothing to re-score \
                and this is a failure rather than a pass.

                Write one from a paid suite run:

                    swift run dnt-eval suite --scorecard \
                \(Self.defaultDirectory)/<provider>-<model>.json

                Then commit it, and every run after that is free.
                """)
        }
        return found
    }
}
