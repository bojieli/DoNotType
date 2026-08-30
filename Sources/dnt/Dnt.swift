import ArgumentParser
import DoNotTypeCore
import Foundation

/// The developer-facing command line.
///
/// ## Why this exists alongside `dnt-eval`
///
/// `dnt-eval` measures the prompt: it runs cases, scores them and prints tables. It is a research
/// harness and every one of its commands is shaped around comparing two conditions.
///
/// This is the other half — the tool for *using* the thing. Transcribe a file. See which key is
/// found and where. Read the log. Search the history the app wrote. Print the prompt that will
/// actually be sent. None of that was reachable without opening the app, and an app you have to
/// open to answer a question is a bad answer to a question.
///
/// Two rules shape the output:
///
/// **stdout is the transcript.** Every diagnostic, progress line and summary goes to stderr, so
/// `dnt transcribe memo.m4a > memo.txt` produces a file with nothing in it but words.
///
/// **Nothing prints a secret.** Keys are reported by source and length, never by value, and the
/// logger scrubs anything key-shaped that reaches it by another route.
@main
struct Dnt: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dnt",
        abstract: "Transcribe recordings, and inspect what DoNotType is doing.",
        discussion: """
            Transcribe a file with the backend the app is configured with:

              dnt transcribe meeting.m4a
              dnt transcribe memo.wav --mode summary:bullets
              dnt transcribe *.m4a --output transcripts/ --save-history

            Find out why something is not working:

              dnt doctor --probe
              dnt logs --follow --level debug
            """,
        version: "dnt 0.4.0 (9a795fc, 2026-08-28)",
        subcommands: [
            Transcribe.self, Providers.self, Doctor.self, HistoryCommand.self, LogsCommand.self,
            PromptCommand.self,
        ],
        defaultSubcommand: Transcribe.self)
}

// MARK: - Logging

/// Flags every subcommand takes, so `--log-level` works wherever someone types it.
struct LoggingOptions: ParsableArguments {
    @Flag(name: .shortAndLong, help: "Log what is happening, to stderr. Same as --log-level debug.")
    var verbose = false

    @Option(
        name: .long,
        help: "trace, debug, info, warn, error or off. Overrides --verbose and DNT_LOG_LEVEL.")
    var logLevel: String?

    @Flag(name: .long, help: "Log as one JSON object per line.")
    var logJson = false

    @Flag(
        name: .long,
        help: """
            Include transcripts and screen text in the log. Off by default — a log you might paste \
            into an issue should not contain what you said.
            """)
    var logContent = false

    /// Called first thing in every `run()`. Returns the level actually in force.
    ///
    /// Precedence is flags over environment over defaults. The environment is merged first so that
    /// `DNT_LOG_FILE` works here exactly as it does for the app, and the flags are laid over it
    /// afterwards — a `--log-level` someone typed for this invocation must beat a variable exported
    /// in their profile last month, not the other way round.
    @discardableResult
    func start() -> LogLevel {
        var configuration = LogRouter.Configuration
            .commandLine(level: verbose ? .debug : .warning)
            .applyingEnvironment()

        if let logLevel, let parsed = LogLevel(name: logLevel) { configuration.level = parsed }
        if logJson { configuration.json = true }
        if logContent { configuration.includesContent = true }

        return LogRouter.shared.bootstrap(configuration, applyingEnvironment: false).level
    }
}

// MARK: - Backend selection

/// How to reach a provider. Defaults come from the app's own settings when it has any, so the CLI
/// and the menu bar do not disagree about which backend "the" backend is.
struct BackendOptions: ParsableArguments {
    @Option(
        name: .long,
        help: "Backend: \(ProviderKind.allCases.map(\.rawValue).joined(separator: ", ")). Defaults to the app's.")
    var provider: String?

    @Option(name: .long, help: "Model ID. Defaults to the app's, then the backend's own default.")
    var model: String?

    @Option(name: .long, help: "Fidelity: raw, light or tidy.")
    var fidelity: String?

    @Option(
        name: .long,
        help: "Path to the prompt/ directory. Found by walking up from the working directory.")
    var prompt: String?

    @Flag(
        inversion: .prefixedNo,
        help: "Read the key from the login Keychain when the environment has none.")
    var keychain = true

    @Flag(
        name: .long,
        help: """
            Derive spelling hints from the screen context for recognition backends. Off by \
            default; see the Keyterms notes in docs/EVALUATION.md.
            """)
    var keyterms = false

    func resolveProvider() throws -> ProviderKind {
        guard let provider else { return AppPreferences.provider }
        guard let kind = ProviderKind(persistedValue: provider) else {
            throw ValidationError(
                "Unknown provider '\(provider)'. Options: "
                    + ProviderKind.allCases.map(\.rawValue).joined(separator: ", "))
        }
        return kind
    }

