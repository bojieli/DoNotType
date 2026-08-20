import ArgumentParser
import DoNotTypeCore
import Foundation

/// Lists the backends and what each one can actually do here.
///
/// The capability column is the point. Three of these six are not language models, which decides
/// whether screen grounding and the fidelity ladder work at all — and one of those three still
/// rewrites, on a second endpoint behind the same key. None of that is visible from the name.
struct Providers: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "providers",
        abstract: "Which backends exist, which have a key, and what each can do.")

    @OptionGroup var logging: LoggingOptions

    @Flag(name: .long, help: "Emit JSON.")
    var json = false

    @Flag(inversion: .prefixedNo, help: "Look in the login Keychain for keys.")
    var keychain = true

    mutating func run() throws {
        logging.start()

        let rows = ProviderKind.allCases.map { kind -> Row in
            let resolution = APIKeyResolver.resolve(kind, allowsKeychain: keychain)
            return Row(
                name: kind.rawValue,
                isDefault: kind == AppPreferences.provider,
                model: AppPreferences.model(for: kind),
                envVar: kind.apiKeyEnvVar,
                keySource: resolution?.source,
                capability: Self.capability(of: kind))
        }

        if json {
            Out.stdout(String(decoding: try JSONEncoder.cli.encode(rows), as: UTF8.self))
            return
        }

        Out.stdout(
            "   backend      key                          model                     capability")
        for row in rows {
            let marker = row.isDefault ? " → " : "   "
            Out.stdout(
                marker + row.name.padded(12) + (row.keySource ?? "— not set").padded(29)
                    + row.model.padded(26) + row.capability)
        }
        Out.stdout("")
        Out.stdout(
            AppPreferences.isAvailable
                ? "→ marks the backend the app is set to. Override with --provider."
                : "No stored preferences found, so → is the fresh-install default.")
        Out.stdout(
            "A recognition backend cannot rewrite or summarise on its own; pair one with "
                + "--text-provider, unless its own key reaches a chat model.")
    }

    /// Three answers, not two: a backend can be unable to read the screen and still able to
    /// rewrite, which is what xAI is — recognition on one endpoint, Grok chat on another.
    private static func capability(of kind: ProviderKind) -> String {
        switch (kind.isSpeechRecognition, kind.supportsTextGeneration) {
        case (false, _): "model — grounding, rewrite, summary"
        case (true, true): "transcription, rewrite, summary — no grounding"
        case (true, false): "transcription only"
        }
    }

    struct Row: Encodable {
        let name: String
        let isDefault: Bool
        let model: String
        let envVar: String
        let keySource: String?
        let capability: String
    }
}

