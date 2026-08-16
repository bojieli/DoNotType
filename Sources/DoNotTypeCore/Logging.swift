import Foundation

#if canImport(os)
    import os
#endif

/// Structured logging for every surface of this project: the menu-bar app, the `dnt` CLI, the eval
/// harness and the core itself.
///
/// ## Why this exists rather than `os.Logger`
///
/// The app used `os.Logger` directly, which is the right transport on Apple platforms and a bad
/// *interface* for a tool people are expected to debug. Four things were missing and all four came
/// up in practice:
///
/// 1. **A level you can turn up.** `os.Logger` decides what is persisted by a system-wide policy;
///    there was no way for a user to say "record everything for the next ten minutes".
/// 2. **A file.** `log stream --predicate` is not a thing you can ask a bug reporter to run, and
///    the output cannot be attached to an issue. A path you can `tail -f` and drag into a comment
///    is worth more than a better ring buffer.
/// 3. **Anything at all in `DoNotTypeCore`.** Every interesting decision — which grounding route a
///    backend got, whether the hedge fired, why a retry gave up — happens in the core, which had
///    two log lines in the entire target. The app logged that a dictation failed; nothing logged
///    *what the request had been*.
/// 4. **A redaction rule.** Once logging is useful enough to paste into an issue, it has to be safe
///    to paste into an issue. See `Redaction`.
///
/// `os.Logger` is kept as one sink among several, so Console still works and nothing that used to
/// be visible stopped being visible.
///
/// ## The privacy rule
///
/// Transcripts and screen contents are *content*, and content is never logged unless the user turns
/// it on with `DNT_LOG_CONTENT=1`. Everything else — sizes, counts, durations, model IDs, HTTP
/// status codes — is logged freely, because a log that omits them cannot explain a failure and a
/// log that includes the user's words is a second copy of exactly what this app promises to keep
/// under their control. `Log.content` is the one door between the two, and it is closed by default.
public enum LogLevel: Int, Sendable, Codable, CaseIterable, Comparable {
    /// Per-chunk, per-retry, per-request detail. Verbose enough to read a whole dictation from.
    case trace = 0
    /// The decisions: which route, which backend, how big, how long.
    case debug
    /// One line per meaningful event. The default.
    case info
    /// Something degraded but recovered — a fallback fired, an encoder was missing.
    case warning
    /// Something failed and the user noticed.
    case error
    /// Nothing at all.
    case off

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Accepts the spellings people actually type, including `warn` and `silent`.
    public init?(name: String) {
        switch name.trimmed.lowercased() {
        case "trace", "verbose", "v": self = .trace
        case "debug", "d": self = .debug
        case "info", "i", "default": self = .info
        case "warn", "warning", "w": self = .warning
        case "error", "err", "e": self = .error
        case "off", "none", "silent", "quiet": self = .off
        default: return nil
        }
    }

    public var name: String {
        switch self {
        case .trace: "trace"
        case .debug: "debug"
        case .info: "info"
        case .warning: "warn"
        case .error: "error"
        case .off: "off"
        }
    }

    /// Fixed width, so a column of log lines stays a column.
    var padded: String { name.padding(toLength: 5, withPad: " ", startingAt: 0).uppercased() }
}

/// One line in the log.
public struct LogEvent: Sendable, Identifiable {
    public let id: UInt64
    public let timestamp: Date
    public let level: LogLevel
    public let category: String
    public let message: String
    /// Key-value detail, rendered sorted so two runs of the same code produce comparable output.
    public let fields: [String: String]

    public init(
        id: UInt64 = 0, timestamp: Date = Date(), level: LogLevel, category: String,
        message: String, fields: [String: String] = [:]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.message = message
        self.fields = fields
    }

