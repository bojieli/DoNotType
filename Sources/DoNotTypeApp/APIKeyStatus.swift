import DoNotTypeCore
import Foundation

/// What is known about the configured key right now.
///
/// The app used to have no such state: the key was read at the moment a dictation needed it, so
/// "no key" and "wrong key" were things you discovered by losing a sentence. This is checked at
/// launch and after every edit instead, which is the whole point of it existing.
enum APIKeyStatus: Equatable {
    /// Not looked at yet.
    case unchecked
    case checking
    /// Nothing in the Keychain, nothing in the environment.
    case missing
    /// The provider answered and said no — a bad key, an empty account, an impossible model.
    case rejected(String)
    /// The check could not complete. Says nothing about the key, and must never be shown as
    /// though it did.
    case unverified(String)
    case valid

    /// Whether the user has to do something before dictation can work.
    ///
    /// `unverified` is deliberately excluded: waking up on a train is not a configuration problem,
    /// and a settings window that opens itself every time the network is slow is one people learn
    /// to close without reading.
    var needsAttention: Bool {
        switch self {
        case .missing, .rejected: true
        case .unchecked, .checking, .unverified, .valid: false
        }
    }

    /// The one-line form, in the shape the settings window already renders: a leading ✓ or ✗.
    ///
    /// `latency` is the wall time of the complete provider probe, not model-reported inference
    /// time: it includes the network, authentication and response parsing a real dictation pays.
    func summary(provider: ProviderKind, latency: Duration? = nil) -> String? {
        let message: String?
        switch self {
        case .unchecked, .checking: message = nil
        case .valid: message = "✓ \(provider.displayName) reachable, key accepted"
        case .missing: message = "✗ No API key set."
        case .rejected(let detail): message = "✗ \(detail)"
        case .unverified(let detail): message = "✗ Could not check: \(detail)"
        }
        guard let message, let latency else { return message }
        return "\(message) · \(Self.latencyLabel(latency))"
    }

    private static func latencyLabel(_ duration: Duration) -> String {
        let components = duration.components
        let seconds = max(
            0,
            Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000)
        if seconds < 1 {
            return "\(Int((seconds * 1_000).rounded())) ms"
        }
        return String(format: "%.2f s", seconds)
    }

    /// The menu-bar line, for a failure that would otherwise only be visible in a window nobody
    /// has open.
    func menuTitle(provider: ProviderKind) -> String? {
        switch self {
        case .missing: "No API key for \(provider.displayName) — open Settings"
        case .rejected: "The \(provider.displayName) key was rejected — open Settings"
        case .unchecked, .checking, .unverified, .valid: nil
        }
    }

    /// Where the key was looked for, and why a key you are certain you set is not there.
    ///
    /// This paragraph is the answer to the only question a missing key ever raises. A bundle
    /// opened from Finder, the Dock or Login Items inherits launchd's environment, and `~/.zshrc`
    /// is sourced by interactive shells only — so `export XAI_API_KEY=…` is real in every terminal
    /// and invisible to the app. That is not obvious, it looks exactly like a bug, and the fix is
    /// one paste into the field above.
    static func explanation(for provider: ProviderKind) -> String {
        let names = provider.apiKeyEnvVars.joined(separator: " or ")
        return """
            Looked in the Keychain (app.donottype → \(provider.rawValue)) and in \(names). \
            An app opened from Finder or Login Items does not inherit your shell, so a key \
            exported in ~/.zshrc is invisible here — paste it above and it is stored in the \
            Keychain, where every launch can find it.
            """
    }
}
