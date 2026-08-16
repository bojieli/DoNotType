import ArgumentParser
import DoNotTypeCore
import Foundation

/// Measures the rewrite stage on its own terms.
///
/// The rewrite is a **formatting** feature, not a fidelity one: it exists so a dictated paragraph
/// can become an email, with filler removed and ideas ordered. Judging it on substitution — the
/// transcription problem — was a category error, and it is the reason this command exists
/// separately from `ablate`.
///
/// What a rewrite must not do is invent, drop, or "correct" content. Numbers, names and
/// identifiers came from speech and are not the rewriter's to fix, which is rule 2 of
/// `prompt/rewrite.md`. This measures exactly that, with no audio involved — text in, text out,
/// so a full run costs seconds rather than minutes.
struct Rewrite: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Measure whether the rewrite stage preserves facts while changing style.")

    @OptionGroup var options: ProviderOptions

    @Option(name: .long, help: "Styles to test, comma separated.")
    var styles: String = "formal,concise,bullets"

    @Option(name: .long, help: "Runs per case per style.")
    var trials: Int = 3

    /// Deliberately full of things a helpful model might want to "fix": a stale version number, an
    /// unusual library name, a port, a rounded figure, and a name that looks like a typo.
    struct Case {
        let id: String
        let transcript: String
        /// Every token that must survive verbatim.
        let mustKeep: [String]
    }

    static let cases: [Case] = [
        Case(
            id: "stale-version",
            transcript:
                "um so we're still on Gemini 1.5 Flash for the batch job, you know, and I think "
                + "we should probably move it to the newer one at some point but not this week",
            mustKeep: ["1.5"]),
        Case(
            id: "identifiers",
            transcript:
                "so the koffi bindings load libContextHelper.dylib and uh we call "
                + "getFocusedAppInfo from there, that's the whole bridge basically",
            mustKeep: ["koffi", "libContextHelper.dylib", "getFocusedAppInfo"]),
        Case(
            id: "numbers",
            transcript:
                "right so it's running on port 8081 not 8080, and the timeout is 500 milliseconds, "
                + "and we saw like 11 failures out of 19 runs which is way too many",
            mustKeep: ["8081", "8080", "500", "11", "19"]),
        Case(
            id: "names",
            transcript:
                "can you send the draft to Priya and cc Marcus, and um also loop in Bojie because "
                + "he asked about it yesterday",
            mustKeep: ["Priya", "Marcus", "Bojie"]),
        Case(
            id: "hedges",
            transcript:
                "I think we should probably ship it on Friday, but I'm not certain the migration "
                + "will be done, so maybe hold off if it looks risky",
            // A rewriter that "improves" this into a commitment has changed its meaning.
            mustKeep: ["probably", "not certain", "maybe"]),
    ]

    mutating func run() async throws {
        let (runner, kind) = try options.makeRunner()
        guard let promptURL = PromptBuilder.findPromptDirectory() else {
            throw ValidationError("Could not find the prompt/ directory")
        }
        let builder = PromptBuilder(directory: promptURL)

        let selected = styles.split(separator: ",").compactMap {
            RewriteStyle(rawValue: $0.trimmingCharacters(in: .whitespaces))
        }
        guard !selected.isEmpty else { throw ValidationError("No valid styles given") }

        print("provider \(kind.rawValue) · model \(runner.model) · \(trials) runs per case\n")

        var totals: [RewriteStyle: (kept: Int, lost: Int, empty: Int)] = [:]

        for style in selected {
            let instruction = try builder.rewriteInstruction(style: style)
            var kept = 0
            var lost = 0
            var empty = 0
            var examples: [String] = []

            for testCase in Self.cases {
                for _ in 0..<trials {
                    let rewritten: String
                    do {
                        rewritten = try await runner.provider.transcribe(
                            TranscriptionRequest(
                                model: runner.model,
                                systemInstruction: instruction,
                                parts: [.text(testCase.transcript)])
                        ).transcript.transcript
                    } catch {
                        empty += 1
                        continue
                    }
                    guard !rewritten.trimmed.isEmpty else {
                        empty += 1
                        continue
                    }

                    let missing = testCase.mustKeep.filter { !rewritten.containsLoosely($0) }
                    if missing.isEmpty {
                        kept += 1
                    } else {
                        lost += 1
                        if examples.count < 3 {
                            examples.append("\(testCase.id): lost \(missing) → \(rewritten.prefix(90))")
                        }
                    }
                }
            }

            totals[style] = (kept, lost, empty)
            let judged = kept + lost
            let rate = judged == 0 ? "n/a" : String(format: "%.0f%%", Double(lost) / Double(judged) * 100)
            print("\(style.rawValue): lost content in \(lost)/\(judged) (\(rate))")
            for example in examples { print("  \(example)") }
        }

        print("\n────────────────────────────────────────────")
        print("style      preserved  lost   error   loss rate")
        for style in selected {
            guard let total = totals[style] else { continue }
            let judged = total.kept + total.lost
            let rate = judged == 0 ? "  —  " : String(
                format: "%5.0f%%", Double(total.lost) / Double(judged) * 100)
            print(
                style.rawValue.padding(toLength: 11, withPad: " ", startingAt: 0)
                    + String(format: "%9d  %4d  %6d  ", total.kept, total.lost, total.empty)
                    + rate)
        }
        print("\nLoss rate is the number that matters: a rewrite may change how it reads,")
        print("never what it says. Anything above zero is a defect in the rewrite prompt.")

        let anyLoss = totals.values.contains { $0.lost > 0 }
        if anyLoss { throw ExitCode.failure }
    }
}
