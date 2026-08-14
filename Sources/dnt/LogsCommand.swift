import ArgumentParser
import DoNotTypeCore
import Foundation

/// Reads the app's log file.
///
/// This is `tail` with the two things `tail` cannot do here: it knows where the file is, and it
/// understands the level column, so `--level warn` filters rather than making you eyeball it. The
/// file is plain text on purpose — anything this prints, you could have got with `less`.
struct LogsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "logs",
        abstract: "Show what the app logged.",
        discussion: """
            The app writes to ~/Library/Application Support/DoNotType/logs/donottype.log at info \
            level. To record more, set the level in Settings › Logs, or launch it with \
            DNT_LOG_LEVEL=debug.

            The CLI logs to stderr instead, so `dnt logs` never shows this process's own output.
            """)

    @OptionGroup var logging: LoggingOptions

    @Option(name: .shortAndLong, help: "How many lines to show.")
    var lines = 200

    @Option(name: .long, help: "Hide anything below this level: trace, debug, info, warn, error.")
    var level: String?

    @Option(name: .long, help: "Only lines containing this.")
    var grep: String?

    @Flag(name: .shortAndLong, help: "Keep printing as new lines arrive.")
    var follow = false

    @Flag(name: .long, help: "Print the log file path and exit.")
    var path = false

    @Flag(name: .long, help: "Delete the log file and its rotated generation.")
    var clear = false

    /// Where the app writes, which is not where this process writes. See `LogRouter.Configuration`.
    static var appLogURL: URL {
        HistoryStore.defaultDirectory().appendingPathComponent("logs/donottype.log")
    }

    mutating func run() async throws {
        logging.start()
        let url = Self.appLogURL

        if path {
            Out.stdout(url.path)
            return
        }

        if clear {
            let manager = FileManager.default
            for candidate in [url, url.appendingPathExtension("1")] {
                if manager.fileExists(atPath: candidate.path) {
                    try manager.removeItem(at: candidate)
                    Out.note("removed \(candidate.path)")
                }
            }
            return
        }

        guard FileManager.default.fileExists(atPath: url.path) else {
            Out.note(
                """
                No log file yet at \(url.path).
                The app writes one as soon as it runs. For the CLI's own logging use --verbose.
                """)
            throw ExitCode.failure
        }

        let minimum = try resolveLevel()
        let existing = try tail(url, lines: lines, minimum: minimum)
        for line in existing { Out.stdout(line) }

        guard follow else { return }
        try await follow(url, minimum: minimum)
    }

    private func resolveLevel() throws -> LogLevel {
        guard let level else { return .trace }
        guard let parsed = LogLevel(name: level) else {
            throw ValidationError(
                "Unknown level '\(level)'. Options: trace, debug, info, warn, error.")
        }
        return parsed
    }

    /// Reads the whole file rather than seeking backwards.
    ///
    /// The file rotates at 8 MB, so the worst case is a few megabytes of text and a millisecond.
    /// A backwards-seeking tail would be faster and is not worth the off-by-one bugs.
    private func tail(_ url: URL, lines count: Int, minimum: LogLevel) throws -> [String] {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let matching = text.split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { matches($0, minimum: minimum) }
        return count > 0 ? Array(matching.suffix(count)) : matching
    }

    private func matches(_ line: String, minimum: LogLevel) -> Bool {
        if let grep, !grep.isEmpty, !line.localizedCaseInsensitiveContains(grep) { return false }
        guard minimum > .trace else { return true }
        // `12:04:31.512 WARN  fallback  …` — the level is the second column, and a line that does
        // not parse (a wrapped stack trace, say) is kept rather than silently dropped.
        let columns = line.split(separator: " ", omittingEmptySubsequences: true)
        guard columns.count > 1, let parsed = LogLevel(name: String(columns[1])) else { return true }
        return parsed >= minimum
    }

    /// Polls for appended bytes. `DispatchSource` file watching does not fire for every append on
    /// every filesystem, and half a second of latency is invisible to someone watching a log.
    private func follow(_ url: URL, minimum: LogLevel) async throws {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        var offset = (try? handle.seekToEnd()) ?? 0
        var carry = ""

        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(500))

            // A rotation replaces the file underneath us; noticing that it shrank is enough to
            // start again from the top rather than printing nothing forever.
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? UInt64
            if let size, size < offset {
                try? handle.seek(toOffset: 0)
                offset = 0
                carry = ""
            }

            guard let chunk = try? handle.readToEnd(), !chunk.isEmpty else { continue }
            offset += UInt64(chunk.count)
            carry += String(decoding: chunk, as: UTF8.self)

            // Hold back a trailing partial line until its newline arrives.
            var pieces = carry.components(separatedBy: "\n")
            carry = pieces.removeLast()
            for line in pieces where !line.isEmpty && matches(line, minimum: minimum) {
                Out.stdout(line)
            }
        }
    }
}

