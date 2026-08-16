import ArgumentParser
import DoNotTypeCore
import Foundation

/// Transcribes recordings that already exist.
///
/// This is the offline half of the product. Everything else in DoNotType is built around a key you
/// hold while speaking; this one takes a voice memo, a meeting recording or a `.wav` someone sent
/// you, and produces the same three things the live path can: the words, a rewrite of them, or a
/// summary of them.
///
/// The verbatim transcript is always produced, whatever mode was asked for. With `--output` it is
/// written beside the derived text rather than replaced by it, for the same reason the app keeps it
/// in history: a summary you cannot check against what was actually said is a summary you have to
/// take on faith.
struct Transcribe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transcribe",
        abstract: "Transcribe one or more recordings.",
        discussion: """
            Modes:
              verbatim              word for word, at the chosen fidelity (default)
              rewrite[:style]       verbatim, then rewritten — formal, concise, bullets
              summary[:style]       verbatim, then summarised — brief, bullets, actions

            Rewriting and summarising need a language model. When the transcription backend is a \
            recogniser (xai, deepgram, mistral), point --text-provider at a model and the recording \
            still goes to the fast recogniser.

            Formats: \(AudioDecoder.supportedFormats) and anything else CoreAudio can open. \
            Recordings longer than 90 seconds are split on silence and transcribed concurrently.
            """)

    @OptionGroup var backend: BackendOptions
    @OptionGroup var logging: LoggingOptions

    @Argument(help: "Recordings to transcribe.", completion: .file())
    var files: [String] = []

    @Option(
        name: .long,
        help: "\(TranscriptMode.acceptedSpellings.joined(separator: ", ")).")
    var mode: String = TranscriptMode.default.rawValue

    @Option(
        name: .long,
        help: "Backend for the rewrite or summary, when the transcription one cannot do text.")
    var textProvider: String?

    @Option(name: .long, help: "Model for --text-provider.")
    var textModel: String?

    @Option(
        name: .long,
        help: "Write transcripts here. A directory takes one file per recording.",
        completion: .file())
    var output: String?

    @Flag(name: .long, help: "Emit JSON — text, timings, tokens and the verbatim transcript.")
    var json = false

    @Flag(name: .long, help: "Record the results in the app's history, as a dictation would be.")
    var saveHistory = false

    @Option(name: .long, help: "Requests in flight per recording when it has to be split.")
    var concurrency: Int = 3

    @Option(name: .long, help: "Attempts per request before giving up.")
    var attempts: Int = 3

    @Flag(name: .long, help: "Only the transcript on stdout. No summary line on stderr.")
    var quiet = false

    // Screen context, so a grounded dictation can be reproduced from the command line — including
    // one pulled straight out of history with `dnt history show <id> --context`.
    @Option(name: .long, help: "Visible screen text to ground spelling on.")
    var visibleText: String?

    @Option(name: .long, help: "Text immediately before the caret.")
    var beforeCaret: String?

    @Option(name: .long, help: "Foreground app name.")
    var app: String?

    @Option(name: .long, help: "Focused window title.")
    var windowTitle: String?

    @Option(
        name: .long, help: "A JSON ScreenContext, as `dnt history show --context` prints.",
        completion: .file())
    var contextFile: String?

    @Flag(
        name: .long,
        help: """
            Transcribe a second time without the screen context and take digits from that run. \
            Costs one extra request; see the substitution numbers in docs/EVALUATION.md.
            """)
    var verifyNumbers = false

    mutating func run() async throws {
        logging.start()

        guard !files.isEmpty else {
            throw ValidationError("Nothing to transcribe. Pass one or more audio files.")
        }
        guard let parsedMode = TranscriptMode(rawValue: mode) else {
            throw ValidationError(
                "Unknown mode '\(mode)'. Options: "
                    + TranscriptMode.acceptedSpellings.joined(separator: ", "))
        }

        let urls = try files.map { path -> URL in
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ValidationError("No such file: \(path)")
            }
            return url
        }

        let kind = try backend.resolveProvider()
        let (service, keySource) = try backend.makeService(kind)
        let secondStage = try makeSecondStage(primary: kind)

        let transcriber = FileTranscriber(
            service: service,
            prompt: try backend.promptBuilder(),
            fidelity: try backend.resolveFidelity(),
            secondStage: secondStage?.service)

        // Checked before a single byte is uploaded. Finding out that a summary is impossible after
        // billing forty minutes of audio is a bad way to learn it.
        guard transcriber.supports(parsedMode) else {
            throw ValidationError(
                """
                \(kind.rawValue) is a speech recognition endpoint: it transcribes audio and cannot \
                do anything with text, so it cannot \
                \(parsedMode.needsSecondPass ? "produce a \(parsedMode.rawValue)" : "run this mode").
                Either transcribe with a model (--provider gemini), or keep the recogniser and add \
                --text-provider gemini for the second stage.
                """)
        }

        let context = try resolveContext()
        let destination = try resolveOutput(count: urls.count)

        if !quiet {
            Out.note(
                "\(kind.rawValue) · \(service.model) · \(parsedMode.rawValue) · key from \(keySource)"
                    + (secondStage.map { " · second stage: \($0.name)" } ?? ""))
            if context != nil {
                Out.note("grounding: screen context supplied on the command line")
            }
        }

        var outcomes: [FileTranscriber.Outcome] = []
        var failures: [(url: URL, message: String)] = []
        // Copied out of `self` because the progress callback is `@Sendable` and this command is a
        // mutating struct — the closure cannot capture it.
        let isQuiet = quiet

        // Sequential on purpose. Concurrency here would interleave failures with output, make the
        // cost of a mistyped glob unbounded, and buy nothing for the common case of one file —
        // `--concurrency` splits a *single long* recording, which is where the wait actually is.
        // Worked out before the first request rather than as each file finishes: a name collision
        // discovered halfway through a batch has already cost the money for the file it would
        // overwrite.
        let names = FileTranscriber.outputNames(for: urls)

        for (index, url) in urls.enumerated() {
            do {
                let outcome = try await transcriber.transcribe(
                    fileAt: url, mode: parsedMode, context: context,
                    verifyNumbers: verifyNumbers, attempts: attempts, maxConcurrent: concurrency,
                    onProgress: { progress in
                        guard !isQuiet else { return }
                        Out.progress(Self.describe(progress, file: url.lastPathComponent))
                    })
                Out.endProgress()
                outcomes.append(outcome)

                if let destination {
                    try write(outcome, to: destination, named: names[index])
                }
                if saveHistory {
                    await store(outcome)
                }
                if !json {
                    emit(outcome, showHeader: urls.count > 1)
                }
            } catch {
                Out.endProgress()
                failures.append((url, error.localizedDescription))

                // The exact error first and uncut, because this is a developer tool and the exact
                // error is what gets pasted into an issue. The advice second, on its own line,
                // because a status code does not say whether to retry or to go and fix something.
                Out.note("✗ \(url.lastPathComponent): \(error.localizedDescription)")
                let advice = FailureAdvice.describe(error)
                if advice.message != error.localizedDescription {
                    Out.note("  → \(advice.message)")
                }
                Log("transcribe").error(
                    "file transcription failed",
                    ["file": url.lastPathComponent, "detail": FailureAdvice.detail(of: error)])
            }
        }

        if json {
            let payload = outcomes.map(JSONOutcome.init)
            let data = try JSONEncoder.cli.encode(payload)
            Out.stdout(String(decoding: data, as: UTF8.self))
        }

        if !quiet, !outcomes.isEmpty {
            Out.note(summary(outcomes))
        }
        // A partial run must not look like a clean one, and a script driving this needs the exit
        // code to say so.
        if !failures.isEmpty { throw ExitCode.failure }
    }

    // MARK: - Second stage

    private func makeSecondStage(
        primary: ProviderKind
    ) throws -> (service: TranscriptionService, name: String)? {
        guard let textProvider else { return nil }
        guard let kind = ProviderKind(rawValue: textProvider.lowercased()) else {
            throw ValidationError(
                "Unknown --text-provider '\(textProvider)'. Options: "
                    + ProviderKind.allCases.map(\.rawValue).joined(separator: ", "))
        }
        // xAI passes this: it is a recogniser whose key also reaches Grok chat models, so the
        // question is whether the backend has a text side, not whether it transcribes.
        guard let (service, _) = try backend.makeTextService(kind, model: textModel) else {
            throw ValidationError(
                "--text-provider \(kind.rawValue) is a speech recognition endpoint with no text "
                    + "input. Choose gemini, openrouter, local or xai.")
        }
        return (service, "\(kind.rawValue)/\(service.model)")
    }

    // MARK: - Context

    private func resolveContext() throws -> ScreenContext? {
        var context: ScreenContext?

        if let contextFile {
            let url = URL(fileURLWithPath: contextFile)
            guard let data = try? Data(contentsOf: url) else {
                throw ValidationError("Could not read \(contextFile)")
            }
            do {
                context = try JSONDecoder().decode(ScreenContext.self, from: data)
            } catch {
                throw ValidationError(
                    "\(contextFile) is not a ScreenContext: \(error.localizedDescription)")
            }
        }

        // Explicit flags win over the file, so one field can be overridden without editing it.
        if visibleText != nil || beforeCaret != nil || app != nil || windowTitle != nil {
            var merged = context ?? ScreenContext()
            merged.visibleText = visibleText ?? merged.visibleText
            merged.textBeforeCaret = beforeCaret ?? merged.textBeforeCaret
            merged.appName = app ?? merged.appName
            merged.windowTitle = windowTitle ?? merged.windowTitle
            context = merged
        }

        guard let context, !context.isEmpty else { return nil }
        return context
    }

    // MARK: - Output

    private enum Destination {
        case directory(URL)
        case file(URL)
    }

    private func resolveOutput(count: Int) throws -> Destination? {
        guard let output else { return nil }
        let url = URL(fileURLWithPath: output)

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        if exists && isDirectory.boolValue { return .directory(url) }
        if output.hasSuffix("/") || count > 1 {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return .directory(url)
        }
        return .file(url)
    }

    private func write(
        _ outcome: FileTranscriber.Outcome, to destination: Destination, named name: String
    ) throws {
        let target: URL
        switch destination {
        case .file(let url): target = url
        case .directory(let directory): target = directory.appendingPathComponent(name)
        }
        try outcome.delivered.write(to: target, atomically: true, encoding: .utf8)
        Out.note("wrote \(target.path)")

        // The verbatim transcript goes next to the derived one rather than being replaced by it.
        guard outcome.mode != .verbatim, outcome.delivered != outcome.verbatim else { return }
        let verbatimURL = target.deletingPathExtension()
            .appendingPathExtension("verbatim.txt")
        try outcome.verbatim.write(to: verbatimURL, atomically: true, encoding: .utf8)
        Out.note("wrote \(verbatimURL.path)")
    }

    private func emit(_ outcome: FileTranscriber.Outcome, showHeader: Bool) {
        if showHeader { Out.stdout("# \(outcome.sourceURL.lastPathComponent)") }
        Out.stdout(outcome.delivered)
        if showHeader { Out.stdout("") }
    }

    private func store(_ outcome: FileTranscriber.Outcome) async {
        let store = HistoryStore(directory: HistoryStore.defaultDirectory())
        // The recording is already on disk where the user put it; copying it into the history
        // would duplicate potentially hours of audio for no gain, and the row records where it
        // came from.
        await store.insert(outcome.historyRecord(), audio: nil)
    }

    private static func describe(_ progress: FileTranscriber.Progress, file: String) -> String {
        switch progress {
        case .decoding: "\(file): decoding…"
        case .transcribing(let done, let total):
            total > 1 ? "\(file): transcribing \(done)/\(total)…" : "\(file): transcribing…"
        case .deriving(let mode): "\(file): \(mode.rawValue)…"
        }
    }

    private func summary(_ outcomes: [FileTranscriber.Outcome]) -> String {
        let seconds = outcomes.reduce(0.0) { $0 + $1.totalSeconds }
        let audio = outcomes.compactMap(\.durationSeconds).reduce(0, +)
        let tokens = outcomes.compactMap { $0.usage.audioTokens }.reduce(0, +)

        var parts = ["\(outcomes.count) file\(outcomes.count == 1 ? "" : "s")"]
        if audio > 0 {
            parts.append("\(PerformanceStats.formatDuration(audio)) of audio")
            parts.append("in \(PerformanceStats.formatDuration(seconds))")
            if seconds > 0 {
                parts.append(String(format: "(%.0f× realtime)", audio / seconds))
            }
        } else {
            parts.append("in \(PerformanceStats.formatDuration(seconds))")
        }
        if tokens > 0 { parts.append("· \(tokens) audio tokens") }
        return parts.joined(separator: " ")
    }
}

