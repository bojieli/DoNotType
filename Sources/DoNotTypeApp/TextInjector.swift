import AppKit
import ApplicationServices
import CoreGraphics
import DoNotTypeCore

/// Puts the transcript into whatever the user was typing in.
///
/// Pasteboard save → ⌘V → restore, which is what Typeless does and what every tool in this
/// category converges on. Setting `AXValue` directly is cleaner in principle and fails on too many
/// real apps to be the primary path — Electron, Java, terminals and anything canvas-drawn.
///
/// The clipboard is borrowed, not taken: every representation of every item is archived first and
/// put back afterwards, so a user's copied image or rich text survives a dictation.
@MainActor
enum TextInjector {
    private static let log = Log("inject")

    /// How long to let the target app read the pasteboard before restoring it.
    ///
    /// Restoring too eagerly races the paste and the user gets their old clipboard inserted
    /// instead of the transcript.
    private static let restoreDelay: Duration = .milliseconds(220)

    static func insert(_ text: String, dictation: String = "-") async {
        guard !text.isEmpty else { return }

        // Logged because "it transcribed but nothing appeared" is a distinct failure from "it did
        // not transcribe", and from the outside they look the same. Accessibility being off is the
        // usual cause and produces no error at all: the keystroke is simply never delivered.
        let trusted = AXIsProcessTrusted()
        let target = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        log.info(
            "inserting",
            [
                "dictation": dictation, "chars": "\(text.count)", "app": target,
                "accessibility": trusted ? "granted" : "MISSING",
            ])
        if !trusted {
            log.error(
                "cannot insert: Accessibility permission is not granted",
                ["dictation": dictation, "app": target])
        }

        let pasteboard = NSPasteboard.general
        let archive = archiveContents(of: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        simulatePaste()

        try? await Task.sleep(for: restoreDelay)
        restore(archive, to: pasteboard)
        log.debug("clipboard restored", ["dictation": dictation])
    }

    /// Puts the transcript on the clipboard and leaves it there.
    ///
    /// For the case where the paste cannot happen — Accessibility revoked, which macOS does on
    /// every signature change. The words have been recorded, sent and paid for by that point, and
    /// the difference between "press ⌘V" and "nothing happened" is the difference between a
    /// permission to fix and an app that looks broken.
    static func copyForManualPaste(_ text: String, dictation: String = "-") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        log.info(
            "left on the clipboard for a manual paste",
            ["dictation": dictation, "chars": "\(text.count)"])
    }

    // MARK: - Private

    /// Every type of every item, so non-text clipboard contents survive.
    private static func archiveContents(of pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            var representations: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { representations[type] = data }
            }
            return representations
        }
    }

    private static func restore(
        _ archive: [[NSPasteboard.PasteboardType: Data]], to pasteboard: NSPasteboard
    ) {
        pasteboard.clearContents()
        guard !archive.isEmpty else { return }

        let items = archive.map { representations -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in representations { item.setData(data, forType: type) }
            return item
        }
        pasteboard.writeObjects(items)
    }

    /// Removes `count` characters before the caret.
    ///
    /// Simulated backspaces rather than setting the field's value: the target is an arbitrary app
    /// and most do not expose a settable value, which is the same reason insertion goes through
    /// the pasteboard. Batched with a small gap because some apps drop synthetic keys sent faster
    /// than a person could type.
    static func deleteBackward(count: Int) async {
        guard count > 0, let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let backspace: CGKeyCode = 51

        for index in 0..<count {
            CGEvent(keyboardEventSource: source, virtualKey: backspace, keyDown: true)?
                .post(tap: .cgAnnotatedSessionEventTap)
            CGEvent(keyboardEventSource: source, virtualKey: backspace, keyDown: false)?
                .post(tap: .cgAnnotatedSessionEventTap)

            // Every few keystrokes, yield briefly. Without this a long transcript floods the
            // target app's event queue and some of the deletions are silently dropped.
            if index % 16 == 15 { try? await Task.sleep(for: .milliseconds(8)) }
        }
    }

    private static func simulatePaste() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            log.error("could not create an event source for ⌘V")
            return
        }
        // Suppress our own synthetic keystrokes from re-entering the app's own event tap.
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents], state: .eventSuppressionStateSuppressionInterval)

        let v: CGKeyCode = 9
        let down = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)
    }
}