/// Prints the prompt that will actually be sent.
///
/// "Which prompt am I running?" has three possible answers — the shipped one, an edited copy in
/// Application Support, or one passed with `--prompt` — and until now the only way to tell them
/// apart was to open the app's Prompt tab. This also expands the placeholders, so what it prints is
/// the exact text a request carries rather than the template.
struct PromptCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "prompt",
        abstract: "Show, locate or validate the prompt contract.",
        subcommands: [ShowPrompt.self, PromptPath.self, ValidatePrompt.self],
        defaultSubcommand: ShowPrompt.self)

    struct ShowPrompt: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "show",
            abstract: "The assembled instruction, with placeholders filled in.")

        @OptionGroup var backend: BackendOptions
        @OptionGroup var logging: LoggingOptions

        @Option(name: .long, help: "Which block: system, rewrite or summary.")
        var section = "system"

        @Option(name: .long, help: "Rewrite style, for --section rewrite.")
        var style = RewriteStyle.formal.rawValue

        @Option(name: .long, help: "Summary style, for --section summary.")
        var summary = SummaryStyle.default.rawValue

        mutating func run() throws {
            logging.start()
            let builder = try backend.promptBuilder()

            switch section.lowercased() {
            case "system", "transcribe":
                Out.stdout(
                    try builder.systemInstruction(fidelity: try backend.resolveFidelity()))
            case "rewrite":
                guard let parsed = RewriteStyle(rawValue: style), parsed.isRewrite else {
                    throw ValidationError(
                        "Unknown rewrite style '\(style)'. Options: "
                            + RewriteStyle.allCases.filter(\.isRewrite).map(\.rawValue)
                            .joined(separator: ", "))
                }
                Out.stdout(try builder.rewriteInstruction(style: parsed))
            case "summary":
                guard let parsed = SummaryStyle(rawValue: summary) else {
                    throw ValidationError(
                        "Unknown summary style '\(summary)'. Options: "
                            + SummaryStyle.allCases.map(\.rawValue).joined(separator: ", "))
                }
                Out.stdout(try builder.summaryInstruction(style: parsed))
            default:
                throw ValidationError(
                    "Unknown section '\(section)'. Options: system, rewrite, summary.")
            }
        }
    }

    struct PromptPath: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "path",
            abstract: "Which file is in force, shipped or edited.")

        @OptionGroup var backend: BackendOptions

        mutating func run() throws {
            let store = PromptStore(directory: HistoryStore.defaultDirectory())
            if store.hasCustomPrompt {
                Out.stdout(store.customURL.path)
                Out.note("edited copy — the measured numbers in PROMPT.md's changelog do not apply")
            } else {
                Out.stdout(try backend.promptURL().path)
                Out.note("the shipped contract")
            }
        }
    }

    struct ValidatePrompt: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "validate",
            abstract: "Check that every block and placeholder a request needs resolves.")

        @OptionGroup var backend: BackendOptions

        @Argument(help: "A prompt file to check. Defaults to the one in force.", completion: .file())
        var file: String?

        mutating func run() throws {
            let template: String
            if let file {
                template = try String(contentsOf: URL(fileURLWithPath: file), encoding: .utf8)
            } else {
                template = try PromptStore(directory: HistoryStore.defaultDirectory())
                    .activeTemplate(default: try backend.promptURL())
            }

            // `PromptStore.validate` covers what a *dictation* needs. The optional stages are
            // checked separately and reported rather than thrown: a prompt without a summary block
            // is still a working prompt for everything except summaries, and failing validation
            // over it would be wrong.
            try PromptStore.validate(template)
            Out.stdout("system block      ok (every fidelity resolves)")

            let builder = PromptBuilder(template: template)
            for style in RewriteStyle.allCases where style.isRewrite {
                let ok = (try? builder.rewriteInstruction(style: style)) != nil
                Out.stdout("rewrite:\(style.rawValue.padded(10))\(ok ? "ok" : "MISSING")")
            }
            for style in SummaryStyle.allCases {
                let ok = (try? builder.summaryInstruction(style: style)) != nil
                Out.stdout("summary:\(style.rawValue.padded(10))\(ok ? "ok" : "MISSING")")
            }
        }
    }
}
