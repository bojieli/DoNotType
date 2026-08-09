import AppKit
import DoNotTypeCore
import Foundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let dictation = DictationController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setIcon(for: .idle)

        dictation.onStateChange = { [weak self] state in
            self?.setIcon(for: state)
            self?.rebuildMenu()
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

        if Settings.shared.resolvedAPIKey() == nil {
            alert(
                "Add your API key",
                """
                DoNotType calls the model with your own key, so nothing routes through a server \
                of ours.

                Set \(Settings.shared.provider.apiKeyEnvVar) in your environment, or add a key \
                from the menu bar item.
                """)
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
        button.image = NSImage(
            systemSymbolName: name, accessibilityDescription: "DoNotType")
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
            menu.addItem(disabled("Error: \(message)"))
        }
        menu.addItem(.separator())

        let fidelity = NSMenu()
        for value in Fidelity.allCases {
            let item = NSMenuItem(
                title: describe(value), action: #selector(setFidelity(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value.rawValue
            item.state = Settings.shared.fidelity == value ? .on : .off
            fidelity.addItem(item)
        }
        let fidelityItem = NSMenuItem(title: "Fidelity", action: nil, keyEquivalent: "")
        fidelityItem.submenu = fidelity
        menu.addItem(fidelityItem)

        let grounding = NSMenuItem(
            title: "Ground in screen context", action: #selector(toggleGrounding),
            keyEquivalent: "")
        grounding.target = self
        grounding.state = Settings.shared.groundingEnabled ? .on : .off
        menu.addItem(grounding)

        menu.addItem(.separator())
        if let latest = dictation.recentHistory.first {
            menu.addItem(disabled(String(latest.text.prefix(60))))
            let copy = NSMenuItem(
                title: "Copy last transcript", action: #selector(copyLast), keyEquivalent: "")
            copy.target = self
            menu.addItem(copy)
            menu.addItem(.separator())
        }

        let quit = NSMenuItem(title: "Quit DoNotType", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    private func describe(_ fidelity: Fidelity) -> String {
        switch fidelity {
        case .raw: "Raw — every um and false start"
        case .light: "Light — drop fillers, keep your words"
        case .tidy: "Tidy — light, plus punctuation"
        }
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: - Actions

    @objc private func setFidelity(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
            let fidelity = Fidelity(rawValue: raw)
        else { return }
        Settings.shared.fidelity = fidelity
        rebuildMenu()
    }

    @objc private func toggleGrounding() {
        Settings.shared.groundingEnabled.toggle()
        rebuildMenu()
    }

    @objc private func copyLast() {
        guard let latest = dictation.recentHistory.first else { return }
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