    /// `2026-08-16T12:04:31.512 INFO  dictation  transcribed  chars=142 ms=980`
    ///
    /// The parameter is about the stamp, not about the date within it: `false` omits the time
    /// entirely, and is for the sinks whose transport stamps every line itself — `os.Logger`,
    /// logcat, the Windows event view. Everything that persists or exports a line stamps it here.
    public func render(timestamped: Bool = true) -> String {
        var line = timestamped ? "\(LogClock.stamp(timestamp)) " : ""
        line += "\(level.padded) \(category.padding(toLength: 12, withPad: " ", startingAt: 0)) "
        line += message
        if !fields.isEmpty {
            line += "  " + fields.keys.sorted().map { "\($0)=\(quoted(fields[$0]!))" }
                .joined(separator: " ")
        }
        return line
    }

    /// One JSON object per line, for `jq`. Hand-built rather than `JSONEncoder`ed: the output has
    /// to be a single line whatever the input contains, and a log formatter that can throw is a
    /// log formatter that can lose the line it was asked to write.
    public func renderJSON() -> String {
        var parts = [
            "\"ts\":\(escaped(LogClock.iso8601(timestamp)))",
            "\"level\":\(escaped(level.name))",
            "\"category\":\(escaped(category))",
            "\"message\":\(escaped(message))",
        ]
        if !fields.isEmpty {
            let body = fields.keys.sorted()
                .map { "\(escaped($0)):\(escaped(fields[$0]!))" }
                .joined(separator: ",")
            parts.append("\"fields\":{\(body)}")
        }
        return "{" + parts.joined(separator: ",") + "}"
    }

    /// A field value, kept whole and kept on one line.
    ///
    /// Escaped rather than shortened. A response body belongs in the log in full — it is the thing
    /// somebody is reading the log to see — but a raw newline inside it would split one entry into
    /// several, and every line after the first would have no timestamp, no level and no category.
    /// `dnt logs --grep` would then find a fragment and show it without the message it belongs to.
    private func quoted(_ value: String) -> String {
        let flattened = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return flattened.contains(" ") || flattened.isEmpty ? "\"\(flattened)\"" : flattened
    }

    private func escaped(_ value: String) -> String {
        var out = "\""
        for character in value.unicodeScalars {
            switch character {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if character.value < 0x20 {
                    out += String(format: "\\u%04x", character.value)
                } else {
                    out.unicodeScalars.append(character)
                }
            }
        }
        return out + "\""
    }
}

/// Somewhere a log line goes.
public protocol LogSink: Sendable {
    func write(_ event: LogEvent)
    /// Called before the process exits, for sinks that buffer.
    func flush()
}

extension LogSink {
    public func flush() {}
}

// MARK: - Router

/// The one place a log line passes through: filters by level, redacts, fans out to sinks and keeps
/// the last few thousand events in memory for the in-app viewer.
///
/// A lock rather than an actor, deliberately. Logging has to be callable from synchronous code in
/// the middle of an audio callback or a `defer`, and an actor would make every call site `await`
/// — which in practice means the call site does not log at all.
public final class LogRouter: @unchecked Sendable {
    public static let shared = LogRouter()

    /// How the process wants to log. Built from a per-executable default and then overridden by
    /// the environment, so `DNT_LOG_LEVEL=trace` works on the app, the CLI and the eval harness
    /// without any of them needing to know about it.
    public struct Configuration: Sendable {
        public var level: LogLevel
        /// Where to append. Nil disables file logging.
        public var fileURL: URL?
        public var writesToStandardError: Bool
        /// Also emit through `os.Logger`, so Console and `log stream` keep working.
        public var usesOSLog: Bool
        /// Whether transcripts and screen text may be written. Off unless asked for.
        public var includesContent: Bool
        /// JSON lines instead of the human format, for the file and stderr sinks.
        public var json: Bool
        /// How many events the in-memory buffer keeps for the log viewer.
        public var bufferCapacity: Int
        /// Rotate the file once it passes this, keeping one previous generation.
        public var maximumFileBytes: Int

