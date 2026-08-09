import ArgumentParser
import DoNotTypeCore
import Foundation

/// Measures competing designs against each other on the same audio.
///
/// Built because a mechanism argument is not evidence. Two conclusions in this project were
/// reached by reasoning and then contradicted by measurement: that restating the content rule
/// nearer the audio would help (it made substitution worse, 11/19 → 15/18, because the example
/// named the wrong answer), and that a two-pass rewrite must beat a single pass. Anything that
/// changes fidelity or latency should come through here first.
struct Ablate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Compare prompt and pipeline variants on fidelity and latency.")

    @OptionGroup var options: ProviderOptions

    @Option(name: .long, help: "Recording to test against.")
    var audio: String = "eval/audio/real-talk-gemini15.wav"

    @Option(name: .long, help: "Screen text that contradicts the audio.")
    var visibleText: String =
        "Gemini 2.5 Flash is the current model. See the Gemini 2.5 guide. Gemini 2.5 Flash "
        + "pricing is lower. Upgrade to Gemini 2.5 today. Gemini 2.5 Flash benchmarks."

    @Option(name: .long, help: "Value the speaker actually said.")
    var spoken: String = "1.5"

    @Option(name: .long, help: "Value on screen that must never appear in the transcript.")
    var decoy: String = "2.5"

    @Option(name: .long, help: "Runs per condition. Below ~15 the intervals are too wide to act on.")
    var trials: Int = 15

    @Option(name: .long, help: "Conditions to run: verbatim, single-formal, two-formal, no-context.")
    var conditions: String = "verbatim,single-formal,two-formal"

    struct Outcome {
        var correct = 0
        var substituted = 0
        var noVersion = 0
        var totalSeconds = 0.0
        var errors = 0
        var sample = ""

        var judged: Int { correct + substituted }
        var substitutionRate: Double {
            judged == 0 ? 0 : Double(substituted) / Double(judged)
        }
    }

    mutating func run() async throws {
        let (runner, kind) = try options.makeRunner()
        let file = try AudioFile(contentsOf: URL(fileURLWithPath: audio))
        let promptURL = PromptBuilder.findPromptFile()
        guard let promptURL else { throw ValidationError("Could not find PROMPT.md") }
        let builder = try PromptBuilder(contentsOf: promptURL)

        let context = ScreenContext(
            appName: "Safari", windowTitle: "Documentation", visibleText: visibleText)
        let selected = conditions.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }

        print("provider \(kind.rawValue) · model \(runner.model) · \(trials) trials per condition")
        print("audio \(file.url.lastPathComponent) · spoken \"\(spoken)\" · decoy \"\(decoy)\"\n")

        var results: [(String, Outcome)] = []
        for condition in selected {
            var outcome = Outcome()
            for _ in 0..<trials {
                let started = Date()
                do {
                    let text = try await runOne(
                        condition: condition, audio: file, context: context,
                        builder: builder, runner: runner)
                    outcome.totalSeconds += Date().timeIntervalSince(started)
                    if outcome.sample.isEmpty { outcome.sample = String(text.prefix(90)) }

                    if text.contains(decoy) { outcome.substituted += 1 }
                    else if text.contains(spoken) { outcome.correct += 1 }
                    else { outcome.noVersion += 1 }
                } catch {
                    outcome.errors += 1
                }
            }
            results.append((condition, outcome))
            report(condition, outcome)
        }

        print("\n────────────────────────────────────────────────────────────")
        print("condition        subst.  correct  n/a  err   rate    mean latency")
        for (condition, outcome) in results {
            let rate = outcome.judged == 0
                ? "  —  "
                : String(format: "%5.0f%%", outcome.substitutionRate * 100)
            let latency = String(
                format: "%5.2fs", outcome.totalSeconds / Double(max(1, trials - outcome.errors)))
            print(
                condition.padding(toLength: 16, withPad: " ", startingAt: 0)
                    + String(format: "%6d  %7d  %3d  %3d  ", outcome.substituted, outcome.correct,
                             outcome.noVersion, outcome.errors)
                    + rate + "   " + latency)
        }
        print("\nLower substitution is better. Latency is what the user feels after releasing the key.")
    }

    private func runOne(
        condition: String, audio: AudioFile, context: ScreenContext,
        builder: PromptBuilder, runner: EvalRunner
    ) async throws -> String {
        switch condition {
        case "no-context":
            return try await runner.transcribe(audio: audio, context: nil)
                .transcript.transcript

        case "verbatim":
            return try await runner.transcribe(audio: audio, context: context)
                .transcript.transcript

        case "single-formal":
            // One request that both transcribes and rewrites, by appending the style rule.
            let combined = try builder.systemInstruction(fidelity: .light)
                + "\n\nAfter transcribing, rewrite the transcript in this style, keeping every "
                + "number, name and identifier exactly as transcribed:\n"
                + builder.styleClause(.formal)
            let service = TranscriptionService(
                provider: runner.provider, model: runner.model, systemInstruction: combined)
            return try await service.transcribe(audio: audio, context: context)
                .transcript.transcript

        case "two-formal":
            // Transcribe verbatim, then rewrite the text with no audio and no screen context.
            let verbatim = try await runner.transcribe(audio: audio, context: context)
                .transcript.transcript
            let rewriter = TranscriptionService(
                provider: runner.provider, model: runner.model,
                systemInstruction: try builder.rewriteInstruction(style: .formal))
            return try await rewriter.provider.transcribe(
                TranscriptionRequest(
                    model: runner.model,
                    systemInstruction: try builder.rewriteInstruction(style: .formal),
                    parts: [.text(verbatim)])
            ).transcript.transcript

        default:
            throw ValidationError("Unknown condition '\(condition)'")
        }
    }

    private func report(_ condition: String, _ outcome: Outcome) {
        let rate = outcome.judged == 0 ? "n/a" : String(
            format: "%.0f%%", outcome.substitutionRate * 100)
        print("\(condition): substituted \(outcome.substituted)/\(outcome.judged) (\(rate))")
        if !outcome.sample.isEmpty { print("  e.g. \(outcome.sample)") }
    }
}
