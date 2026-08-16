import DoNotTypeCore
import Foundation

/// User preferences, and the API key.
///
/// The key goes in the Keychain, never `UserDefaults` and never a config file: this is a
/// bring-your-own-key app, so the key is the whole privacy story and a plist is not where it
/// belongs.
@MainActor
final class Settings {
    static let shared = Settings()

    private let defaults = UserDefaults.standard

    private enum Key {
        static let provider = "provider"
        static let model = "model"
        static let fidelity = "fidelity"
        static let trigger = "trigger"
        static let groundingEnabled = "groundingEnabled"
        static let screenshotEnabled = "screenshotEnabled"
        static let verifyNumbers = "verifyNumbers"
        static let keepAudio = "keepAudio"
        static let blockedBundleIDs = "blockedBundleIDs"
        static let blockedURLPrefixes = "blockedURLPrefixes"
        static let retention = "retention"
        static let hotkeyMode = "hotkeyMode"
        static let secondaryTrigger = "secondaryTrigger"
        static let secondaryStyle = "secondaryStyle"
        static let microphoneUID = "microphoneUID"
        static let interactionSounds = "interactionSounds"
        static let keytermBiasing = "keytermBiasing"
        static let fallbackProvider = "fallbackProvider"
        static let textModel = "textModel"
        static let fallbackAfterSeconds = "fallbackAfterSeconds"
        static let logLevel = "logLevel"
        static let logContent = "logContent"
        static let fileMode = "fileMode"
    }

    /// Shipped non-empty. A blocklist that starts empty is a blocklist nobody ever fills in, and
    /// this app transmits screen contents.
    static let defaultBlockedBundleIDs = [
        "com.apple.keychainaccess",
        "com.1password.1password", "com.agilebits.onepassword7",
        "com.bitwarden.desktop", "com.lastpass.LastPass",
        "com.apple.Passwords",
    ]

    static let defaultBlockedURLPrefixes = [
        "https://accounts.google.com",
        "https://login.microsoftonline.com",
        "https://vault.bitwarden.com",
    ]

    private init() {
        defaults.register(defaults: [
            Key.provider: ProviderKind.defaultForNewInstalls.rawValue,
            Key.fidelity: Fidelity.default.rawValue,
            Key.trigger: HotkeyMonitor.Trigger.rightCommand.rawValue,
            Key.groundingEnabled: true,
            Key.screenshotEnabled: true,
            Key.keepAudio: false,
            Key.blockedBundleIDs: Self.defaultBlockedBundleIDs,
            Key.blockedURLPrefixes: Self.defaultBlockedURLPrefixes,
            Key.retention: RetentionPolicy.forever.rawValue,
            Key.hotkeyMode: HotkeyMonitor.Mode.automatic.rawValue,
            Key.secondaryStyle: RewriteStyle.formal.rawValue,
            // Audible boundaries make it clear when capture has begun and ended, even when the
            // recording overlay is behind another window. Users can still turn them off below.
            Key.interactionSounds: true,
        ])
    }

    /// How much the app writes to its log file.
    ///
    /// Persisted rather than environment-only because the people who need it most are the ones who
    /// cannot set an environment variable for a bundle launched from Finder — `~/.zshrc` is read by
    /// interactive shells and nothing else. `DNT_LOG_LEVEL` still overrides this when it is set,
    /// which is what a developer running from a terminal expects.
    var logLevel: LogLevel {
        get { LogLevel(name: defaults.string(forKey: Key.logLevel) ?? "") ?? .info }
        set {
            defaults.set(newValue.name, forKey: Key.logLevel)
            LogRouter.shared.setLevel(newValue)
        }
    }

    /// Whether transcripts and screen text may go into the log.
    ///
    /// Off, and it stays off unless someone deliberately turns it on: a log file is the one artifact
    /// of this app most likely to be attached to a bug report, and an app whose promise is that
    /// your words stay yours should not write a second copy of them by default.
    var logContent: Bool {
        get { defaults.bool(forKey: Key.logContent) }
        set {
            defaults.set(newValue, forKey: Key.logContent)
            LogRouter.shared.setIncludesContent(newValue)
        }
    }

    /// Last mode chosen in the file transcription window, so it opens where you left it.
    var fileMode: TranscriptMode {
        get {
            TranscriptMode(rawValue: defaults.string(forKey: Key.fileMode) ?? "") ?? .verbatim
        }
        set { defaults.set(newValue.rawValue, forKey: Key.fileMode) }
    }

