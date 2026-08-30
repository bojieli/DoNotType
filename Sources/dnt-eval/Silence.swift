import ArgumentParser
import DoNotTypeCore
import Foundation

/// Asks a real backend to transcribe recordings with nothing in them, and reports what comes back.
///
/// The app never sends these — `SpeechActivity` stops them before the request, and that gate is the
/// defence somebody actually relies on. This measures the thing the gate is protecting against, so
/// the protection is a measured decision rather than a belief:
///
/// - **`prompt/system.md` rule 7 is otherwise untested.** It says silent or unintelligible audio returns
///   an empty transcript. Nothing in the suite has ever checked whether a model obeys it.
/// - **Recognisers never receive the rule at all.** Deepgram, xAI and Mistral Voxtral have no
///   system instruction, so for them rule 7 does not exist. They are also the backends most
///   documented for inventing a stock phrase over silence, which makes them the interesting case.
///
/// A pass here is an empty transcript. Anything else is the model inventing words for audio that
/// contained none, and the number worth knowing is how often.
///
/// ```
/// dnt-eval silence --provider google
/// dnt-eval silence --provider deepgram --repeat-count 5
/// ```
struct Silence: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "What a backend returns for silence, noise and a keyboard click.")

    @Option(name: .long, help: "Backend to ask.")
    var provider: String = "google"

    @Option(name: .long, help: "Model override.")
    var model: String?

    @Option(name: .long, help: "Directory of recordings that should transcribe to nothing.")
    var corpus: String = "eval/audio/silence"

    @Option(
        name: .long,
        help: "Runs per recording. A model that invents a sentence once in five is still broken.")
    var repeatCount: Int = 3

    @Option(name: .long, help: "Write the full result here as JSON.")
    var output: String?

    struct Attempt: Encodable {
        var recording: String
        var run: Int
        var transcript: String
        var isEmpty: Bool
        var error: String?
    }

    func run() async throws {
        guard let kind = ProviderKind(persistedValue: provider) else {
            throw ValidationError("Unknown provider '\(provider)'")
        }
        let instruction = try PromptBuilder(
            directory: PromptBuilder.findPromptDirectory()
                ?? URL(fileURLWithPath: "prompt")).systemInstruction(fidelity: .default)

        let service = TranscriptionService(
            provider: try ProviderFactory.make(kind),
            model: model ?? kind.defaultModel,
            systemInstruction: instruction,
            fidelity: .default,
            // The harness measures the backend, not this app's typography. See `EvalCase`.
            typography: .unchanged)

        let recordings = try FileManager.default
            .contentsOfDirectory(atPath: corpus)
            .filter { $0.hasSuffix(".wav") }
            .sorted()
        guard !recordings.isEmpty else {
            throw ValidationError("no .wav recordings in \(corpus)")
        }

        note(
            "\(kind.rawValue) · \(service.model) · \(recordings.count) recordings × \(repeatCount)")
        if kind.isSpeechRecognition {
            note(
                "note: this backend has no system instruction, so system.md rule 7 never reaches "
                    + "it. Whatever it does here, it does without having been asked not to.")
        }

        var attempts: [Attempt] = []
        for name in recordings {
            let url = URL(fileURLWithPath: corpus).appendingPathComponent(name)
            let audio = try AudioDecoder.load(url)

            for run in 1...repeatCount {
                do {
                    let result = try await service.transcribe(audio: audio, context: nil)
                    let text = result.transcript.transcript.trimmed
                    attempts.append(
                        Attempt(
                            recording: name, run: run, transcript: text, isEmpty: text.isEmpty,
                            error: nil))
                } catch ProviderError.emptyOutput {
                    // Provider clients reject a blank transcript on ordinary speech because losing
                    // a real dictation must be visible. In this command blank is the expected
                    // result: Deepgram and the other recognisers represent it with `emptyOutput`,
                    // just as ProviderProbe already accepts when its silent recording completes.
                    attempts.append(
                        Attempt(
                            recording: name, run: run, transcript: "", isEmpty: true,
                            error: nil))
                } catch {
                    // An error is not a hallucination. It is reported separately rather than
                    // counted as a pass, because a backend that fails on silence has not
                    // demonstrated the behaviour being measured either way.
                    attempts.append(
                        Attempt(
                            recording: name, run: run, transcript: "", isEmpty: false,
                            error: error.localizedDescription))
                }
            }
        }

        report(attempts)

        if let output {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(attempts)
            try data.write(to: URL(fileURLWithPath: output))
            note("wrote \(output)")
        }

        // A non-zero exit when anything was invented, so this can gate a release.
        if attempts.contains(where: { !$0.isEmpty && $0.error == nil }) {
            throw ExitCode.failure
        }
    }

    private func report(_ attempts: [Attempt]) {
        say("")
        say("recording              runs   empty   invented   errored")

        for name in Set(attempts.map(\.recording)).sorted() {
            let mine = attempts.filter { $0.recording == name }
            let empty = mine.filter { $0.isEmpty }.count
            let errored = mine.filter { $0.error != nil }.count
            let invented = mine.count - empty - errored
            let flag = invented > 0 ? "  ← invented words" : ""
            say(
                name.padding(toLength: 22, withPad: " ", startingAt: 0)
                    + String(format: "%5d%8d%11d%10d", mine.count, empty, invented, errored)
                    + flag)
        }

        // The transcripts themselves, because "it said something" is not as useful as knowing it
        // said "Thank you." — that is the signature of the failure and worth recognising by eye.
        let invented = attempts.filter { !$0.isEmpty && $0.error == nil }
        if !invented.isEmpty {
            say("")
            say("what it invented:")
            for attempt in invented {
                say("  \(attempt.recording) run \(attempt.run): \"\(attempt.transcript)\"")
            }
        }

        let total = attempts.filter { $0.error == nil }.count
        let clean = attempts.filter(\.isEmpty).count
        say("")
        say(
            total == 0
                ? "every attempt errored; nothing was measured"
                : "\(clean)/\(total) returned nothing, which is the only correct answer here")
    }
}

private func note(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }
private func say(_ text: String) { print(text) }