        public init(
            level: LogLevel = .info,
            fileURL: URL? = nil,
            writesToStandardError: Bool = false,
            usesOSLog: Bool = false,
            includesContent: Bool = false,
            json: Bool = false,
            bufferCapacity: Int = 5_000,
            maximumFileBytes: Int = 8 * 1024 * 1024
        ) {
            self.level = level
            self.fileURL = fileURL
            self.writesToStandardError = writesToStandardError
            self.usesOSLog = usesOSLog
            self.includesContent = includesContent
            self.json = json
            self.bufferCapacity = bufferCapacity
            self.maximumFileBytes = maximumFileBytes
        }

        /// What a windowed app wants: a file it can be asked for, Console for people who already
        /// know how to use it, and nothing on stderr because nobody is reading it.
        public static func app(logDirectory: URL) -> Configuration {
            Configuration(
                level: .info,
                fileURL: logDirectory.appendingPathComponent("donottype.log"),
                writesToStandardError: false,
                usesOSLog: true)
        }

        /// What a command-line tool wants: stderr, so stdout stays a clean transcript that can be
        /// piped, and no file unless one is asked for — two processes appending to the app's log
        /// would interleave and race its rotation.
        public static func commandLine(level: LogLevel = .warning) -> Configuration {
            Configuration(
                level: level, fileURL: nil, writesToStandardError: true, usesOSLog: false)
        }

        /// Environment overrides. Documented in `docs/CLI.md`.
        ///
        /// - `DNT_LOG_LEVEL`: trace, debug, info, warn, error, off
        /// - `DNT_LOG_FILE`: path to append to, or `none` to turn the file off
        /// - `DNT_LOG_STDERR`: 1 or 0
        /// - `DNT_LOG_JSON`: 1 for one JSON object per line
        /// - `DNT_LOG_CONTENT`: 1 to include transcripts and screen text
        public func applyingEnvironment(
            _ environment: [String: String] = ProcessInfo.processInfo.environment
        ) -> Configuration {
            var copy = self
            if let raw = environment["DNT_LOG_LEVEL"], let level = LogLevel(name: raw) {
                copy.level = level
            }
            if let path = environment["DNT_LOG_FILE"]?.trimmed, !path.isEmpty {
                copy.fileURL = ["none", "off", "no", "0"].contains(path.lowercased())
                    ? nil : URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            }
            if let flag = environment["DNT_LOG_STDERR"] { copy.writesToStandardError = flag.isTruthy }
            if let flag = environment["DNT_LOG_JSON"] { copy.json = flag.isTruthy }
            if let flag = environment["DNT_LOG_CONTENT"] { copy.includesContent = flag.isTruthy }
            return copy
        }
    }

    private let lock = NSLock()
    private var level: LogLevel = .info
    private var sinks: [any LogSink] = []
    private var buffer: [LogEvent] = []
    private var capacity = 5_000
    private var nextID: UInt64 = 1
    private var secrets: [String] = []
    private var contentAllowed = false
    private var activeFileURL: URL?

    private init() {}

    /// Installs a configuration, replacing whatever was there. Safe to call more than once; the
    /// last caller wins, which is what a `--log-level` flag parsed after startup needs.
    ///
    /// - Parameter applyingEnvironment: whether `DNT_LOG_*` overrides this configuration. Callers
    ///   that have already merged the environment with their own flags pass `false`, because
    ///   applying it twice would let `DNT_LOG_LEVEL` win over an explicitly typed `--log-level`.
    @discardableResult
    public func bootstrap(
        _ configuration: Configuration, applyingEnvironment: Bool = true
    ) -> Configuration {
        let resolved = applyingEnvironment
            ? configuration.applyingEnvironment() : configuration
        var built: [any LogSink] = []
        if resolved.writesToStandardError {
            built.append(StandardErrorLogSink(json: resolved.json))
        }
        if let url = resolved.fileURL {
            if let sink = FileLogSink(
                url: url, json: resolved.json, maximumBytes: resolved.maximumFileBytes)
            {
                built.append(sink)
            }
        }
        #if canImport(os)
            if resolved.usesOSLog { built.append(OSLogSink()) }
        #endif

        lock.lock()
        level = resolved.level
        sinks = built
        capacity = max(0, resolved.bufferCapacity)
        contentAllowed = resolved.includesContent
        activeFileURL = resolved.fileURL
        if buffer.count > capacity { buffer.removeFirst(buffer.count - capacity) }
        lock.unlock()

        return resolved
    }

