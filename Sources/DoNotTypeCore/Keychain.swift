import Foundation
import Security

/// Where the API key lives.
///
/// In the core rather than the app because `dnt` needs the same answer the menu bar gets. A CLI
/// that could not see the key the user already configured would either be useless or would push
/// them into exporting a second copy into their shell profile — which is how a key ends up in a
/// dotfile, a backup and a screen share.
///
/// One account per provider, so switching backends does not overwrite the previous one's key.
public enum Keychain {
    private static let service = "app.donottype"

    public static func read(account: String) -> String? {
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

    public static func write(_ value: String, account: String) {
        delete(account: account)
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
        ]
        SecItemAdd(attributes as CFDictionary, nil)
    }

    public static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// Finds the key for a backend, and says where it came from.
///
/// The order is environment first, then the Keychain. That is the opposite of what the app does
/// internally, and deliberately so: a key exported in the shell you are typing in is an explicit
/// instruction for this invocation, while the Keychain entry is the standing configuration. It also
/// makes `GEMINI_API_KEY=other-key dnt transcribe …` do what it obviously should.
public enum APIKeyResolver {
    public struct Resolution: Sendable, Equatable {
        public var key: String
        /// `environment (GEMINI_API_KEY)` or `keychain`, for anything that has to report it.
        public var source: String
    }

    public static func resolve(
        _ kind: ProviderKind,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        allowsKeychain: Bool = true
    ) -> Resolution? {
        for name in kind.apiKeyEnvVars {
            if let value = environment[name]?.trimmed, !value.isEmpty {
                return Resolution(key: value, source: "environment (\(name))")
            }
        }
        if allowsKeychain, let stored = Keychain.read(account: kind.rawValue)?.trimmed,
            !stored.isEmpty
        {
            return Resolution(key: stored, source: "keychain")
        }
        // A self-hosted server usually has no auth at all, so an absent key is normal there rather
        // than a misconfiguration. Matches `ProviderFactory`.
        if kind == .local {
            return Resolution(key: "not-required", source: "not required for a local server")
        }
        return nil
    }
}
