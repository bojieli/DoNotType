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
            ProviderKind(rawValue: defaults.string(forKey: Key.provider) ?? "")
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
            if provider == .gemini, let legacy = defaults.string(forKey: Key.model),
                !legacy.isEmpty
            {
                return legacy
            }
            return provider.defaultModel
        }
        set { defaults.set(newValue, forKey: modelKey(for: provider)) }
    }

    private func modelKey(for kind: ProviderKind) -> String { "\(Key.model)-\(kind.rawValue)" }

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
        get { Keychain.read(account: provider.rawValue) }
        set {
            if let newValue, !newValue.isEmpty {
                Keychain.write(newValue, account: provider.rawValue)
            } else {
                Keychain.delete(account: provider.rawValue)
            }
        }
    }

    /// Falls back to the environment so a developer running from a terminal does not have to
    /// populate the Keychain first.
    func resolvedAPIKey() -> String? {
        if let stored = apiKey, !stored.isEmpty { return stored }
        return ProcessInfo.processInfo.environment[provider.apiKeyEnvVar]
    }
}

enum Keychain {
    private static let service = "app.donottype"

    static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String, account: String) {
        delete(account: account)
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
        ]
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