    /// Raises or lowers the level without rebuilding the sinks — what the in-app level picker and
    /// `dnt --log-level` both want.
    public func setLevel(_ newLevel: LogLevel) {
        lock.lock()
        level = newLevel
        lock.unlock()
    }

    public var currentLevel: LogLevel {
        lock.lock()
        defer { lock.unlock() }
        return level
    }

    public var includesContent: Bool {
        lock.lock()
        defer { lock.unlock() }
        return contentAllowed
    }

    public func setIncludesContent(_ allowed: Bool) {
        lock.lock()
        contentAllowed = allowed
        lock.unlock()
    }

    /// The file being appended to, for the UI's "Reveal" button and `dnt logs --path`.
    public var fileURL: URL? {
        lock.lock()
        defer { lock.unlock() }
        return activeFileURL
    }

    /// Registers a value that must never appear in a log line, whatever route it takes there.
    ///
    /// Pattern matching alone is not enough — a key pasted into a custom base URL, or echoed back
    /// inside a provider's error body, does not look like a key by the time it reaches here. The
    /// app registers every resolved key at startup, so the exact bytes are known.
    public func redact(secret: String) {
        let trimmed = secret.trimmed
        guard trimmed.count >= 8 else { return }  // too short to be a key, long enough to be a word
        lock.lock()
        if !secrets.contains(trimmed) { secrets.append(trimmed) }
        lock.unlock()
    }

    public func isEnabled(_ candidate: LogLevel) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return candidate >= level && level != .off
    }

    public func emit(
        level candidate: LogLevel, category: String, message: String,
        fields: [String: String] = [:]
    ) {
        lock.lock()
        guard candidate >= level, level != .off else {
            lock.unlock()
            return
        }
        let knownSecrets = secrets
        let event = LogEvent(
            id: nextID, timestamp: Date(), level: candidate, category: category,
            message: Redaction.scrub(message, secrets: knownSecrets),
            fields: fields.mapValues { Redaction.scrub($0, secrets: knownSecrets) })
        nextID += 1
        if capacity > 0 {
            buffer.append(event)
            if buffer.count > capacity { buffer.removeFirst(buffer.count - capacity) }
        }
        let targets = sinks
        lock.unlock()

        for sink in targets { sink.write(event) }
    }

    // MARK: - The in-memory buffer, for the log viewer

    /// Newest last, filtered. The window polls this; it is a copy, so the UI never holds the lock.
    public func recent(
        limit: Int = 500, minimumLevel: LogLevel = .trace, containing needle: String = ""
    ) -> [LogEvent] {
        lock.lock()
        let snapshot = buffer
        lock.unlock()

        let search = needle.trimmed.lowercased()
        let matches = snapshot.filter { event in
            guard event.level >= minimumLevel else { return false }
            guard !search.isEmpty else { return true }
            if event.message.lowercased().contains(search) { return true }
            if event.category.lowercased().contains(search) { return true }
            return event.fields.contains { key, value in
                key.lowercased().contains(search) || value.lowercased().contains(search)
            }
        }
        return matches.suffix(limit)
    }

    /// Monotonic count of everything emitted since launch. The viewer polls this to decide whether
    /// anything changed, which is cheaper than diffing the buffer.
    public var emittedCount: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return nextID - 1
    }

    public func clearBuffer() {
        lock.lock()
        buffer.removeAll()
        lock.unlock()
    }

    public func flush() {
        lock.lock()
        let targets = sinks
        lock.unlock()
        for sink in targets { sink.flush() }
    }

    /// Test seam: swap the sinks for one that records, without touching the file or Console.
    public func install(sinks replacement: [any LogSink], level newLevel: LogLevel = .trace) {
        lock.lock()
        sinks = replacement
        level = newLevel
        activeFileURL = nil
        lock.unlock()
    }
}