    /// Where the log file lives, next to the history it explains.
    static var logDirectory: URL {
        HistoryStore.defaultDirectory().appendingPathComponent("logs", isDirectory: true)
    }

    /// Installs logging for the whole process. Called once, before anything else can log.
    ///
    /// Every configured key is registered for redaction here rather than at the point of use: a key
    /// reaches the log through routes nobody planned — a provider echoing it back inside an error
    /// body, a base URL someone pasted it into — and the only reliable defence is knowing the exact
    /// bytes before the first request.
    func startLogging() {
        var configuration = LogRouter.Configuration.app(logDirectory: Self.logDirectory)
        configuration.level = logLevel
        configuration.includesContent = logContent
        let resolved = LogRouter.shared.bootstrap(configuration)

        for kind in ProviderKind.allCases {
            if let key = resolvedAPIKey(for: kind), !key.isEmpty {
                LogRouter.shared.redact(secret: key)
            }
        }

        Log("app").info(
            "started",
            [
                "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
                    ?? "dev",
                "level": resolved.level.name,
                "log": resolved.fileURL?.path ?? "none",
                "provider": provider.rawValue,
                "model": model,
            ])
    }

    /// Pinned input device, by UID. Nil means "whatever the system default is".
    ///
    /// UID rather than AudioDeviceID because IDs are reassigned across reboots and reconnections,
    /// so a saved ID would silently point at the wrong device.
    var microphoneUID: String? {
        get { defaults.string(forKey: Key.microphoneUID) }
        set { defaults.set(newValue, forKey: Key.microphoneUID) }
    }

    /// On by default so recording boundaries are audible even when the overlay is not visible.
    /// Users who find a tone on every dictation distracting can turn it off in Audio settings.
    var interactionSounds: Bool {
        get { defaults.bool(forKey: Key.interactionSounds) }
        set { defaults.set(newValue, forKey: Key.interactionSounds) }
    }

    /// Second key bound to a rewrite style. Off unless the user picks one, because a key that
    /// silently rewrites what you said would be the exact failure this project exists to avoid.
    var secondaryTrigger: HotkeyMonitor.Trigger? {
        get {
            guard let raw = defaults.string(forKey: Key.secondaryTrigger) else { return nil }
            return HotkeyMonitor.Trigger(rawValue: raw)
        }
        set { defaults.set(newValue?.rawValue, forKey: Key.secondaryTrigger) }
    }

    var secondaryStyle: RewriteStyle {
        get {
            RewriteStyle(rawValue: defaults.string(forKey: Key.secondaryStyle) ?? "") ?? .formal
        }
        set { defaults.set(newValue.rawValue, forKey: Key.secondaryStyle) }
    }

    var hotkeyMode: HotkeyMonitor.Mode {
        get {
            HotkeyMonitor.Mode(rawValue: defaults.string(forKey: Key.hotkeyMode) ?? "")
                ?? .automatic
        }
        set { defaults.set(newValue.rawValue, forKey: Key.hotkeyMode) }
    }

    /// How long transcripts are kept. Note that a failed dictation keeps its audio regardless,
    /// until it succeeds or is deleted — otherwise Retry would be a button that cannot work.
    var retention: RetentionPolicy {
        get {
            RetentionPolicy(rawValue: defaults.string(forKey: Key.retention) ?? "") ?? .forever
        }
        set { defaults.set(newValue.rawValue, forKey: Key.retention) }
    }

    var provider: ProviderKind {
        get {
            ProviderKind(persistedValue: defaults.string(forKey: Key.provider) ?? "")
                ?? .defaultForNewInstalls
        }
        set { defaults.set(newValue.rawValue, forKey: Key.provider) }
    }

    /// Stored per provider, like the Keychain entry above.
    ///
    /// A single shared field would send `gemini-3.6-flash` to Deepgram's `/v1/listen` the moment
    /// someone switched backend to compare them — which is the whole reason there is more than
    /// one. The legacy flat value is read as Gemini's so an existing install keeps its choice.
    var model: String {
        get {
            if let stored = defaults.string(forKey: modelKey(for: provider)), !stored.isEmpty {
                return stored
            }
            // The same per-provider key under the name this backend used to have, so renaming a
            // case does not read as a factory reset to someone who had chosen a model.
            if let renamed = provider.legacyPersistedValue,
                let stored = defaults.string(forKey: "\(Key.model)-\(renamed)"), !stored.isEmpty
            {
                return stored
            }
            if provider == .google, let legacy = defaults.string(forKey: Key.model),
                !legacy.isEmpty
            {
                return legacy
            }
            return provider.defaultModel
        }
        set { defaults.set(newValue, forKey: modelKey(for: provider)) }
    }

