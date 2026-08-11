import AVFoundation
import AppKit
import CommonCrypto
import DoNotTypeCore
import Foundation

/// A copyable description of everything needed to explain a failure.
///
/// Built because the first real failure of this app in someone else's hands produced
/// `HTTP 400: [{ "error": {…` in a two-line label, and neither of us could tell what was wrong.
/// Diagnosing it meant a shell, the source, and an afternoon. That is a fine debugging story for
/// the person who wrote the app and a terrible one for anybody else.
///
/// Everything here is chosen to answer a question that has actually come up: which key is it
/// using, is the model reachable, did permissions get revoked, is the encoder available, what
/// failed most recently. It is one button and one paste.
@MainActor
enum Diagnostics {
    /// A fingerprint of the API key — never the key.
    ///
    /// Length and a short hash are enough to answer "is the app using the key I think it is?",
    /// which is the only question anyone asks about it while debugging. The key itself has no
    /// business in a report meant to be pasted into an issue, and asking people to redact it
    /// themselves is a plan that fails once and permanently.
    static func fingerprint(_ key: String?) -> String {
        guard let key, !key.isEmpty else { return "none" }
        var hasher = SHA256Lite()
        hasher.update(key)
        return "\(key.count) chars, sha256:\(hasher.shortDigest)"
    }

    static func report(model: SettingsModel, history: [DictationRecord]) -> String {
        let settings = Settings.shared
        let bundle = Bundle.main
        let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "?"

        var lines: [String] = []
        func section(_ title: String) { lines.append("\n## \(title)") }
        func row(_ name: String, _ value: String) { lines.append("\(name): \(value)") }

        lines.append("# DoNotType diagnostics")
        row("generated", ISO8601DateFormatter().string(from: Date()))

        section("App")
        row("version", "\(version) (\(build))")
        row("bundle", bundle.bundleIdentifier ?? "?")
        row("macOS", ProcessInfo.processInfo.operatingSystemVersionString)
        row("architecture", architecture)

        section("Provider")
        row("service", settings.provider.rawValue)
        row("model", settings.model)
        row("fidelity", settings.fidelity.rawValue)
        row("key source", model.resolvedKeySource)
        row("key", fingerprint(settings.resolvedAPIKey()))
        row("last connection test", model.connectionStatus ?? "not run")

        section("Permissions")
        row("accessibility", AccessibilityReader.isTrusted ? "granted" : "NOT GRANTED")
        row("microphone", microphoneStatus)
        row("screen recording", CGPreflightScreenCaptureAccess() ? "granted" : "not granted")

        section("Audio")
        row("microphone setting", settings.microphoneUID ?? "system default")
        row("in use", model.activeMicrophoneName)
        row("opus encoder", OpusEncoder.isAvailable ? "available" : "UNAVAILABLE (uploads as WAV)")

        section("Grounding")
        row("enabled", settings.groundingEnabled ? "yes" : "no")
        row("screenshot fallback", settings.screenshotEnabled ? "yes" : "no")
        row("number check", settings.numberCheck.rawValue)
        row("blocked apps", "\(settings.blockedBundleIDs.count)")
        row("custom prompt", model.isPromptCustom ? "yes" : "no (using the bundled contract)")

        section("History")
        let failures = history.filter { $0.status != .completed }
        row("total", "\(history.count)")
        row("needing attention", "\(failures.count)")

        let stats = PerformanceStats.compute(from: history)
        row("median wait", PerformanceStats.formatDuration(stats.medianLatency))
        row("p95 wait", PerformanceStats.formatDuration(stats.p95Latency))
        row("succeeded", stats.successRate.map { "\(Int($0 * 100))%" } ?? "n/a")

        if !failures.isEmpty {
            section("Recent failures")
            // Newest five, with the whole message. Truncating here would reproduce the exact
            // problem this report exists to solve.
            for record in failures.prefix(5) {
                lines.append("- \(ISO8601DateFormatter().string(from: record.createdAt))")
                lines.append("  app: \(record.appName ?? "unknown")")
                lines.append("  status: \(record.status.rawValue), retries: \(record.retryCount)")
                lines.append("  error: \(record.errorMessage ?? "none recorded")")
            }
        }

        return lines.joined(separator: "\n")
    }

    /// Opens Console with this app's log stream.
    ///
    /// The app logs to `os.Logger`, which is invisible unless you know to look — and knowing to
    /// look means knowing the subsystem string. This is the one click that turns "nothing
    /// happened" into something readable.
    static func revealLogs() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Console"]
        try? process.run()
    }

    static func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Private

    private static var microphoneStatus: String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: "granted"
        case .denied: "DENIED"
        case .restricted: "restricted"
        case .notDetermined: "not yet requested"
        @unknown default: "unknown"
        }
    }

    private static var architecture: String {
        #if arch(arm64)
            "arm64"
        #elseif arch(x86_64)
            "x86_64"
        #else
            "unknown"
        #endif
    }
}

/// Just enough SHA-256 to fingerprint a key without importing CryptoKit into a file that only
/// needs twelve hex characters.
private struct SHA256Lite {
    private var data = Data()

    mutating func update(_ string: String) { data.append(contentsOf: Array(string.utf8)) }

    var shortDigest: String {
        var hash = [UInt8](repeating: 0, count: 32)
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(buffer.count), &hash)
        }
        return hash.prefix(6).map { String(format: "%02x", $0) }.joined()
    }
}