// MARK: - Call site

/// A category handle. Held as a `let` on the type that logs, exactly like `os.Logger` was.
///
/// ```swift
/// private let log = Log("dictation")
/// log.info("transcribed", ["chars": "\(text.count)", "ms": "\(elapsed)"])
/// ```
///
/// The message is an `@autoclosure` so that building it costs nothing when the level is off — the
/// interpolated string is never constructed, which is what makes it reasonable to leave `trace`
/// calls in hot paths permanently.
public struct Log: Sendable {
    public let category: String

    public init(_ category: String) {
        self.category = category
    }

    public func trace(_ message: @autoclosure () -> String, _ fields: [String: String] = [:]) {
        write(.trace, message(), fields)
    }

    public func debug(_ message: @autoclosure () -> String, _ fields: [String: String] = [:]) {
        write(.debug, message(), fields)
    }

    public func info(_ message: @autoclosure () -> String, _ fields: [String: String] = [:]) {
        write(.info, message(), fields)
    }

    public func warning(_ message: @autoclosure () -> String, _ fields: [String: String] = [:]) {
        write(.warning, message(), fields)
    }

    public func error(_ message: @autoclosure () -> String, _ fields: [String: String] = [:]) {
        write(.error, message(), fields)
    }

    /// The user's words, or their screen. Logged only when `DNT_LOG_CONTENT=1`.
    ///
    /// The event is still emitted without it — with the size and nothing else — because knowing a
    /// 412-character transcript came back is most of what debugging needs, and the times it is not
    /// are exactly the times someone should have to opt in.
    public func content(
        _ message: String, _ text: @autoclosure () -> String, level: LogLevel = .debug
    ) {
        guard LogRouter.shared.isEnabled(level) else { return }
        let value = text()
        var fields = ["chars": String(value.count)]
        if LogRouter.shared.includesContent { fields["text"] = value }
        LogRouter.shared.emit(level: level, category: category, message: message, fields: fields)
    }

    private func write(_ level: LogLevel, _ message: @autoclosure () -> String, _ fields: [String: String]) {
        guard LogRouter.shared.isEnabled(level) else { return }
        LogRouter.shared.emit(
            level: level, category: category, message: message(), fields: fields)
    }
}

// MARK: - Sinks

/// Appends to a file, rotating once it gets big.
///
/// Rotation keeps exactly one previous generation. Two is not obviously better and "the log ate the
/// disk" is a real way for a background app to ruin someone's day.
public final class FileLogSink: LogSink, @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL
    private let json: Bool
    private let maximumBytes: Int
    private var handle: FileHandle?
    private var written: Int = 0

    public init?(url: URL, json: Bool = false, maximumBytes: Int = 8 * 1024 * 1024) {
        self.url = url
        self.json = json
        self.maximumBytes = maximumBytes

        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let opened = Self.openForAppending(url) else { return nil }
        handle = opened
        written = (try? opened.offset()).map(Int.init) ?? 0
    }

    /// Opens in append mode, which is a correctness requirement rather than a convenience.
    ///
    /// `FileHandle(forWritingTo:)` writes at its own offset. Two processes with the same file open
    /// — `DNT_LOG_FILE` pointing at the app's log, or simply two `dnt` invocations at once — each
    /// hold their own idea of the end and overwrite each other's lines. With `O_APPEND` the kernel
    /// positions every write at the real end, and a write this size lands whole, so the worst case
    /// is interleaved lines rather than lost ones.
    private static func openForAppending(_ url: URL) -> FileHandle? {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard descriptor >= 0 else { return nil }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    deinit { try? handle?.close() }

    public func write(_ event: LogEvent) {
        let line = (json ? event.renderJSON() : event.render()) + "\n"
        guard let data = line.data(using: .utf8) else { return }

        lock.lock()
        defer { lock.unlock() }

        // A rotation that could not reopen the file left this nil. Try again rather than staying
        // silently dead for the rest of the process: a full disk that empties, or a directory
        // somebody deleted and recreated, should not cost every later line.
        if handle == nil {
            handle = Self.openForAppending(url)
            written = (try? handle?.offset()).map(Int.init) ?? 0
        }
        guard let handle else { return }

        try? handle.write(contentsOf: data)
        written += data.count
        if written > maximumBytes { rotate() }
    }

    public func flush() {
        lock.lock()
        try? handle?.synchronize()
        lock.unlock()
    }

    /// Caller holds the lock.
    private func rotate() {
        let manager = FileManager.default
        let previous = url.appendingPathExtension("1")
        try? handle?.close()
        handle = nil
        try? manager.removeItem(at: previous)
        try? manager.moveItem(at: url, to: previous)
        guard let reopened = Self.openForAppending(url) else { return }
        handle = reopened
        written = 0
    }
}

