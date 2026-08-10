import ArgumentParser
import DoNotTypeCore
import Foundation

// The harness that has to work before any macOS code is written. Its job is to answer one
// question with a number: does "context corrects spelling, never content" actually hold?

@main
struct DntEval: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dnt-eval",
        abstract: "Measure what screen context does to a transcript.",
        subcommands: [
            Probe.self, Once.self, Suite.self, Ablate.self, Rewrite.self, Conformance.self, Encode.self,
        ],
        defaultSubcommand: Suite.self
    )
}

// MARK: - Shared options

struct ProviderOptions: ParsableArguments {
    @Option(name: .long, help: "Backend: gemini or openrouter.")
    var provider: String = "gemini"

    @Option(name: .long, help: "Model ID. Defaults to the provider's Gemini Flash.")
    var model: String?

    @Option(name: .long, help: "Fidelity: raw, light, or tidy.")
    var fidelity: String = Fidelity.default.rawValue

    @Option(name: .long, help: "Path to PROMPT.md. Found by walking up from cwd if omitted.")
    var prompt: String?

    func resolveKind() throws -> ProviderKind {
        guard let kind = ProviderKind(rawValue: provider.lowercased()) else {
            throw ValidationError(
                "Unknown provider '\(provider)'. Options: "
                    + ProviderKind.allCases.map(\.rawValue).joined(separator: ", "))
        }
        return kind
    }

    func resolveFidelity() throws -> Fidelity {
        guard let value = Fidelity(rawValue: fidelity.lowercased()) else {
            throw ValidationError(
                "Unknown fidelity '\(fidelity)'. Options: "
                    + Fidelity.allCases.map(\.rawValue).joined(separator: ", "))
        }
        return value
    }

    func resolveSystemInstruction() throws -> String {
        let url =
            prompt.map { URL(fileURLWithPath: $0) }
            ?? PromptBuilder.findPromptFile()
        guard let url else {
            throw ValidationError("Could not find PROMPT.md — pass --prompt.")
        }
        return try PromptBuilder(contentsOf: url).systemInstruction(fidelity: try resolveFidelity())
    }

    func makeRunner() throws -> (EvalRunner, ProviderKind) {
        let kind = try resolveKind()
        let runner = EvalRunner(
            provider: try ProviderFactory.make(kind),
            model: model ?? kind.defaultModel,
            systemInstruction: try resolveSystemInstruction()
        )
        return (runner, kind)
    }
}

// MARK: - probe

/// Smallest possible round trip. Confirms auth, request shape, and — when given audio — that the
/// provider actually forwards it.
struct Probe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Validate a provider end to end.")

    @OptionGroup var options: ProviderOptions

    @Option(name: .long, help: "Optional audio file, to verify the provider forwards audio.")
    var audio: String?

    mutating func run() async throws {
        let (runner, kind) = try options.makeRunner()
        print("provider  \(kind.rawValue)")
        print("model     \(runner.model)")

        guard let audio else {
            let result = try await runner.provider.transcribe(
                TranscriptionRequest(
                    model: runner.model,
                    systemInstruction: "You are a transcription engine.",
                    parts: [.text("Pretend the audio said: hello there. Transcribe it.")]))
            print("output    \(result.transcript.transcript)")
            print("\n✓ text round trip OK — audio not exercised (pass --audio to verify it)")
            return
        }

        let file = try AudioFile(contentsOf: URL(fileURLWithPath: audio))
        print("audio     \(file.url.lastPathComponent) · \(file.data.count) bytes · \(file.mimeType)")
        let result = try await runner.transcribe(audio: file, context: nil)
        print("audioTok  \(result.usage.audioTokens.map(String.init) ?? "not reported")")
        print("output    \(result.transcript.transcript)")
        print("\n✓ audio round trip OK")
    }
}

// MARK: - once

/// A single case, run both ways, printed in full. The debugging tool.
struct Once: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Transcribe one recording with and without context.")

    @OptionGroup var options: ProviderOptions

    @Option(name: .long, help: "Path to the recording.") var audio: String
    @Option(name: .long, help: "Visible screen text to ground on.") var visibleText: String?
    @Option(name: .long, help: "Text immediately before the caret.") var beforeCaret: String?
    @Option(name: .long, help: "Foreground app name.") var app: String?
    @Option(name: .long, help: "Focused window title.") var windowTitle: String?

    mutating func run() async throws {
        let (runner, _) = try options.makeRunner()
        let file = try AudioFile(contentsOf: URL(fileURLWithPath: audio))
        let context = ScreenContext(
            appName: app, windowTitle: windowTitle,
            visibleText: visibleText, textBeforeCaret: beforeCaret)

        let withContext = try await runner.transcribe(audio: file, context: context)
        let withoutContext = try await runner.transcribe(audio: file, context: nil)
        let report = TranscriptDiff.compare(
            withoutContext: withoutContext.transcript.transcript,
            withContext: withContext.transcript.transcript)

        print("context OFF  \(withoutContext.transcript.transcript)")
        print("context ON   \(withContext.transcript.transcript)")
        print("audio tokens \(withContext.usage.audioTokens.map(String.init) ?? "not reported")")
        print("context cost ~\(runner.encoder.estimatedTokens(context)) tokens")

        if report.spans.isEmpty {
            print("\ndiff         none — context changed nothing")
        } else {
            print("\ndiff")
            for span in report.spans {
                print("  \(marker(span.classification)) \(span.classification.rawValue.padding(toLength: 15, withPad: " ", startingAt: 0)) \(span.description)")
            }
        }
        if report.bugCount > 0 { throw ExitCode.failure }
    }
}

