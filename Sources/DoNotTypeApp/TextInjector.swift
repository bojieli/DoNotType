import AppKit
import CoreGraphics
import os

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
    private static let log = Logger(subsystem: "ai.19pine.donottype", category: "inject")

    /// How long to let the target app read the pasteboard before restoring it.
    ///
    /// Restoring too eagerly races the paste and the user gets their old clipboard inserted
    /// instead of the transcript.
    private static let restoreDelay: Duration = .milliseconds(220)

    static func insert(_ text: String) async {
        guard !text.isEmpty else { return }

        let pasteboard = NSPasteboard.general
        let archive = archiveContents(of: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        simulatePaste()

        try? await Task.sleep(for: restoreDelay)
        restore(archive, to: pasteboard)
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
