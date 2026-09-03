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
        static let typographySpacing = "typographySpacing"
        static let chineseScript = "chineseScript"
        static let dictationExample = "dictationExample"
        // Retired, read once by `migrateDictationExample()` and then cleared. Kept as names here
        // so the migration reads the same strings the old build wrote.
        static let legacyDictationStyle = "dictationStyle"
        static let legacyCustomDictationStyle = "customDictationStyle"
        static let customRewriteStyle = "customRewriteStyle"
        static let translateTo = "translateTo"
        static let trigger = "trigger"
        static let groundingEnabled = "groundingEnabled"
        static let screenshotEnabled = "screenshotEnabled"
        static let keepAudio = "keepAudio"
        static let blockedBundleIDs = "blockedBundleIDs"
        static let blockedURLPrefixes = "blockedURLPrefixes"
        static let retention = "retention"
        static let hotkeyMode = "hotkeyMode"
        static let cancelShortcut = "cancelShortcut"
        static let finishAndSendAction = "finishAndSendAction"
        // The stored names still say "secondary" from when a rewrite was the only thing a
        // second key could do. Renaming them would log every existing user out of their own
        // binding to no benefit, so the spelling on disk stays and the property names moved.
        static let rewriteTrigger = "secondaryTrigger"
        static let rewriteStyle = "secondaryStyle"
        static let translateTrigger = "translateTrigger"
        static let microphoneUID = "microphoneUID"
        static let interactionSounds = "interactionSounds"
        static let keytermBiasing = "keytermBiasing"
        static let fallbackProvider = "fallbackProvider"
        static let textModel = "textModel"
        static let fallbackAfterSeconds = "fallbackAfterSeconds"
        static let logLevel = "logLevel"
        static let logContent = "logContent"
        static let fileMode = "fileMode"
        static let endpoint = "endpoint"
        static let dictionaryTerms = "dictionaryTerms"
        static let learnedDictionaryTerms = "learnedDictionaryTerms"
        static let learnDictionaryFromEdits = "learnDictionaryFromEdits"
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
            Key.cancelShortcut: CancelShortcut.escape.rawValue,
            // Finishing a message can send it to another person, so it must be a deliberate opt-in.
            Key.finishAndSendAction: FinishAndSendAction.disabled.rawValue,
            Key.rewriteStyle: RewriteStyle.casual.rawValue,
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

    /// Key bound to a rewrite style. Off unless the user picks one, because a key that silently
    /// rewrites what you said would be the exact failure this project exists to avoid.
    var rewriteTrigger: HotkeyMonitor.Trigger? {
        get {
            guard let raw = defaults.string(forKey: Key.rewriteTrigger) else { return nil }
            return HotkeyMonitor.Trigger(rawValue: raw)
        }
        set { defaults.set(newValue?.rawValue, forKey: Key.rewriteTrigger) }
    }

    var rewriteStyle: RewriteStyle {
        get {
            RewriteStyle(rawValue: defaults.string(forKey: Key.rewriteStyle) ?? "") ?? .casual
        }
        set { defaults.set(newValue.rawValue, forKey: Key.rewriteStyle) }
    }

    /// Key bound to the configured target language. Off by default for the same reason the
    /// rewrite key is: `translateTo` alone used to be enough to change what every key delivered.
    var translateTrigger: HotkeyMonitor.Trigger? {
        get {
            guard let raw = defaults.string(forKey: Key.translateTrigger) else { return nil }
            return HotkeyMonitor.Trigger(rawValue: raw)
        }
        set { defaults.set(newValue?.rawValue, forKey: Key.translateTrigger) }
    }

    var hotkeyMode: HotkeyMonitor.Mode {
        get {
            HotkeyMonitor.Mode(rawValue: defaults.string(forKey: Key.hotkeyMode) ?? "")
                ?? .automatic
        }
        set { defaults.set(newValue.rawValue, forKey: Key.hotkeyMode) }
    }

    var cancelShortcut: CancelShortcut {
        get {
            CancelShortcut(rawValue: defaults.string(forKey: Key.cancelShortcut) ?? "")
                ?? .escape
        }
        set { defaults.set(newValue.rawValue, forKey: Key.cancelShortcut) }
    }

    var finishAndSendAction: FinishAndSendAction {
        get {
            FinishAndSendAction(rawValue: defaults.string(forKey: Key.finishAndSendAction) ?? "")
                ?? .disabled
        }
        set { defaults.set(newValue.rawValue, forKey: Key.finishAndSendAction) }
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
    /// A single shared field would send `gemini-3.5-flash` to Deepgram's `/v1/listen` the moment
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

    private func endpointKey(for kind: ProviderKind) -> String {
        "\(Key.endpoint)-\(kind.rawValue)"
    }

    /// The URL this backend posts to, or empty for its own.
    ///
    /// Per backend rather than one global setting, for the same reason the key and the model are:
    /// somebody who points OpenRouter at a mirror and then switches to Google for a week must not
    /// come back to find their mirror gone, or worse, still being used by the wrong backend.
    var endpoint: String {
        get { endpoint(for: provider) }
        set { setEndpoint(newValue, for: provider) }
    }

    /// The endpoint for a backend that is not the current selection. See `resolvedAPIKey(for:)`.
    func endpoint(for kind: ProviderKind) -> String {
        defaults.string(forKey: endpointKey(for: kind))?.trimmed ?? ""
    }

    func setEndpoint(_ value: String, for kind: ProviderKind) {
        defaults.set(value.trimmed, forKey: endpointKey(for: kind))
    }

    /// The model for a backend that is not the current selection — the fallback's, in practice.
    func setModel(_ value: String, for kind: ProviderKind) {
        defaults.set(value.trimmed, forKey: modelKey(for: kind))
    }

    func setTextModel(_ value: String?, for kind: ProviderKind) {
        defaults.set(value?.trimmed ?? "", forKey: textModelKey(for: kind))
    }

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

    /// What happens where Chinese meets Latin in a finished transcript. Deterministic — see
    /// `Typography`. The other three clients spell the stored values the same way.
    var typographySpacing: TypographySpacing {
        get {
            TypographySpacing(rawValue: defaults.string(forKey: Key.typographySpacing) ?? "")
                ?? .default
        }
        set { defaults.set(newValue.rawValue, forKey: Key.typographySpacing) }
    }

    /// Which characters Chinese is written in. Asked of the model; see `ChineseScript`.
    var chineseScript: ChineseScript {
        get {
            ChineseScript(rawValue: defaults.string(forKey: Key.chineseScript) ?? "") ?? .default
        }
        set { defaults.set(newValue.rawValue, forKey: Key.chineseScript) }
    }

    /// How the transcript should be written down — a description, or a sentence written the way
    /// the user wants theirs written. Empty sends nothing at all.
    ///
    /// One string where there used to be a five-case enum and a text box that only one of the
    /// cases used. Sanitised on the way in rather than on the way out, so what the settings window
    /// shows is what a request would carry.
    var dictationExample: String {
        get { defaults.string(forKey: Key.dictationExample) ?? "" }
        set { defaults.set(Typography.sanitizedSample(newValue), forKey: Key.dictationExample) }
    }

    /// Turns a pre-example install's style setting into the text that setting was sending.
    ///
    /// Runs once, at launch, and clears the old keys so it cannot run twice and cannot resurrect a
    /// value the user has since edited. Nobody's dictations change: someone who had chosen Chat had
    /// `chat.md`'s words in every request, and afterwards has those same words in their box, where
    /// they can finally see them. Someone on the default had nothing appended and still does.
    ///
    /// - Parameter presetText: resolves a preset to its text. Passed in because `Settings` has no
    ///   prompt directory of its own, and the one in force may be the user's override.
    func migrateDictationExample(presetText: (DictationPreset) -> String?) {
        let legacyStyle = defaults.string(forKey: Key.legacyDictationStyle)
        let legacyCustom = defaults.string(forKey: Key.legacyCustomDictationStyle)
        guard legacyStyle != nil || legacyCustom != nil else { return }

        func clearLegacyKeys() {
            defaults.removeObject(forKey: Key.legacyDictationStyle)
            defaults.removeObject(forKey: Key.legacyCustomDictationStyle)
        }

        // An example already set wins. The migration is for an install that has never seen the box,
        // and overwriting a box somebody has typed into would be the one unforgivable outcome.
        guard (defaults.string(forKey: Key.dictationExample) ?? "").isEmpty else {
            clearLegacyKeys()
            return
        }
        // Nil is "not knowable yet", never "no style". Clearing the keys on an unreadable prompt
        // directory would throw away the only record of what the user chose, permanently, over
        // something that will probably work on the next launch.
        guard let migrated = DictationExample.migrating(
            legacyStyle: legacyStyle, legacyCustom: legacyCustom, presetText: presetText)
        else { return }
        clearLegacyKeys()
        // Written even when empty, and that is load-bearing: it records that this install has made
        // its choice, so `seedDictationExample` leaves it alone. Someone upgrading from "As spoken"
        // was sending nothing and goes on sending nothing.
        dictationExample = migrated
    }

    /// Gives a brand-new install the default example, once.
    ///
    /// After the migration, and only when the key has never been written — an empty string is
    /// somebody who pressed Clear, and putting words back they had just removed is the same
    /// unforgivable outcome the migration guards against.
    func seedDictationExample(presetText: (DictationPreset) -> String?) {
        guard let seeded = DictationExample.seeding(
            stored: defaults.string(forKey: Key.dictationExample), presetText: presetText)
        else { return }
        dictationExample = seeded
    }

    /// The same, for the rewrite stage. Its own setting because the two are different jobs — this
    /// one may reword, and the dictation style may not.
    var customRewriteStyle: String {
        get { defaults.string(forKey: Key.customRewriteStyle) ?? "" }
        set { defaults.set(Typography.sanitizedSample(newValue), forKey: Key.customRewriteStyle) }
    }

    var trigger: HotkeyMonitor.Trigger {
        get {
            HotkeyMonitor.Trigger(rawValue: defaults.string(forKey: Key.trigger) ?? "")
                ?? .rightCommand
        }
        set { defaults.set(newValue.rawValue, forKey: Key.trigger) }
    }

    /// The language dictations are written in, or empty for the one that was spoken.
    ///
    /// Empty by default, and that default is the product: this is the one setting that makes the
    /// main key deliver something other than what was said. What it does *not* change is the
    /// promise underneath — the verbatim transcript is still produced first and still stored, so
    /// `⌘⌥Z` puts the spoken words back exactly as it does after a rewrite.
    var translateTo: String {
        get { TranslationTarget.sanitized(defaults.string(forKey: Key.translateTo) ?? "") }
        set { defaults.set(TranslationTarget.sanitized(newValue), forKey: Key.translateTo) }
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

    /// Terms the user entered or imported. Stored locally in preferences; there is no account or
    /// sync service involved.
    var dictionaryTerms: [String] {
        get { PersonalDictionary.sanitized(defaults.stringArray(forKey: Key.dictionaryTerms) ?? []) }
        set { defaults.set(PersonalDictionary.sanitized(newValue), forKey: Key.dictionaryTerms) }
    }

    /// Terms inferred from explicit spelling corrections, kept separately so the dictionary UI
    /// can say where each prior came from and remove learned entries without touching manual ones.
    var learnedDictionaryTerms: [String] {
        get {
            let manual = dictionaryTerms
            let manualKeys = Set(manual.map { $0.lowercased() })
            let remaining = max(0, PersonalDictionary.maxTerms - manual.count)
            return PersonalDictionary.sanitized(
                defaults.stringArray(forKey: Key.learnedDictionaryTerms) ?? []
            ).filter { !manualKeys.contains($0.lowercased()) }.prefix(remaining).map { $0 }
        }
        set {
            let manual = dictionaryTerms
            let manualKeys = Set(manual.map { $0.lowercased() })
            let remaining = max(0, PersonalDictionary.maxTerms - manual.count)
            let values = PersonalDictionary.sanitized(newValue)
                .filter { !manualKeys.contains($0.lowercased()) }.prefix(remaining).map { $0 }
            defaults.set(values, forKey: Key.learnedDictionaryTerms)
        }
    }

    var personalDictionaryTerms: [String] {
        PersonalDictionary.sanitized(dictionaryTerms + learnedDictionaryTerms)
    }

    /// Opt-in because learning is a convenience with a real failure mode, not a neutral default.
    /// Only spelling fixes classified by `PersonalDictionary.learnedCandidates` reach the list.
    var learnDictionaryFromEdits: Bool {
        get { defaults.bool(forKey: Key.learnDictionaryFromEdits) }
        set { defaults.set(newValue, forKey: Key.learnDictionaryFromEdits) }
    }

    /// Adds new learned spellings and returns only the entries that were actually stored.
    @discardableResult
    func learnDictionaryTerms(_ candidates: [String]) -> [String] {
        guard learnDictionaryFromEdits else { return [] }
        var learned = learnedDictionaryTerms
        var all = personalDictionaryTerms
        var added: [String] = []
        for candidate in candidates {
            guard let term = try? PersonalDictionary.normalize(candidate),
                !all.contains(where: { $0.caseInsensitiveCompare(term) == .orderedSame }),
                all.count < PersonalDictionary.maxTerms
            else { continue }
            learned.append(term)
            all.append(term)
            added.append(term)
        }
        learnedDictionaryTerms = learned
        return added
    }

    func forgetLearnedDictionaryTerms(_ terms: [String]) {
        let keys = Set(terms.map { $0.lowercased() })
        learnedDictionaryTerms.removeAll { keys.contains($0.lowercased()) }
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
        set { setAPIKey(newValue, for: provider) }
    }

    /// The stored credential only, never an environment fallback. A settings export must not
    /// quietly copy a secret inherited from somebody's shell or launch agent.
    func storedAPIKey(for kind: ProviderKind) -> String? { Self.keychainKey(for: kind) }

    func setAPIKey(_ value: String?, for kind: ProviderKind) {
        if let value, !value.isEmpty {
            Keychain.write(value, account: kind.rawValue)
        } else {
            Keychain.delete(account: kind.rawValue)
            // The entry under the pre-rename name too, or the getter's fallback would resurrect a
            // key that an imported profile deliberately cleared.
            if let renamed = kind.legacyPersistedValue { Keychain.delete(account: renamed) }
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

    /// Builds a backend with everything the user configured for it.
    ///
    /// The one place the app turns a `ProviderKind` into a provider, so a setting added here
    /// reaches every caller — dictation, the fallback, the rewrite, file transcription, the
    /// connection test and the warm-up — rather than the subset somebody remembered. The endpoint
    /// override was previously reachable only through an environment variable, which an app opened
    /// from Finder does not have, and only for one backend.
    ///
    /// - Parameter apiKey: the key to use, for callers that have already resolved one. Resolved
    ///   from the Keychain and the environment otherwise.
    func makeProvider(
        _ kind: ProviderKind, apiKey: String? = nil
    ) throws -> any TranscriptionProvider {
        let key = apiKey ?? resolvedAPIKey(for: kind) ?? ""
        return try ProviderFactory.make(kind, apiKey: key, endpoint: endpoint(for: kind))
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