    private func modelKey(for kind: ProviderKind) -> String { "\(Key.model)-\(kind.rawValue)" }

    /// The model the second stage runs on, when the provider serves text from a different model
    /// than it transcribes with. Nil for every backend where one model does both, so the two
    /// cannot drift apart in the one case where a single field would have been enough.
    var textModel: String? {
        get { textModel(for: provider) }
        set { defaults.set(newValue ?? "", forKey: textModelKey(for: provider)) }
    }

    /// See `model(for:)` — the same lookup, for the stage that rewrites rather than transcribes.
    func textModel(for kind: ProviderKind) -> String? {
        guard let fallback = kind.defaultTextModel else { return nil }
        if let stored = defaults.string(forKey: textModelKey(for: kind)), !stored.isEmpty {
            return stored
        }
        return fallback
    }

    private func textModelKey(for kind: ProviderKind) -> String {
        "\(Key.textModel)-\(kind.rawValue)"
    }

    /// Backend to start alongside the primary when it has not answered in time. Nil disables it.
    ///
    /// Off by default. Hedging costs a second request and can hand you a less accurate transcript,
    /// so it is something to turn on after being bitten by the primary's tail rather than a thing
    /// that quietly happens to everyone.
    var fallbackProvider: ProviderKind? {
        get {
            guard let raw = defaults.string(forKey: Key.fallbackProvider), !raw.isEmpty else {
                return nil
            }
            let kind = ProviderKind(persistedValue: raw)
            // A fallback identical to the primary would double the cost to no purpose.
            return kind == provider ? nil : kind
        }
        set { defaults.set(newValue?.rawValue ?? "", forKey: Key.fallbackProvider) }
    }

    /// How long the primary gets on its own before the fallback starts alongside it.
    ///
    /// This is the accuracy-against-latency dial. Below the primary's normal response time it
    /// hedges constantly and you mostly get the fallback's transcript; far above it the tail is
    /// not bounded by much. Clamped rather than validated so a hand-edited plist cannot produce a
    /// zero-second hedge that races from the start.
    var fallbackAfterSeconds: Double {
        get {
            let stored = defaults.double(forKey: Key.fallbackAfterSeconds)
            return stored > 0 ? min(max(stored, 1), 120) : 8
        }
        set { defaults.set(min(max(newValue, 1), 120), forKey: Key.fallbackAfterSeconds) }
    }

    var fidelity: Fidelity {
        get { Fidelity(rawValue: defaults.string(forKey: Key.fidelity) ?? "") ?? .default }
        set { defaults.set(newValue.rawValue, forKey: Key.fidelity) }
    }

    var trigger: HotkeyMonitor.Trigger {
        get {
            HotkeyMonitor.Trigger(rawValue: defaults.string(forKey: Key.trigger) ?? "")
                ?? .rightCommand
        }
        set { defaults.set(newValue.rawValue, forKey: Key.trigger) }
    }

    var groundingEnabled: Bool {
        get { defaults.bool(forKey: Key.groundingEnabled) }
        set { defaults.set(newValue, forKey: Key.groundingEnabled) }
    }

    /// Screenshots are only captured when the accessibility tree comes back thin, so this being
    /// on does not mean an image is sent every time.
    var screenshotEnabled: Bool {
        get { defaults.bool(forKey: Key.screenshotEnabled) }
        set { defaults.set(newValue, forKey: Key.screenshotEnabled) }
    }

    /// When to spend a second, screen-blind request to check the numbers.
    ///
    /// Defaults to the measured middle: only when the text around the caret contains digits. That
    /// is the regime where a screen value overwrites a spoken one 75% of the time, against 30%
    /// when the contradiction is off in the visible text — so the request buys the most where it
    /// is spent, and ordinary dictation into an empty field never pays for it.
    var numberCheck: NumberCheckPolicy {
        get {
            defaults.string(forKey: Key.verifyNumbers)
                .flatMap(NumberCheckPolicy.init(rawValue:)) ?? .whenCaretHasNumbers
        }
        set { defaults.set(newValue.rawValue, forKey: Key.verifyNumbers) }
    }