/// Answers "why is this not working" without opening the app or reading the source.
///
/// The same information the app's diagnostics report carries, from a shell, before anything has
/// been recorded — plus the two things only a CLI can check: whether this process can see the key,
/// and whether the prompt it would send is the one the user thinks it is.
struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Check keys, prompt, history, audio support and connectivity.")

    @OptionGroup var backend: BackendOptions
    @OptionGroup var logging: LoggingOptions

    @Flag(name: .long, help: "Also make one live request per configured backend. Costs money.")
    var probe = false

    mutating func run() async throws {
        logging.start()

        var problems: [String] = []
        func section(_ title: String) { Out.stdout("\n\(title)") }
        func row(_ name: String, _ value: String) {
            Out.stdout("  \(name.padded(22))\(value)")
        }
        func bad(_ name: String, _ value: String) {
            row(name, value)
            problems.append("\(name): \(value)")
        }

        Out.stdout("DoNotType — \(Dnt.configuration.version)")

        section("Environment")
        row("macOS", ProcessInfo.processInfo.operatingSystemVersionString)
        row("opus encoder", OpusEncoder.isAvailable ? "available" : "UNAVAILABLE — uploads as WAV")
        row(
            "app settings",
            AppPreferences.isAvailable
                ? "found (\(AppPreferences.domain))"
                : "none stored — using fresh-install defaults")

        section("Logging")
        row("level", LogRouter.shared.currentLevel.name)
        row("file", LogRouter.shared.fileURL?.path ?? "none for this process")
        let appLog = HistoryStore.defaultDirectory().appendingPathComponent("logs/donottype.log")
        row(
            "app log",
            FileManager.default.fileExists(atPath: appLog.path)
                ? "\(appLog.path) (\(byteCount(of: appLog)))" : "not written yet")
        row("content logging", LogRouter.shared.includesContent ? "ON — transcripts are logged" : "off")

        section("Prompt")
        let store = PromptStore(directory: HistoryStore.defaultDirectory())
        if let url = try? backend.promptURL() {
            row("shipped", url.path)
            do {
                let builder = try backend.promptBuilder()
                _ = try builder.systemInstruction(fidelity: try backend.resolveFidelity())
                row("system block", "ok")
                row(
                    "summary block",
                    (try? builder.summaryInstruction(style: .brief)) != nil
                        ? "ok" : "MISSING — summaries will fail")
            } catch {
                bad("prompt", error.localizedDescription)
            }
        } else {
            bad("prompt", "the prompt/ directory was not found — pass --prompt or run from a checkout")
        }
        row(
            "edited parts",
            store.hasCustomPrompt
                ? "\(store.customParts.map(\.id).joined(separator: ", ")) — in \(store.promptDirectory.path)"
                : "none — all shipped")

        section("History")
        let history = HistoryStore(directory: HistoryStore.defaultDirectory())
        let records = await history.all()
        row("directory", HistoryStore.defaultDirectory().path)
        row("records", "\(records.count)")
        row("needing retry", "\(records.count(where: \.canRetry))")
        row(
            "audio kept",
            ByteCountFormatter.string(fromByteCount: await history.audioBytes(), countStyle: .file))
        if !records.isEmpty {
            let stats = PerformanceStats.compute(from: records)
            row("median wait", PerformanceStats.formatDuration(stats.medianLatency))
            row("p95 wait", PerformanceStats.formatDuration(stats.p95Latency))
        }

        section("Backends")
        for kind in ProviderKind.allCases {
            let resolution = APIKeyResolver.resolve(kind, allowsKeychain: backend.keychain)
            let marker = kind == (try? backend.resolveProvider()) ? "→ " : "  "
            let key = resolution.map { "key from \($0.source)" } ?? "no key (\(kind.apiKeyEnvVar))"
            row("\(marker)\(kind.rawValue)", "\(key) · \(AppPreferences.model(for: kind))")
        }

        if probe {
            section("Live check")
            let selected = try backend.resolveProvider()
            let (service, _) = try backend.makeService(selected)
            Out.note("probing \(selected.rawValue)…")
            switch await ProviderProbe.check(service.provider, model: service.model) {
            case .accepted: row(selected.rawValue, "✓ accepted")
            case .rejected(let message): bad(selected.rawValue, "✗ \(message)")
            case .inconclusive(let message): row(selected.rawValue, "? \(message)")
            }
        } else {
            Out.stdout("\n(--probe makes one real request to check the key end to end.)")
        }

        Out.stdout("")
        if problems.isEmpty {
            Out.stdout("No problems found.")
        } else {
            Out.stdout("\(problems.count) problem\(problems.count == 1 ? "" : "s") found:")
            for problem in problems { Out.stdout("  • \(problem)") }
            throw ExitCode.failure
        }
    }

    private func byteCount(of url: URL) -> String {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int64
        return ByteCountFormatter.string(fromByteCount: size ?? 0, countStyle: .file)
    }
}

extension String {
    /// Left-aligned in a fixed column. Truncated rather than allowed to break the table, which is
    /// what a model ID long enough to matter would do.
    func padded(_ width: Int) -> String {
        count >= width
            ? String(prefix(max(0, width - 2))) + "… " : padding(toLength: width, withPad: " ", startingAt: 0)
    }
}
