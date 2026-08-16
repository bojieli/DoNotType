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

    /// Which channel the contradiction arrives through, because they are not equivalent: the same
    /// decoy substitutes 3/10 from visible text and 7/10 from the caret window. A guard measured
    /// only in the weak channel has not been measured where the failure actually bites.
    @Flag(name: .long, help: "Put the contradicting text before the caret instead of in visible text.")
    var decoyBeforeCaret = false

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

    @Option(name: .long, help: "Conditions: verbatim, no-context, digit-guard, single-formal, two-formal.")
    var conditions: String = "verbatim,single-formal,two-formal"

    /// Counters for the digit-guard condition, which has two failure modes worth telling apart:
    /// the guard declining to act because the runs disagreed on how many numbers there were, and
    /// the guard acting on a value the audio-only run also got wrong.
    final class Diagnostics: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var applied = 0
        private(set) var skippedForMismatch = 0
        private(set) var agreed = 0
        private(set) var groundedSeconds = 0.0
        private(set) var audioOnlySeconds = 0.0
        private(set) var wallSeconds = 0.0

        func record(
            reconciliation: NumericGuard.Reconciliation,
            grounded: Double, audioOnly: Double, wall: Double
        ) {
            lock.withLock {
                if reconciliation.skippedForMismatch { skippedForMismatch += 1 }
                else if reconciliation.corrections.isEmpty { agreed += 1 }
                else { applied += 1 }
                groundedSeconds += grounded
                audioOnlySeconds += audioOnly
                wallSeconds += wall
            }
        }

        var summary: String {
            let total = applied + skippedForMismatch + agreed
            guard total > 0 else { return "" }
            return """
                digit-guard detail: corrected \(applied), already agreed \(agreed), \
                declined for count mismatch \(skippedForMismatch) of \(total)
                  mean leg latency: grounded \(fmt(groundedSeconds / Double(total)))s, \
                audio-only \(fmt(audioOnlySeconds / Double(total)))s, \
                wall \(fmt(wallSeconds / Double(total)))s \
                (wall near the slower leg means they really ran concurrently)
                """
        }

        private func fmt(_ value: Double) -> String { String(format: "%.2f", value) }
    }

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
        let promptURL = PromptBuilder.findPromptDirectory()
        guard let promptURL else { throw ValidationError("Could not find the prompt/ directory") }
        let builder = PromptBuilder(directory: promptURL)

        let context = decoyBeforeCaret
            ? ScreenContext(
                appName: "Safari", windowTitle: "Documentation", textBeforeCaret: visibleText)
            : ScreenContext(
                appName: "Safari", windowTitle: "Documentation", visibleText: visibleText)
        let selected = conditions.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }

        print("provider \(kind.rawValue) · model \(runner.model) · \(trials) trials per condition")
        print(
            "audio \(file.url.lastPathComponent) · spoken \"\(spoken)\" · decoy \"\(decoy)\" · "
                + "decoy in \(decoyBeforeCaret ? "the caret window" : "visible text")\n")

        let diagnostics = Diagnostics()
        var results: [(String, Outcome)] = []
        for condition in selected {
            var outcome = Outcome()
            for _ in 0..<trials {
                let started = Date()
                do {
                    let text = try await runOne(
                        condition: condition, audio: file, context: context,
                        builder: builder, runner: runner, diagnostics: diagnostics)
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
        if !diagnostics.summary.isEmpty { print("\n" + diagnostics.summary) }
        print("\nLower substitution is better. Latency is what the user feels after releasing the key.")
    }

    private func timed<T: Sendable>(
        _ work: @Sendable () async throws -> T
    ) async rethrows -> (T, Double) {
        let started = Date()
        return (try await work(), Date().timeIntervalSince(started))
    }

    private func runOne(
        condition: String, audio: AudioFile, context: ScreenContext,
        builder: PromptBuilder, runner: EvalRunner, diagnostics: Diagnostics
    ) async throws -> String {
        switch condition {
        case "no-context":
            return try await runner.transcribe(audio: audio, context: nil)
                .transcript.transcript

        case "verbatim":
            return try await runner.transcribe(audio: audio, context: context)
                .transcript.transcript

        case "digit-guard":
            // Grounded and audio-only together, then take the numbers from the run that could not
            // have seen the screen. They must genuinely overlap -- run one after the other this
            // doubles the wait and is indefensible -- so the legs are timed individually and the
            // wall time is reported next to them rather than assumed.
            let wallStart = Date()
            async let groundedTimed = timed {
                try await runner.transcribe(audio: audio, context: context).transcript.transcript
            }
            async let audioOnlyTimed = timed {
                try await runner.transcribe(audio: audio, context: nil).transcript.transcript
            }
            let (grounded, groundedSeconds) = try await groundedTimed
            let (audioOnly, audioOnlySeconds) = try await audioOnlyTimed

            let reconciliation = NumericGuard.reconcile(grounded: grounded, audioOnly: audioOnly)
            diagnostics.record(
                reconciliation: reconciliation, grounded: groundedSeconds,
                audioOnly: audioOnlySeconds, wall: Date().timeIntervalSince(wallStart))
            return reconciliation.text

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
