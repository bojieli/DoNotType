import AVFoundation
import AppKit
import DoNotTypeCore
import Foundation
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var permissionsWindow: NSWindow?
    private var fileWindow: NSWindow?

    private let store = HistoryStore(directory: HistoryStore.defaultDirectory())
    private let permissions = PermissionsModel()
    private lazy var dictation = DictationController(store: store)
    private lazy var settingsModel = SettingsModel(store: store)
    private lazy var fileTranscription = FileTranscriptionModel(store: store)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Before anything else: a crash during startup is exactly the case where the log has to
        // already exist, and every key is registered for redaction here.
        Settings.shared.startLogging()

        // An invisible menu bar, purely so ⌘V reaches the key field. See `MainMenu`.
        NSApp.mainMenu = MainMenu.make()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setIcon(for: .idle)

        settingsModel.onHotkeyChange = { [weak self] in self?.dictation.reloadHotkey() }
        settingsModel.onHotkeyCaptureChange = { [weak self] active in
            self?.dictation.setHotkeyCaptureActive(active) ?? false
        }
        settingsModel.onKeyStatusChange = { [weak self] in self?.rebuildMenu() }
        dictation.onStateChange = { [weak self] state in
            self?.setIcon(for: state)
            self?.rebuildMenu()
        }
        dictation.onHistoryChange = { [weak self] in
            guard let self else { return }
            Task { await settingsModel.refresh() }
            rebuildMenu()
        }
        dictation.onDictionaryChange = { [weak self] _ in
            guard let self else { return }
            settingsModel.refreshDictionary()
            rebuildMenu()
        }
        rebuildMenu()

        Task { await requestPermissionsAndStart() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        dictation.stop()
        // The file sink buffers through a `FileHandle`; without this the last few lines before a
        // quit — which are usually the interesting ones — never reach the disk.
        Log("app").info("terminating")
        LogRouter.shared.flush()
    }

    // MARK: - Startup

    /// Re-checked at every launch, not just the first: macOS revokes Accessibility whenever an
    /// app's signature changes, and people turn things off in System Settings without connecting
    /// that to the app going quiet.
    private func requestPermissionsAndStart() async {
        permissions.refresh()

        // The microphone is the one permission with a real system prompt left, so ask for it
        // inline before falling back to the walkthrough.
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AudioRecorder.requestAccess()
            permissions.refresh()
        }

        guard permissions.allRequiredGranted else {
            openPermissions()
            return
        }
        await startDictating()
    }

    private func startDictating() async {
        guard dictation.start() else {
            permissions.refresh()
            openPermissions()
            return
        }

        // Immediately after the hotkey is live, because the window between the two is exactly when
        // an eager user presses the key for the first time.
        dictation.warmUpAudio()

        await settingsModel.refresh()
        rebuildMenu()

        // Asked here rather than at the end of the first dictation. A key that is absent or
        // rejected is a setting, and finding out about it while a recording is in flight costs a
        // sentence the user has already spoken.
        await settingsModel.checkConnection()
        if settingsModel.keyStatus.needsAttention {
            openSettings()
        } else {
            // Anything that failed while the machine was offline goes out now.
            await dictation.retryPending()
        }
    }

    @objc private func openPermissions() {
        permissions.refresh()

        if let permissionsWindow {
            permissionsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 520),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "DoNotType Setup"
        window.contentView = NSHostingView(
            rootView: PermissionsView(model: permissions) { [weak self] in
                guard let self else { return }
                permissionsWindow?.close()
                Task { await self.startDictating() }
            })
        window.center()
        window.isReleasedWhenClosed = false
        permissionsWindow = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Menu bar

    /// The app mark, in the three states it has something to say about. Failure keeps the system
    /// warning glyph on purpose: an error is the one moment where being instantly recognisable
    /// matters more than being on brand.
    private func setIcon(for state: DictationController.State) {
        guard let button = statusItem.button else { return }
        let image: NSImage?
        switch state {
        case .idle: image = Self.statusImage("StatusIdle", fallback: "mic")
        case .recording: image = Self.statusImage("StatusRecording", fallback: "mic.fill")
        case .transcribing: image = Self.statusImage("StatusTranscribing", fallback: "waveform")
        case .failed:
            image = NSImage(systemSymbolName: "exclamationmark.triangle",
                            accessibilityDescription: "DoNotType")
        }
        image?.isTemplate = true
        button.image = image
    }

    /// Menu-bar art ships as an 18pt PNG and its 2x twin, assembled here into one image with two
    /// representations so AppKit picks the right one for the display it lands on. Both reps are
    /// declared 18pt: that is what marks the 36px bitmap as the 2x variant rather than as a
    /// separate, larger image.
    ///
    /// The SF Symbol fallback is for `swift run`, which produces a bare executable with no bundle
    /// to load resources from -- a missing image there would leave an invisible status item rather
    /// than an obviously broken one.
    private static func statusImage(_ name: String, fallback: String) -> NSImage? {
        let size = NSSize(width: 18, height: 18)
        let reps = [name, "\(name)@2x"].compactMap { file -> NSImageRep? in
            guard let url = Bundle.main.url(forResource: file, withExtension: "png") else {
                return nil
            }
            let rep = NSImageRep(contentsOf: url)
            rep?.size = size
            return rep
        }
        guard !reps.isEmpty else {
            return NSImage(systemSymbolName: fallback, accessibilityDescription: "DoNotType")
        }
        let image = NSImage(size: size)
        reps.forEach(image.addRepresentation)
        image.accessibilityDescription = "DoNotType"
        return image
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

        // Above everything else, because nothing below it can work until this is fixed, and the
        // menu bar is the only surface a user sees without opening a window.
        if let keyProblem = settingsModel.keyStatus.menuTitle(provider: settingsModel.provider) {
            menu.addItem(.separator())
            let item = NSMenuItem(
                title: keyProblem, action: #selector(openSettings), keyEquivalent: "")
            item.image = NSImage(
                systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
            item.target = self
            menu.addItem(item)
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

        if dictation.canUndo {
            menu.addItem(.separator())
            let undo = NSMenuItem(
                title: "Undo last insertion", action: #selector(undoInsertion), keyEquivalent: "z")
            undo.keyEquivalentModifierMask = [.command, .shift]
            undo.target = self
            menu.addItem(undo)

            if dictation.canRevertToVerbatim {
                let revert = NSMenuItem(
                    title: "Revert to what you said", action: #selector(revertToVerbatim),
                    keyEquivalent: "z")
                revert.keyEquivalentModifierMask = [.command, .option]
                revert.target = self
                menu.addItem(revert)
            }
        }

        if dictation.canUndoDictionaryLearning {
            let learned = NSMenuItem(
                title: "Undo last learned spelling",
                action: #selector(undoDictionaryLearning), keyEquivalent: "")
            learned.target = self
            menu.addItem(learned)
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
        // Above Settings because it is a thing to do, not a thing to configure — and because a
        // recording already on disk is the one case the hotkey cannot serve at all.
        let transcribeFile = NSMenuItem(
            title: "Transcribe a Recording…", action: #selector(openFileTranscription),
            keyEquivalent: "o")
        transcribeFile.target = self
        menu.addItem(transcribeFile)

        if !permissions.allRequiredGranted {
            let setup = NSMenuItem(
                title: "Finish setup…", action: #selector(openPermissions), keyEquivalent: "")
            setup.target = self
            menu.addItem(setup)
        }

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
            // The window is cached rather than released on close, which is what keeps the sidebar
            // where it was left — and AppKit restores the first responder along with it. So one
            // click in the Model field, weeks ago, made every later ⌘, put the caret back there,
            // in a field that saves as you type. Reopening a settings window is not typing into
            // it, so it starts with the caret nowhere.
            settingsWindow.makeFirstResponder(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // These two numbers used to be measurements of the tab bar: how much width nine tabs
        // needed before they collapsed into one `»` chevron. The navigation is a sidebar now and
        // cannot run out of room, so they measure the panels instead — and the panels are what
        // they should always have been measuring.
        //
        // The sidebar costs about 180pt off the top of every panel, so the window gets wider
        // rather than the panels getting narrower: at 980 the content keeps the ~800pt it had
        // under the tab bar. That matters because three panels have no slack at that width —
        // Transfer's buttons, History's toolbar, and Stats' four tiles, whose text is already
        // capped at minimumScaleFactor(0.8). The minimum leaves the widest of them intact.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "DoNotType Settings"
        window.contentMinSize = NSSize(width: 880, height: 520)
        window.contentView = NSHostingView(rootView: SettingsView(model: settingsModel))
        window.center()
        window.isReleasedWhenClosed = false
        settingsWindow = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func undoDictionaryLearning() {
        dictation.undoLastDictionaryLearning()
    }

    /// The offline path: transcribe, rewrite or summarise a recording that already exists.
    @objc private func openFileTranscription() {
        if let fileWindow {
            fileWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Transcribe a Recording"
        window.contentView = NSHostingView(
            rootView: FileTranscriptionView(model: fileTranscription))
        window.center()
        window.isReleasedWhenClosed = false
        fileWindow = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func retryAll() {
        Task {
            await settingsModel.retryAll()
            rebuildMenu()
        }
    }

    @objc private func undoInsertion() {
        Task { await dictation.undoLastInsertion(revertToVerbatim: false); rebuildMenu() }
    }

    @objc private func revertToVerbatim() {
        Task { await dictation.undoLastInsertion(revertToVerbatim: true); rebuildMenu() }
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
