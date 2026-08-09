import AppKit
import DoNotTypeCore
import Foundation

/// Decides whether the screen may be read at all.
///
/// Evaluated **before** capture, never after. Filtering a context you have already collected still
/// means the text existed in this process's memory; refusing to collect it means it never did.
@MainActor
enum PrivacyGate {
    enum Decision: Equatable {
        case allowed
        case blockedApp(String)
        case blockedURL(String)
        case ownApp

        var isAllowed: Bool { self == .allowed }

        var reason: String? {
            switch self {
            case .allowed: nil
            case .blockedApp(let name): "\(name) is on the blocklist"
            case .blockedURL(let prefix): "the page matches a blocked prefix (\(prefix))"
            case .ownApp: "DoNotType is frontmost"
            }
        }
    }

    static func evaluate(bundleID: String?, appName: String?, url: String?) -> Decision {
        if bundleID == Bundle.main.bundleIdentifier { return .ownApp }

        if let bundleID {
            let blocked = Settings.shared.blockedBundleIDs
            if blocked.contains(where: { $0.caseInsensitiveCompare(bundleID) == .orderedSame }) {
                return .blockedApp(appName ?? bundleID)
            }
        }
        if let url {
            for prefix in Settings.shared.blockedURLPrefixes
            where url.lowercased().hasPrefix(prefix.lowercased()) {
                return .blockedURL(prefix)
            }
        }
        return .allowed
    }

    /// Convenience for the current frontmost app.
    static func evaluateFrontmost(url: String? = nil) -> Decision {
        let app = NSWorkspace.shared.frontmostApplication
        return evaluate(bundleID: app?.bundleIdentifier, appName: app?.localizedName, url: url)
    }
}