/// The `--json` shape. Declared rather than derived from `Outcome` so the field names are a
/// deliberate, stable contract for whatever is parsing them.
private struct JSONOutcome: Encodable {
    let file: String
    let mode: String
    let fidelity: String
    let provider: String
    let model: String
    let secondStageProvider: String?
    let language: String
    let text: String
    let verbatim: String
    let audioSeconds: Double?
    let decodeSeconds: Double
    let transcriptionSeconds: Double
    let secondStageSeconds: Double?
    let chunks: Int
    let promptTokens: Int?
    let completionTokens: Int?
    let audioTokens: Int?

    init(_ outcome: FileTranscriber.Outcome) {
        file = outcome.sourceURL.path
        mode = outcome.mode.rawValue
        fidelity = outcome.fidelity.rawValue
        provider = outcome.provider
        model = outcome.model
        secondStageProvider = outcome.secondStageProvider
        language = outcome.language
        text = outcome.delivered
        verbatim = outcome.verbatim
        audioSeconds = outcome.durationSeconds
        decodeSeconds = outcome.decodeSeconds
        transcriptionSeconds = outcome.transcriptionSeconds
        secondStageSeconds = outcome.secondStageSeconds
        chunks = outcome.chunkCount
        promptTokens = outcome.usage.promptTokens
        completionTokens = outcome.usage.completionTokens
        audioTokens = outcome.usage.audioTokens
    }
}
