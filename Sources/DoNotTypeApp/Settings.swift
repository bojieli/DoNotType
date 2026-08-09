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
        static let keepAudio = "keepAudio"
        static let blockedBundleIDs = "blockedBundleIDs"
        static let blockedURLPrefixes = "blockedURLPrefixes"
        static let retention = "retention"
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
            Key.provider: ProviderKind.gemini.rawValue,
            Key.fidelity: Fidelity.default.rawValue,
            Key.trigger: HotkeyMonitor.Trigger.rightCommand.rawValue,
            Key.groundingEnabled: true,
            Key.screenshotEnabled: true,
            Key.keepAudio: false,
            Key.blockedBundleIDs: Self.defaultBlockedBundleIDs,
            Key.blockedURLPrefixes: Self.defaultBlockedURLPrefixes,
            Key.retention: RetentionPolicy.forever.rawValue,
        ])
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
        get { ProviderKind(rawValue: defaults.string(forKey: Key.provider) ?? "") ?? .gemini }
        set { defaults.set(newValue.rawValue, forKey: Key.provider) }
    }

    var model: String {
        get { defaults.string(forKey: Key.model) ?? provider.defaultModel }
        set { defaults.set(newValue, forKey: Key.model) }
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
    private static let service = "ai.19pine.donottype"

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