    func resolveFidelity() throws -> Fidelity {
        guard let fidelity else { return AppPreferences.fidelity }
        guard let value = Fidelity(rawValue: fidelity.lowercased()) else {
            throw ValidationError(
                "Unknown fidelity '\(fidelity)'. Options: "
                    + Fidelity.allCases.map(\.rawValue).joined(separator: ", "))
        }
        return value
    }

    func resolveModel(for kind: ProviderKind) -> String {
        model ?? AppPreferences.model(for: kind)
    }

    func promptURL() throws -> URL {
        if let prompt { return URL(fileURLWithPath: prompt) }
        guard let found = PromptBuilder.findPromptDirectory() ?? Self.bundledPromptURL else {
            throw ValidationError(
                """
                Could not find the prompt/ directory. Run this from inside a checkout, pass \
                --prompt, or install the app — the CLI looks beside its own binary too.
                """)
        }
        return found
    }

    /// The copy inside `DoNotType.app`, for a `dnt` installed next to it.
    ///
    /// `make app` puts this binary in the bundle's `MacOS` directory, one level up from
    /// `Resources`, so an installed CLI finds the shipped contract without a checkout anywhere.
    static var bundledPromptURL: URL? {
        let binary = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let candidates = [
            binary.deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Resources/prompt"),
            URL(fileURLWithPath: "/Applications/DoNotType.app/Contents/Resources/prompt"),
        ]
        return candidates.first {
            FileManager.default.fileExists(
                atPath: $0.appendingPathComponent(PromptPart.system.relativePath).path)
        }
    }

    /// The prompt actually in force: the user's edited parts when they have any, exactly as the app
    /// would use them. A CLI that silently sent the shipped prompt while the app sent an edited one
    /// would make the two disagree about the only files that matter.
    func promptBuilder() throws -> PromptBuilder {
        let store = PromptStore(directory: HistoryStore.defaultDirectory())
        return store.builder(bundled: try promptURL())
    }

    func makeService(
        _ kind: ProviderKind, model overrideModel: String? = nil
    ) throws -> (service: TranscriptionService, source: String) {
        guard let resolved = APIKeyResolver.resolve(kind, allowsKeychain: keychain) else {
            throw ValidationError(
                """
                No API key for \(kind.rawValue). Set \(kind.apiKeyEnvVar), or add it in the app's \
                Settings — the CLI reads the same Keychain entry unless you pass --no-keychain.
                """)
        }
        // Registered before the first request, so the key cannot appear in a log line whatever
        // route it takes there — including a provider echoing it back inside an error body.
        LogRouter.shared.redact(secret: resolved.key)

        let provider = try ProviderFactory.make(kind, apiKey: resolved.key)
        let service = TranscriptionService(
            provider: provider,
            model: overrideModel ?? resolveModel(for: kind),
            systemInstruction: try promptBuilder().systemInstruction(
                fidelity: try resolveFidelity(),
                script: AppPreferences.chineseScript,
                dictationStyle: AppPreferences.dictationStyle,
                customDictationStyle: AppPreferences.customDictationStyle),
            fidelity: try resolveFidelity(),
            keytermBiasing: keyterms,
            typography: AppPreferences.typographySpacing)
        return (service, resolved.source)
    }

    /// The same, for the stage that rewrites rather than transcribes.
    ///
    /// Its own function because a backend can serve the two from different endpoints with the
    /// same key — xAI transcribes on `/v1/stt` and rewrites on `/v1/chat/completions` — so the
    /// provider object and the model both differ from the transcription ones. Nil when this
    /// backend has no text side at all.
    func makeTextService(
        _ kind: ProviderKind, model overrideModel: String? = nil
    ) throws -> (service: TranscriptionService, source: String)? {
        guard let resolved = APIKeyResolver.resolve(kind, allowsKeychain: keychain) else {
            throw ValidationError(
                """
                No API key for \(kind.rawValue). Set \(kind.apiKeyEnvVar), or add it in the app's \
                Settings — the CLI reads the same Keychain entry unless you pass --no-keychain.
                """)
        }
        LogRouter.shared.redact(secret: resolved.key)

        guard let provider = try ProviderFactory.makeTextProvider(kind, apiKey: resolved.key)
        else { return nil }
        let service = TranscriptionService(
            provider: provider,
            model: overrideModel ?? kind.defaultTextModel ?? resolveModel(for: kind),
            systemInstruction: try promptBuilder().systemInstruction(
                fidelity: try resolveFidelity(),
                script: AppPreferences.chineseScript,
                dictationStyle: AppPreferences.dictationStyle,
                customDictationStyle: AppPreferences.customDictationStyle),
            fidelity: try resolveFidelity(),
            typography: AppPreferences.typographySpacing)
        return (service, resolved.source)
    }
}

// MARK: - The app's settings

