import AppKit
import DoNotTypeCore
import Foundation

/// Runs the two-phase capture that makes grounding free.
///
/// Phase 1 is synchronous at hotkey-down and reads only what is cheap — app identity and cursor
/// state. It has to happen before recording starts, because it is the last moment the focused
/// element is guaranteed to still be the one the user is dictating into.
///
/// Phase 2 is the expensive walk plus, if needed, a screenshot. It is fired without being awaited
/// and lands while the user is still speaking. By the time they release the key it has almost
/// always finished; if it has not, the dictation goes out with phase 1 only rather than waiting.
@MainActor
final class GroundingCoordinator {
    private let log = Log("grounding")

    private var identity: ScreenContext?
    private var fullCapture: Task<ScreenContext?, Never>?
    private(set) var lastDecision: PrivacyGate.Decision = .allowed

    func beginCapture() {
        guard Settings.shared.groundingEnabled else {
            identity = nil
            return
        }

        let decision = PrivacyGate.evaluateFrontmost()
        lastDecision = decision
        guard decision.isAllowed else {
            log.info("grounding skipped: \(decision.reason ?? "blocked")")
            identity = nil
            return
        }

        let snapshot = AccessibilityReader.captureIdentity()
        identity = snapshot

        let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let wantsScreenshot = Settings.shared.screenshotEnabled
        fullCapture = Task { [log] in
            var context = await AccessibilityReader.captureFull()

            // The URL is only known after the walk, so the blocklist gets a second look — a
            // password page inside an allowed browser must still be excluded.
            if let url = context.browserURL {
                let recheck = await MainActor.run {
                    PrivacyGate.evaluate(
                        bundleID: bundleID, appName: context.appName, url: url)
                }
                if !recheck.isAllowed {
                    log.info("grounding dropped after URL check: \(recheck.reason ?? "blocked")")
                    return nil
                }
            }

            // The screenshot exists for surfaces the accessibility tree cannot describe —
            // canvas apps, GPU-rendered terminals, PDFs. It is not a companion to good AX text.
            if wantsScreenshot, context.isAccessibilityThin() {
                context.screenshotPNG = await ScreenCapturer.captureFocusedWindow(
                    ofBundleID: bundleID)
            }
            return context
        }
    }

    /// Merges the two phases. Phase 1's cursor state wins, because it was taken before focus
    /// could move.
    ///
    /// Awaiting here is nearly always free: phase 2 carries its own 500 ms deadline and has
    /// normally finished while the user was still speaking. In the worst case a dictation waits
    /// out the remainder of that deadline rather than shipping ungrounded.
    func finishCapture() async -> ScreenContext? {
        let task = fullCapture
        let snapshot = identity
        identity = nil
        fullCapture = nil

        guard let snapshot else {
            task?.cancel()
            return nil
        }
        guard let task else { return snapshot }
        let captured = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        guard !Task.isCancelled, var merged = captured else { return snapshot }

        merged.selectedText = snapshot.selectedText ?? merged.selectedText
        merged.role = snapshot.role ?? merged.role
        merged.isEditable = snapshot.isEditable ?? merged.isEditable
        merged.appName = snapshot.appName ?? merged.appName
        merged.windowTitle = snapshot.windowTitle ?? merged.windowTitle
        return merged
    }

    func cancel() {
        fullCapture?.cancel()
        fullCapture = nil
        identity = nil
    }
}