// MARK: - suite

/// The number that decides whether grounding ships on by default.
struct Suite: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run every near-miss case and report the classification table.")

    @OptionGroup var options: ProviderOptions

    @Argument(help: "Directory of case JSON files.")
    var directory: String = "eval/nearmiss"

    @Option(
        name: .long,
        help: "Runs per case. Transcription is non-deterministic; one run is an anecdote.")
    var repeatCount: Int = 3

    mutating func run() async throws {
        let (runner, kind) = try options.makeRunner()
        let cases = try EvalRunner.loadCases(in: URL(fileURLWithPath: directory))
        guard !cases.isEmpty else {
            throw ValidationError("No .json cases found in \(directory)")
        }

        print(
            "provider \(kind.rawValue) · model \(runner.model) · \(cases.count) cases × \(repeatCount) runs\n")

        var all: [EvalOutcome] = []
        var regressions: [EvalOutcome] = []

        var errored: [String] = []

        // Outcomes grouped by which pass produced them. Every case is run `repeatCount` times, so
        // pass 0 across all cases is a complete, independent suite result — as is pass 1, and pass
        // 2. Reporting the spread between them costs nothing and is the only thing standing between
        // a reader and the mistake this project keeps making: treating a two-point move in a noisy
        // count as evidence that a change did something.
        var byPass = [[EvalOutcome]](repeating: [], count: max(1, repeatCount))
        var unstable: [String] = []

        for (testCase, url) in cases {
            var runs: [EvalOutcome] = []
            for pass in 0..<repeatCount {
                do {
                    let outcome = try await runner.run(testCase, caseFile: url)
                    byPass[pass].append(outcome)
                    runs.append(outcome)
                } catch {
                    // One unreachable case must not discard the whole run. Recorded and reported
                    // rather than swallowed, so a partial suite is never mistaken for a clean one.
                    errored.append("\(testCase.id): \(error.localizedDescription)")
                }
            }
            guard !runs.isEmpty else {
                print("ERROR \(testCase.id)  — all \(repeatCount) runs failed")
                continue
            }
            all.append(contentsOf: runs)
            regressions.append(contentsOf: runs.filter { $0.effect.isBug })

            let passes = runs.count(where: { $0.passed })
            let verdict =
                passes == runs.count ? "PASS " : (passes == 0 ? "FAIL " : "FLAKY")
            print("\(verdict) \(testCase.id)  \(passes)/\(runs.count)")
            if passes != 0 && passes != runs.count { unstable.append(testCase.id) }

            // Show one representative failure rather than repeating near-identical output.
            if let failure = runs.first(where: { !$0.passed }) {
                print("      expected  \(failure.expected)")
                print("      got       \(failure.withContext)")
                print("      baseline  \(failure.withoutContext)")
                print("      effect    \(failure.effect.rawValue)")
            }
        }

        let effect = { (kind: GroundingEffect) in all.count(where: { $0.effect == kind }) }

        /// Smallest and largest count this effect took in any single pass, so the reader can see
        /// how much one suite run would have moved on its own.
        func spread(_ kind: GroundingEffect) -> String {
            let perPass = byPass.filter { !$0.isEmpty }.map { $0.count(where: { $0.effect == kind }) }
            guard let low = perPass.min(), let high = perPass.max(), perPass.count > 1 else {
                return ""
            }
            return low == high ? "  (\(low) every pass)" : "  (\(low)–\(high) per pass)"
        }

        print("\n─────────────────────────────────────────────")
        print("runs             \(all.count)  (\(all.count(where: \.passed)) matched ground truth)")
        print("improved         \(effect(.improved))\(spread(.improved))   ← context fixed a wrong baseline")
        print("neutral-correct  \(effect(.neutralCorrect))\(spread(.neutralCorrect))")
        print("neutral-wrong    \(effect(.neutralWrong))\(spread(.neutralWrong))   ← context did not help")
        print("REGRESSED        \(effect(.regressed))\(spread(.regressed))   ← must be 0: context broke a correct baseline")

        if !unstable.isEmpty {
            print(
                "\n\(unstable.count) case(s) gave different answers across passes: "
                    + unstable.joined(separator: ", "))
        }
        if byPass.filter({ !$0.isEmpty }).count > 1 {
            print(
                "\nThe per-pass range is this suite's own noise floor. A prompt or model change "
                    + "that moves a count by less than that range has not been shown to do "
                    + "anything — re-measure with more passes before believing it.")
        }

        if !errored.isEmpty {
            print("\nerrors (\(errored.count) run(s) did not complete):")
            for message in errored.prefix(5) { print("  \(message.prefix(120))") }
        }

        if !regressions.isEmpty {
            print("\nregressions:")
            for outcome in regressions {
                print("  \(outcome.caseID): \(outcome.withoutContext) → \(outcome.withContext)")
            }
            throw ExitCode.failure
        }
    }
}

private func marker(_ classification: TranscriptDiff.Classification) -> String {
    classification.isBug ? "✗" : "✓"
}