/// Reads what the menu-bar app is configured with.
///
/// The app writes plain `UserDefaults` in its own domain, which any process running as the same
/// user can read. Doing so means `dnt transcribe file.wav` uses the backend, model and fidelity the
/// user already chose, instead of a default the CLI invented — and it means `dnt doctor` can report
/// on the app's configuration rather than on its own.
///
/// Absent values fall back to the same defaults the app would use on a fresh install, so this works
/// on a machine where the app has never run.
enum AppPreferences {
    static let domain = "app.donottype"

    /// Recomputed per read rather than held: a `static let` holding a `UserDefaults` is a mutable
    /// global as far as Swift 6 is concerned, and the lookup is a dictionary hit.
    private static var defaults: UserDefaults? { UserDefaults(suiteName: domain) }

    /// Whether the user has ever changed a setting.
    ///
    /// Only *set* values cross the process boundary — a default the app registers at launch lives
    /// in its own process and is invisible here. That is harmless, because the fallbacks below are
    /// the same values the app would have registered; it just means "none found" has to be reported
    /// as "no stored preferences" rather than "the app has never run".
    static var isAvailable: Bool {
        guard let defaults else { return false }
        return ["provider", "model-google", "model-gemini", "fidelity", "trigger", "retention"]
            .contains { defaults.object(forKey: $0) != nil }
    }

    static var provider: ProviderKind {
        guard let raw = defaults?.string(forKey: "provider"),
            let kind = ProviderKind(persistedValue: raw)
        else { return .defaultForNewInstalls }
        return kind
    }

    static func model(for kind: ProviderKind) -> String {
        if let stored = defaults?.string(forKey: "model-\(kind.rawValue)"), !stored.isEmpty {
            return stored
        }
        // The same key under the backend's pre-rename name, as in the app.
        if let renamed = kind.legacyPersistedValue,
            let stored = defaults?.string(forKey: "model-\(renamed)"), !stored.isEmpty
        {
            return stored
        }
        // The pre-per-provider key, which an older install still has. Gemini's, as in the app.
        if kind == .google, let legacy = defaults?.string(forKey: "model"), !legacy.isEmpty {
            return legacy
        }
        return kind.defaultModel
    }

    /// The three typography preferences, read for the same reason every other one here is: the
    /// CLI and the app are the same product, and a transcript that came out of `dnt` should not be
    /// spaced differently from one the hotkey produced a minute earlier.
    static var typographySpacing: TypographySpacing {
        guard let raw = defaults?.string(forKey: "typographySpacing"),
            let value = TypographySpacing(rawValue: raw)
        else { return .default }
        return value
    }

    static var chineseScript: ChineseScript {
        guard let raw = defaults?.string(forKey: "chineseScript"),
            let value = ChineseScript(rawValue: raw)
        else { return .default }
        return value
    }

    static var dictationStyle: DictationStyle {
        guard let raw = defaults?.string(forKey: "dictationStyle"),
            let value = DictationStyle(rawValue: raw)
        else { return .default }
        return value
    }

    static var customDictationStyle: String {
        defaults?.string(forKey: "customDictationStyle") ?? ""
    }

    static var customRewriteStyle: String {
        defaults?.string(forKey: "customRewriteStyle") ?? ""
    }

    /// The language dictations are written in, or empty for the one that was spoken.
    static var translateTo: String {
        TranslationTarget.sanitized(defaults?.string(forKey: "translateTo") ?? "")
    }

    static var fidelity: Fidelity {
        guard let raw = defaults?.string(forKey: "fidelity"), let value = Fidelity(rawValue: raw)
        else { return .default }
        return value
    }

    static var keepsAudio: Bool { defaults?.bool(forKey: "keepAudio") ?? false }
}

// MARK: - Output

/// stdout is the transcript; stderr is everything else.
///
/// Kept as one type rather than scattered `print`/`FileHandle` calls because the rule is easy to
/// break by accident and a single stray `print` in a progress path silently corrupts every piped
/// transcript downstream.
enum Out {
    static func stdout(_ text: String, terminator: String = "\n") {
        FileHandle.standardOutput.write(Data((text + terminator).utf8))
    }

    static func note(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }

    /// Overwritable one-line progress, for a terminal. Silent when stderr is redirected — a
    /// progress bar in a log file is noise.
    static func progress(_ text: String) {
        guard isatty(fileno(stderr)) == 1 else { return }
        FileHandle.standardError.write(Data(("\r\u{1B}[2K" + text).utf8))
    }

    static func endProgress() {
        guard isatty(fileno(stderr)) == 1 else { return }
        FileHandle.standardError.write(Data("\r\u{1B}[2K".utf8))
    }
}

extension JSONEncoder {
    /// Stable key order, readable indentation, ISO dates. Everything this CLI emits is meant to be
    /// diffed or piped into `jq`.
    static var cli: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
