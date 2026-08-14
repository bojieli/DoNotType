import ArgumentParser
import DoNotTypeCore
import Foundation

/// Reads and repairs the history the app writes.
///
/// The history is already a plain JSON file by design — "deleting your history should be something
/// you can verify with `ls`". This gives it the operations that were previously only reachable
/// through a window: search it, print one entry in full, retry what failed, prune what should not
/// have been kept.
struct HistoryCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "history",
        abstract: "List, inspect, retry and prune stored transcripts.",
        subcommands: [List.self, Show.self, Retry.self, Delete.self, Prune.self, Path.self],
        defaultSubcommand: List.self)

    // MARK: - list

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Recent transcripts, newest first.")

        @OptionGroup var logging: LoggingOptions

        @Option(name: .long, help: "How many to show. 0 for everything.")
        var limit = 20

        @Option(name: .long, help: "Substring to match in the text, error or app name.")
        var query: String?

        @Option(name: .long, help: "completed, failed, pending or all.")
        var status = "all"

        @Flag(name: .long, help: "Only transcripts made from files rather than the microphone.")
        var filesOnly = false

        @Flag(name: .long, help: "Emit JSON.")
        var json = false

        mutating func run() async throws {
            logging.start()
            let store = HistoryStore(directory: HistoryStore.defaultDirectory())
            var records = await store.all()

            if let query, !query.isEmpty {
                var filter = HistoryQuery()
                filter.text = query
                records = filter.apply(to: records)
            }
            if status != "all" {
                guard let wanted = DictationRecord.Status(rawValue: status) else {
                    throw ValidationError(
                        "Unknown status '\(status)'. Options: completed, failed, pending, all.")
                }
                records = records.filter { $0.status == wanted }
            }
            if filesOnly { records = records.filter(\.isFromFile) }

            let total = records.count
            if limit > 0 { records = Array(records.prefix(limit)) }

            if json {
                Out.stdout(String(decoding: try JSONEncoder.cli.encode(records), as: UTF8.self))
                return
            }

            guard !records.isEmpty else {
                Out.stdout("Nothing in history matches.")
                return
            }

            for record in records {
                let when = record.createdAt.formatted(
                    .dateTime.month(.abbreviated).day().hour().minute())
                let marker: String
                switch record.status {
                case .completed: marker = "✓"
                case .failed: marker = "✗"
                case .pending: marker = "…"
                }
                var tags = [record.resolvedMode.rawValue]
                if let source = record.sourceFileName { tags.append(source) }
                if let app = record.appName { tags.append(app) }
                if record.retryCount > 0 { tags.append("retried \(record.retryCount)×") }

                Out.stdout(
                    "\(marker) \(String(record.id.uuidString.prefix(8)))  \(when)  "
                        + "[\(tags.joined(separator: " · "))]")
                Out.stdout("    " + oneLine(record.summary, limit: 100))
            }

            // No silent caps: a list that stopped at 20 must say that 341 exist.
            if limit > 0, total > records.count {
                Out.stdout("\nShowing \(records.count) of \(total). Pass --limit 0 for all.")
            }
        }

        private func oneLine(_ text: String, limit: Int) -> String {
            let flat = text.replacingOccurrences(of: "\n", with: " ")
            return flat.count > limit ? String(flat.prefix(limit - 1)) + "…" : flat
        }
    }

    // MARK: - show

    struct Show: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "One entry in full, including what was sent as screen context.")

        @OptionGroup var logging: LoggingOptions

        @Argument(help: "Record ID, or enough of the start of one to be unambiguous.")
        var id: String

        @Flag(name: .long, help: "Emit JSON.")
        var json = false

        @Flag(
            name: .long,
            help: "Print only the screen context, ready for `dnt transcribe --context-file`.")
        var context = false

        mutating func run() async throws {
            logging.start()
            let store = HistoryStore(directory: HistoryStore.defaultDirectory())
            let matches = await store.all().filter {
                $0.id.uuidString.lowercased().hasPrefix(id.lowercased())
            }
            guard let record = matches.first else {
                throw ValidationError("No history entry starts with '\(id)'.")
            }
            guard matches.count == 1 else {
                throw ValidationError(
                    "'\(id)' matches \(matches.count) entries. Use more of the ID.")
            }

            if context {
                guard let screen = record.context else {
                    throw ValidationError("That entry has no stored screen context.")
                }
                Out.stdout(String(decoding: try JSONEncoder.cli.encode(screen), as: UTF8.self))
                return
            }
            if json {
                Out.stdout(String(decoding: try JSONEncoder.cli.encode(record), as: UTF8.self))
                return
            }

            Out.stdout("id         \(record.id.uuidString)")
            Out.stdout("when       \(record.createdAt.ISO8601Format())")
            Out.stdout("status     \(record.status.rawValue)")
            Out.stdout("mode       \(record.resolvedMode.rawValue)")
            Out.stdout("backend    \(record.provider) · \(record.model) · \(record.fidelity.rawValue)")
            if let source = record.sourceFileName { Out.stdout("source     \(source)") }
            if let app = record.appName { Out.stdout("app        \(app)") }
            if let latency = record.latencySeconds {
                Out.stdout("wait       \(PerformanceStats.formatDuration(latency))")
            }
            if let usage = record.usage, let audio = usage.audioTokens {
                Out.stdout("audioTok   \(audio)")
            }
            if let error = record.errorMessage { Out.stdout("error      \(error)") }
            Out.stdout("audio      \(record.audioFileName ?? "not kept")")
            Out.stdout("context    \(record.context == nil ? "none" : "stored — see --context")")

            Out.stdout("\n--- verbatim ---")
            Out.stdout(record.text)
            if let styled = record.styledText {
                Out.stdout("\n--- \(record.resolvedMode.rawValue) ---")
                Out.stdout(styled)
            }
        }
    }

    // MARK: - retry

    struct Retry: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Re-send dictations that failed, using their stored audio and context.")

        @OptionGroup var backend: BackendOptions
        @OptionGroup var logging: LoggingOptions

        @Argument(help: "Record ID prefix. Omit with --all.")
        var id: String?

        @Flag(name: .long, help: "Retry everything that can be retried.")
        var all = false

        mutating func run() async throws {
            logging.start()
            let store = HistoryStore(directory: HistoryStore.defaultDirectory())
            let kind = try backend.resolveProvider()
            let (service, _) = try backend.makeService(kind)
            let coordinator = RetryCoordinator(service: service, store: store)

            let pending = await store.retryable()
            guard !pending.isEmpty else {
                Out.note("Nothing to retry.")
                return
            }

            let targets: [DictationRecord]
            if all {
                targets = pending
            } else if let id {
                targets = pending.filter {
                    $0.id.uuidString.lowercased().hasPrefix(id.lowercased())
                }
                guard !targets.isEmpty else {
                    throw ValidationError("No retryable entry starts with '\(id)'.")
                }
            } else {
                throw ValidationError(
                    "Pass a record ID or --all. \(pending.count) entries can be retried.")
            }

            var succeeded = 0
            for record in targets {
                switch await coordinator.retry(record) {
                case .success(let text):
                    succeeded += 1
                    Out.note("✓ \(String(record.id.uuidString.prefix(8)))")
                    Out.stdout(text)
                case .failure(let error):
                    Out.note(
                        "✗ \(String(record.id.uuidString.prefix(8))): \(error.localizedDescription)")
                }
            }
            Out.note("\(succeeded)/\(targets.count) succeeded")
            if succeeded < targets.count { throw ExitCode.failure }
        }
    }

    // MARK: - delete

    /// One entry, by ID. `prune` handles the sweeping cases and cannot express this one, which is
    /// the one you want after transcribing something you did not mean to keep.
    struct Delete: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Delete a single entry and its audio.")

        @OptionGroup var logging: LoggingOptions

        @Argument(help: "Record ID, or enough of the start of one to be unambiguous.")
        var id: String

        mutating func run() async throws {
            logging.start()
            let store = HistoryStore(directory: HistoryStore.defaultDirectory())
            let matches = await store.all().filter {
                $0.id.uuidString.lowercased().hasPrefix(id.lowercased())
            }
            guard let record = matches.first else {
                throw ValidationError("No history entry starts with '\(id)'.")
            }
            guard matches.count == 1 else {
                throw ValidationError("'\(id)' matches \(matches.count) entries. Use more of the ID.")
            }
            await store.delete(id: record.id)
            Out.note("Deleted \(record.id.uuidString).")
        }
    }

    // MARK: - prune

    struct Prune: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Delete stored transcripts and their audio.")

        @OptionGroup var logging: LoggingOptions

        @Option(name: .long, help: "Delete entries older than this many days.")
        var olderThan: Int?

        @Flag(name: .long, help: "Delete everything.")
        var all = false

        @Flag(name: .long, help: "Say what would be deleted without deleting it.")
        var dryRun = false

        mutating func run() async throws {
            logging.start()
            guard all || olderThan != nil else {
                throw ValidationError("Pass --all or --older-than <days>.")
            }
            let store = HistoryStore(directory: HistoryStore.defaultDirectory())
            let records = await store.all()

            let doomed: [DictationRecord]
            if all {
                doomed = records
            } else {
                let cutoff = Date().addingTimeInterval(-Double(olderThan ?? 0) * 86_400)
                doomed = records.filter { $0.createdAt < cutoff }
            }

            guard !doomed.isEmpty else {
                Out.note("Nothing to delete.")
                return
            }
            if dryRun {
                Out.note("Would delete \(doomed.count) of \(records.count) entries.")
                return
            }
            for record in doomed { await store.delete(id: record.id) }
            Out.note("Deleted \(doomed.count) entries.")
        }
    }

    // MARK: - path

    struct Path: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Where the history, audio and logs are on disk.")

        mutating func run() throws {
            let directory = HistoryStore.defaultDirectory()
            Out.stdout(directory.path)
            Out.note("  history.json, audio/, logs/, and PROMPT.md if you have edited one")
        }
    }
}