/// stderr, so stdout stays a clean transcript that can be piped into a file.
public final class StandardErrorLogSink: LogSink, @unchecked Sendable {
    private let lock = NSLock()
    private let json: Bool
    /// Off by default, and this is the sink where that is right: `dnt --verbose` prints to a
    /// terminal the reader is watching, where the wall clock is already on screen and a stamp in
    /// front of every line is column noise. The name used to say `includesDate` while controlling
    /// the whole stamp, so the comment here described a time-only line that was never printed.
    private let timestamped: Bool

    public init(json: Bool = false, timestamped: Bool = false) {
        self.json = json
        self.timestamped = timestamped
    }

    public func write(_ event: LogEvent) {
        let line = (json ? event.renderJSON() : event.render(timestamped: timestamped)) + "\n"
        guard let data = line.data(using: .utf8) else { return }
        lock.lock()
        FileHandle.standardError.write(data)
        lock.unlock()
    }
}

/// Collects events in memory. For tests, and for anything that wants the log without a file.
public final class MemoryLogSink: LogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [LogEvent] = []

    public init() {}

    public func write(_ event: LogEvent) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }

    public var events: [LogEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

#if canImport(os)
    /// Keeps Console, `log stream` and everything anyone already knows how to do working.
    public final class OSLogSink: LogSink, @unchecked Sendable {
        private let lock = NSLock()
        private var loggers: [String: Logger] = [:]
        private let subsystem: String

        public init(subsystem: String = "app.donottype") {
            self.subsystem = subsystem
        }

        public func write(_ event: LogEvent) {
            let logger = self.logger(for: event.category)
            // Already scrubbed by the router, so `.public` is what makes the line readable in
            // Console instead of `<private>`.
            let line = event.render(timestamped: false)
            switch event.level {
            case .trace: logger.debug("\(line, privacy: .public)")
            case .debug: logger.debug("\(line, privacy: .public)")
            case .info: logger.info("\(line, privacy: .public)")
            case .warning: logger.warning("\(line, privacy: .public)")
            case .error: logger.error("\(line, privacy: .public)")
            case .off: break
            }
        }

        private func logger(for category: String) -> Logger {
            lock.lock()
            defer { lock.unlock() }
            if let existing = loggers[category] { return existing }
            let made = Logger(subsystem: subsystem, category: category)
            loggers[category] = made
            return made
        }
    }
#endif

// MARK: - Redaction

/// Keeps secrets out of a log that exists to be pasted into an issue.
///
/// Two mechanisms, because either alone leaks. Registered secrets catch the key the app is actually
/// using wherever it turns up — including inside a URL, a header dump or a provider's own error
/// message echoing it back. Pattern matching catches the key belonging to *another* process,
/// service or copy-paste that this one was never told about.
public enum Redaction {
    /// Prefixes that mean "the rest of this token is a credential", regardless of length.
    ///
    /// `Bearer` is deliberately not here: it is separated from its token by a space, so the token
    /// is scanned on its own merits and a prefix entry would never match anything.
    static let secretPrefixes = ["sk-", "sk_", "AIza", "xai-", "gsk_", "dg_", "pk_", "ghp_"]
    /// A run of opaque token characters this long is not a word in any language.
    static let opaqueTokenLength = 32

    public static func scrub(_ text: String, secrets: [String]) -> String {
        var result = text
        // Longest first, so a key that contains another registered value still masks fully.
        for secret in secrets.sorted(by: { $0.count > $1.count }) where !secret.isEmpty {
            result = result.replacingOccurrences(of: secret, with: mask(secret))
        }
        return scrubPatterns(result)
    }

    /// `sha256`-free on purpose: the point is to say "a 39-character secret was here", not to let
    /// anyone confirm which one by grinding a hash.
    public static func mask(_ secret: String) -> String {
        "‹redacted \(secret.count)-char secret›"
    }

    /// Walks token runs and masks anything that looks like a credential.
    ///
    /// Hand-rolled rather than a regular expression so the behaviour is obvious from reading it and
    /// the same code runs everywhere — this is called on every log line and has to be boring.
    static func scrubPatterns(_ text: String) -> String {
        var output = ""
        var token = ""

        func isTokenCharacter(_ character: Character) -> Bool {
            character.isLetter || character.isNumber || character == "-" || character == "_"
                || character == "."
        }

        func flush() {
            output += looksSecret(token) ? "‹redacted›" : token
            token = ""
        }

        for character in text {
            if isTokenCharacter(character) {
                token.append(character)
            } else {
                flush()
                output.append(character)
            }
        }
        flush()
        return output
    }

    static func looksSecret(_ token: String) -> Bool {
        guard token.count >= 12 else { return false }
        if secretPrefixes.contains(where: { token.hasPrefix($0) && token.count > $0.count + 6 }) {
            return true
        }
        guard token.count >= opaqueTokenLength else { return false }
        // Opaque means no separators and both cases or digits present — enough to exclude a long
        // identifier from a stack trace and include a base64-ish key.
        let hasDigit = token.contains { $0.isNumber }
        let hasLetter = token.contains { $0.isLetter }
        let hasSeparator = token.contains { $0 == "." || $0 == "-" || $0 == "_" }
        return hasDigit && hasLetter && !hasSeparator
    }
}

// MARK: - Formatting helpers

public enum LogClock {
    /// Milliseconds, as a log field. Rounded — nobody debugged anything with the fourth decimal.
    public static func ms(_ seconds: Double) -> String {
        String(Int((seconds * 1000).rounded()))
    }

    /// `2026-08-16T12:04:31.512`. Local time, because the reader is looking at their own clock.
    ///
    /// The date is here because the log file rotates on **size** — 8 MB and one generation — not
    /// on the day. A menu-bar app that runs for a fortnight therefore writes a file whose lines
    /// were time-of-day only, and "12:04:31.512" cannot tell you which of those fourteen days it
    /// happened on. That is the one question a log is read to answer.
    ///
    /// One token rather than `2026-08-16 12:04:31.512`, and that is load-bearing: `dnt logs
    /// --level warn` finds the level by splitting the line on spaces and taking the second column.
    /// A stamp containing a space would shift every column, and the parser keeps lines it cannot
    /// read, so the filter would have quietly stopped filtering instead of failing.
    static func stamp(_ date: Date) -> String {
        let seconds = date.timeIntervalSince1970
        let milliseconds = Int((seconds - seconds.rounded(.down)) * 1000)
        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d.%03d", components.year ?? 0,
            components.month ?? 0, components.day ?? 0, components.hour ?? 0,
            components.minute ?? 0, components.second ?? 0, milliseconds)
    }

    static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

extension String {
    /// `1`, `true`, `yes`, `on` — the spellings people expect an environment flag to accept.
    var isTruthy: Bool {
        ["1", "true", "yes", "on"].contains(trimmed.lowercased())
    }
}