    /// Whether a recognition backend may be given a word list derived from the screen.
    ///
    /// Off by default, unlike `groundingEnabled`. The two are not the same feature wearing
    /// different hats: grounding hands a model the screen text under an explicit "reference only,
    /// do not transcribe" instruction, while a keyterm list is a bare vocabulary prior with no
    /// way to say that. See `Keyterms` for what it refuses to send and why.
    var keytermBiasing: Bool {
        get { defaults.bool(forKey: Key.keytermBiasing) }
        set { defaults.set(newValue, forKey: Key.keytermBiasing) }
    }

    var keepAudio: Bool {
        get { defaults.bool(forKey: Key.keepAudio) }
        set { defaults.set(newValue, forKey: Key.keepAudio) }
    }

    var blockedBundleIDs: [String] {
        get { defaults.stringArray(forKey: Key.blockedBundleIDs) ?? [] }
        set { defaults.set(newValue, forKey: Key.blockedBundleIDs) }
    }

    var blockedURLPrefixes: [String] {
        get { defaults.stringArray(forKey: Key.blockedURLPrefixes) ?? [] }
        set { defaults.set(newValue, forKey: Key.blockedURLPrefixes) }
    }

    // MARK: - API key

    var apiKey: String? {
        get { Self.keychainKey(for: provider) }
        set {
            if let newValue, !newValue.isEmpty {
                Keychain.write(newValue, account: provider.rawValue)
            } else {
                Keychain.delete(account: provider.rawValue)
                // The entry under the pre-rename name too, or the getter's fallback would
                // resurrect a key the user has just cleared.
                if let renamed = provider.legacyPersistedValue {
                    Keychain.delete(account: renamed)
                }
            }
        }
    }

    /// Falls back to the environment so a developer running from a terminal does not have to
    /// populate the Keychain first.
    ///
    /// Every spelling `ProviderFactory` accepts is tried, not just the canonical one: the factory
    /// takes `GROK_API_KEY` for xAI, and when this only looked at `XAI_API_KEY` the app refused to
    /// start a dictation over a key it would then have used happily.
    ///
    /// Note that the environment here is the *app's*, which for a bundle opened from Finder or
    /// Login Items is launchd's — `~/.zshrc` is read by interactive shells and nothing else. See
    /// `APIKeyStatus.explanation`, which is where a user finds that out.
    func resolvedAPIKey() -> String? { resolvedAPIKey(for: provider) }

    /// The same resolution for a backend that is *not* the current selection.
    ///
    /// The fallback provider needs its own credentials and is by definition not the one selected,
    /// so every accessor keyed off `provider` is the wrong one for it. Keys were already stored
    /// per provider in the Keychain; this reaches one directly.
    func resolvedAPIKey(for kind: ProviderKind) -> String? {
        if let stored = Self.keychainKey(for: kind), !stored.isEmpty { return stored }
        return Self.environmentAPIKey(for: kind)
    }

    /// The stored key, under the provider's name or the one it had before the rename.
    ///
    /// Keychain accounts are that name, so renaming a case without this would orphan a key that
    /// is still perfectly good and report the backend as unconfigured. Writes always use the
    /// current name, so the old account is read and never added to.
    private static func keychainKey(for kind: ProviderKind) -> String? {
        if let stored = Keychain.read(account: kind.rawValue), !stored.isEmpty { return stored }
        guard let renamed = kind.legacyPersistedValue,
            let stored = Keychain.read(account: renamed), !stored.isEmpty
        else { return nil }
        return stored
    }

    /// The model for a backend that is not the current selection. See `resolvedAPIKey(for:)`.
    func model(for kind: ProviderKind) -> String {
        if let stored = defaults.string(forKey: modelKey(for: kind)), !stored.isEmpty {
            return stored
        }
        if let renamed = kind.legacyPersistedValue,
            let stored = defaults.string(forKey: "\(Key.model)-\(renamed)"), !stored.isEmpty
        {
            return stored
        }
        return kind.defaultModel
    }

    /// The name the key was actually found under, for the settings window to report.
    static func environmentAPIKeyName(for provider: ProviderKind) -> String? {
        provider.apiKeyEnvVars.first { name in
            let value = ProcessInfo.processInfo.environment[name]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return !(value ?? "").isEmpty
        }
    }

    static func environmentAPIKey(for provider: ProviderKind) -> String? {
        guard let name = environmentAPIKeyName(for: provider) else { return nil }
        return ProcessInfo.processInfo.environment[name]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// `Keychain` moved into DoNotTypeCore so `dnt` reads the same entries this window writes. See
// `Keychain` and `APIKeyResolver` there.
