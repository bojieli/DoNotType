import AppKit
import DoNotTypeCore
import Foundation
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?

    private let store = HistoryStore(directory: HistoryStore.defaultDirectory())
    private lazy var dictation = DictationController(store: store)
    private lazy var settingsModel = SettingsModel(store: store)

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setIcon(for: .idle)

        settingsModel.onHotkeyChange = { [weak self] in self?.dictation.reloadHotkey() }
        dictation.onStateChange = { [weak self] state in
            self?.setIcon(for: state)
            self?.rebuildMenu()
        }
        dictation.onHistoryChange = { [weak self] in
            guard let self else { return }
            Task { await settingsModel.refresh() }
            rebuildMenu()
        }
        rebuildMenu()

        Task { await requestPermissionsAndStart() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        dictation.stop()
    }

    // MARK: - Startup

    private func requestPermissionsAndStart() async {
        // Asked one at a time, at the moment each is first needed. Never all three at onboarding.
        if !AccessibilityReader.isTrusted {
            AccessibilityReader.requestTrust()
            alert(
                "Accessibility access required",
                """
                DoNotType needs Accessibility access for two things: to notice your hotkey, and to \
                paste the transcript where you were typing.

                Grant it in System Settings › Privacy & Security › Accessibility, then relaunch.
                """)
            return
        }

        guard await AudioRecorder.requestAccess() else {
            alert(
                "Microphone access required",
                "Grant it in System Settings › Privacy & Security › Microphone, then relaunch.")
            return
        }

        guard dictation.start() else {
            alert(
                "Could not install the hotkey",
                "The system refused to create an event tap. This usually means Accessibility "
                    + "access was revoked. Re-grant it and relaunch.")
            return
        }

        await settingsModel.refresh()

        if Settings.shared.resolvedAPIKey() == nil {
            openSettings()
        } else {
            // Anything that failed while the machine was offline goes out now.
            await dictation.retryPending()
        }
    }

    // MARK: - Menu bar

    private func setIcon(for state: DictationController.State) {
        guard let button = statusItem.button else { return }
        let name: String
        switch state {
        case .idle: name = "mic"
        case .recording: name = "mic.fill"
        case .transcribing: name = "waveform"
        case .failed: name = "exclamationmark.triangle"
        }
        button.image = NSImage(systemSymbolName: name, accessibilityDescription: "DoNotType")
        button.image?.isTemplate = true
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        switch dictation.state {
        case .idle:
            menu.addItem(disabled("Hold \(Settings.shared.trigger.label) to dictate"))
        case .recording:
            menu.addItem(disabled("Recording… release to transcribe"))
        case .transcribing:
            menu.addItem(disabled("Transcribing…"))
        case .failed(let message):
            menu.addItem(disabled(String(message.prefix(70))))
        }

        let pending = settingsModel.retryableCount
        if pending > 0 {
            menu.addItem(.separator())
            let retry = NSMenuItem(
                title: "Retry \(pending) failed dictation\(pending == 1 ? "" : "s")",
                action: #selector(retryAll), keyEquivalent: "")
            retry.target = self
            menu.addItem(retry)
        }

        menu.addItem(.separator())
        if let latest = settingsModel.records.first(where: { $0.status == .completed }) {
            menu.addItem(disabled(String(latest.text.prefix(60))))
            let copy = NSMenuItem(
                title: "Copy last transcript", action: #selector(copyLast), keyEquivalent: "c")
            copy.target = self
            menu.addItem(copy)
        }

        menu.addItem(.separator())
        let settings = NSMenuItem(
            title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let quit = NSMenuItem(title: "Quit DoNotType", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: - Actions

    @objc private func openSettings() {
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 520),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "DoNotType Settings"
        window.contentView = NSHostingView(rootView: SettingsView(model: settingsModel))
        window.center()
        window.isReleasedWhenClosed = false
        settingsWindow = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func retryAll() {
        Task {
            await settingsModel.retryAll()
            rebuildMenu()
        }
    }

    @objc private func copyLast() {
        guard let latest = settingsModel.records.first(where: { $0.status == .completed }) else {
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(latest.text, forType: .string)
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func alert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}
