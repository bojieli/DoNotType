import AVFoundation
import AppKit
import ApplicationServices
import DoNotTypeCore

/// Checks a permission at the moment it is about to be used, and points at the pane that grants it.
///
/// The onboarding sheet already lists all of this, but onboarding happens once and permissions are
/// revoked later — macOS drops Accessibility every time the signature changes, which is every
/// update. What was left was the worst kind of failure: the hotkey works, the recording runs, the
/// transcript comes back, and the paste goes nowhere, because a keystroke sent without
/// Accessibility is not refused, it is ignored. Nothing anywhere says so.
///
/// So the check happens where the thing is used, not only at launch, and it opens the exact pane
/// rather than describing where it is.
@MainActor
enum PermissionGuide {
    struct Missing {
        /// One line for the overlay, which is all there is room for.
        let message: String
        let settingsURL: String
        /// For the log, where there is room to say why it matters.
        let detail: String
    }

    /// Nil when recording can go ahead.
    static func microphone() -> Missing? {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return nil
        case .notDetermined:
            // The system prompt has never been shown. Asking is the guidance.
            return nil
        default:
            return Missing(
                message: "Microphone access is off. Opening System Settings…",
                settingsURL:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
                detail: "recording would capture silence, and the transcript would be empty")
        }
    }

    /// Nil when a transcript can actually be pasted.
    static func accessibility() -> Missing? {
        guard !AXIsProcessTrusted() else { return nil }
        return Missing(
            message: "Accessibility is off, so the text cannot be pasted.",
            settingsURL:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            detail: "the paste keystroke is ignored rather than refused, so the transcript would "
                + "be produced, billed and then dropped")
    }

    /// Opens the pane, at most once per permission per run.
    ///
    /// Once, because somebody who has decided not to grant it should not have System Settings
    /// thrown at them on every keypress — and because the second time it opens, it is no longer
    /// guidance, it is an argument.
    static func present(_ missing: Missing) {
        log.error(
            "a required permission is not granted",
            ["permission": missing.settingsURL, "consequence": missing.detail])

        guard !opened.contains(missing.settingsURL) else { return }
        opened.insert(missing.settingsURL)
        guard let url = URL(string: missing.settingsURL) else { return }
        NSWorkspace.shared.open(url)
    }

    private static var opened: Set<String> = []
    private static let log = Log("permission")
}
