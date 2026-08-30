import DoNotTypeCore
import Darwin
import ObjectiveC.runtime
import UIKit

/// DoNotType's voice keyboard.
///
/// iOS reserves microphone capture for the containing app. A cold press opens that app and starts
/// capture there; while its background audio session is warm, subsequent presses travel over the
/// App Group/Darwin bridge and never leave the current text field. The keyboard owns the gesture,
/// live state, and insertion. The app owns the exact same recorder and provider pipeline used by
/// its main screen.
final class KeyboardViewController: UIInputViewController {

    private let store = TranscriptStore()
    private let voiceBridge = VoiceKeyboardBridge()
    private let dictionaryStore = DictionaryStore()
    private let correctionStore = CorrectionObservationStore()
    private var entries: [TranscriptStore.Entry] = []
    private var correctionTask: Task<Void, Never>?
    private var launchFallback: DispatchWorkItem?
    private var pressStartedAt: Date?
    private var pressStartedRecording = false
    private var stopWhenRecordingStarts = false
    private var lastLearnedTerms: [String] = []
    private var transientStatus: String?
    private var backspaceRepeatDelay: DispatchWorkItem?
    private var backspaceRepeatTimer: Timer?
    private var isBackspaceHeld = false
    /// Darwin notifications can reach this controller after Notes has hidden its keyboard. Its
    /// `textDocumentProxy` still exists then, but inserting through it is a no-op. Never consume a
    /// result until UIKit has attached this keyboard to a visible document again.
    private var isKeyboardVisible = false

    /// UIKit can ask this before loading the extension's view. Keep the early answer truthful and
    /// still forward writes to the superclass so its remote keyboard output is updated.
    override var hasDictationKey: Bool {
        get { true }
        set { super.hasDictationKey = newValue }
    }

    private lazy var appLauncher = KeyboardContainingAppLauncher { [weak self] in self }
    private lazy var statusLabel = UILabel()
    private lazy var modeButton = UIButton(type: .system)
    private lazy var dictateButton = UIButton(type: .system)
    private lazy var cancelButton = UIButton(type: .system)
    private lazy var settingsButton = UIButton(type: .system)
    private lazy var returnButton = UIButton(type: .system)
    private lazy var backspaceButton = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        // The setter means "this extension has its own dictation key" and sends that fact to the
        // remote keyboard host, suppressing the system-owned microphone in the bottom chrome.
        super.hasDictationKey = true
        buildInterface()

        VoiceKeyboardBridge.observeUpdates {
            Task { @MainActor [weak self] in self?.reload() }
        }
        TranscriptStore.observeUpdates {
            Task { @MainActor [weak self] in self?.reload() }
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // The remote keyboard interface can be rebuilt while this extension process stays alive.
        // Re-publish the capability whenever UIKit attaches us to a document.
        super.hasDictationKey = true
        voiceBridge.publishKeyboardSetupStatus(hasFullAccess: hasFullAccess)
        reload()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isKeyboardVisible = true
        // A cold dictation normally finishes while this extension is not running. The result is
        // deliberately still pending in the App Group, and is consumed only after UIKit has
        // restored the original document proxy.
        reload()
        observePendingCorrection()
    }

    override func viewWillDisappear(_ animated: Bool) {
        isKeyboardVisible = false
        correctionTask?.cancel()
        correctionTask = nil
        launchFallback?.cancel()
        launchFallback = nil
        stopWhenRecordingStarts = false
        stopBackspaceRepeat()
        super.viewWillDisappear(animated)
    }

    // MARK: - Interface

    private func buildInterface() {
        view.backgroundColor = .secondarySystemBackground

        statusLabel.font = .preferredFont(forTextStyle: .callout)
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 2
        statusLabel.textAlignment = .center
        statusLabel.accessibilityIdentifier = "kb-status"
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.isUserInteractionEnabled = true
        statusLabel.addGestureRecognizer(
            UITapGestureRecognizer(target: self, action: #selector(statusTapped)))

        modeButton.accessibilityIdentifier = "kb-dictation-mode"
        modeButton.titleLabel?.numberOfLines = 1
        modeButton.titleLabel?.lineBreakMode = .byClipping
        modeButton.addTarget(self, action: #selector(toggleMode), for: .touchUpInside)
        modeButton.translatesAutoresizingMaskIntoConstraints = false

        dictateButton.accessibilityIdentifier = "kb-dictate"
        dictateButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        dictateButton.tintColor = .white
        dictateButton.layer.cornerRadius = 29
        dictateButton.clipsToBounds = true
        dictateButton.translatesAutoresizingMaskIntoConstraints = false
        dictateButton.addTarget(self, action: #selector(dictateTouchDown), for: .touchDown)
        dictateButton.addTarget(
            self, action: #selector(dictateTouchUp), for: [.touchUpInside, .touchUpOutside])

        cancelButton.setTitle("Cancel", for: .normal)
        cancelButton.setTitleColor(.systemRed, for: .normal)
        cancelButton.titleLabel?.font = .preferredFont(forTextStyle: .callout)
        cancelButton.accessibilityIdentifier = "kb-cancel"
        cancelButton.addTarget(self, action: #selector(cancelDictation), for: .touchUpInside)
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.isHidden = true

        settingsButton.setImage(UIImage(systemName: "gearshape"), for: .normal)
        settingsButton.accessibilityIdentifier = "kb-settings"
        settingsButton.accessibilityLabel = "Settings"
        settingsButton.backgroundColor = .tertiarySystemFill
        settingsButton.layer.cornerRadius = 10
        settingsButton.addTarget(self, action: #selector(openSettings), for: .touchUpInside)
        settingsButton.translatesAutoresizingMaskIntoConstraints = false

        returnButton.setImage(UIImage(systemName: "return"), for: .normal)
        returnButton.accessibilityIdentifier = "kb-return"
        returnButton.accessibilityLabel = "Return"
        returnButton.backgroundColor = .tertiarySystemFill
        returnButton.layer.cornerRadius = 10
        returnButton.addTarget(self, action: #selector(insertReturn), for: .touchUpInside)
        returnButton.translatesAutoresizingMaskIntoConstraints = false

        backspaceButton.setImage(UIImage(systemName: "delete.left"), for: .normal)
        backspaceButton.accessibilityIdentifier = "kb-backspace"
        backspaceButton.accessibilityLabel = "Delete"
        backspaceButton.backgroundColor = .tertiarySystemFill
        backspaceButton.layer.cornerRadius = 10
        backspaceButton.addTarget(self, action: #selector(startBackspacePress), for: .touchDown)
        backspaceButton.addTarget(
            self, action: #selector(finishBackspacePress), for: .touchUpInside)
        backspaceButton.addTarget(
            self, action: #selector(cancelBackspacePress),
            for: [.touchUpOutside, .touchCancel, .touchDragExit])
        backspaceButton.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(statusLabel)
        view.addSubview(dictateButton)
        view.addSubview(cancelButton)
        view.addSubview(settingsButton)
        view.addSubview(modeButton)
        view.addSubview(returnButton)
        view.addSubview(backspaceButton)

        NSLayoutConstraint.activate([
            view.heightAnchor.constraint(equalToConstant: 170),

            statusLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 5),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            statusLabel.heightAnchor.constraint(equalToConstant: 30),

            dictateButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            dictateButton.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 4),
            dictateButton.widthAnchor.constraint(equalToConstant: 170),
            dictateButton.heightAnchor.constraint(equalToConstant: 58),

            cancelButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            cancelButton.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            cancelButton.widthAnchor.constraint(equalToConstant: 58),
            cancelButton.heightAnchor.constraint(equalToConstant: 30),

            settingsButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            settingsButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -7),
            settingsButton.widthAnchor.constraint(equalToConstant: 38),
            settingsButton.heightAnchor.constraint(equalToConstant: 38),

            modeButton.leadingAnchor.constraint(equalTo: settingsButton.trailingAnchor, constant: 7),
            modeButton.centerYAnchor.constraint(equalTo: settingsButton.centerYAnchor),
            modeButton.widthAnchor.constraint(equalToConstant: 86),
            modeButton.heightAnchor.constraint(equalToConstant: 34),

            returnButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            returnButton.centerYAnchor.constraint(equalTo: settingsButton.centerYAnchor),
            returnButton.widthAnchor.constraint(equalToConstant: 84),
            returnButton.heightAnchor.constraint(equalToConstant: 38),

            backspaceButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            backspaceButton.centerYAnchor.constraint(equalTo: settingsButton.centerYAnchor),
            backspaceButton.widthAnchor.constraint(equalToConstant: 52),
            backspaceButton.heightAnchor.constraint(equalToConstant: 38),
        ])
    }

    private func reload() {
        entries = store.load()

        guard hasFullAccess else {
            statusLabel.text =
                "Turn on Full Access in Settings › General › Keyboard › Keyboards › "
                + "DoNotType."
            dictateButton.isEnabled = false
            renderButton(phase: .idle, sessionWarm: false)
            return
        }
        guard TranscriptStore.containerURL != nil else {
            statusLabel.text = "The shared App Group is missing from this build."
            dictateButton.isEnabled = false
            renderButton(phase: .idle, sessionWarm: false)
            return
        }

        dictateButton.isEnabled = true
        let snapshot = voiceBridge.snapshot

        if isKeyboardVisible, view.window != nil,
            snapshot.phase == .idle, let result = snapshot.result, !result.isEmpty
        {
            insert(result)
            voiceBridge.acknowledgeResult()
            transientStatus = "Inserted"
        }

        var current = voiceBridge.snapshot
        // Audio-session activation can take longer than the hold. Preserve push-to-talk semantics
        // without turning `waiting` into `transcribing` before the app has actually opened its
        // recorder. A cold launch dismisses this keyboard and deliberately falls back to toggle.
        if current.phase == .recording, stopWhenRecordingStarts {
            stopWhenRecordingStarts = false
            voiceBridge.requestStop()
            current = voiceBridge.snapshot
        }
        switch current.phase {
        case .idle:
            statusLabel.text = transientStatus ?? idleCallToAction
        case .waiting:
            statusLabel.text = voiceBridge.isSessionWarm
                ? "Starting dictation…" : "Opening DoNotType to activate the microphone…"
        case .recording:
            statusLabel.text = "Listening… tap to stop"
        case .transcribing:
            statusLabel.text = "Transcribing…"
        case .failed:
            statusLabel.text = current.message ?? "Dictation failed — tap to try again"
        }
        renderButton(phase: current.phase, sessionWarm: voiceBridge.isSessionWarm)
    }

    private func renderButton(phase: VoiceKeyboardBridge.Phase, sessionWarm: Bool) {
        let symbol: String
        let title: String
        let background: UIColor
        switch phase {
        case .recording:
            symbol = "stop.fill"
            title = " Stop"
            background = .systemRed
        case .waiting:
            symbol = "ellipsis"
            title = " Starting"
            background = .systemGray
        case .transcribing:
            symbol = "ellipsis"
            title = " Transcribing"
            background = .systemGray
        case .idle, .failed:
            symbol = sessionWarm ? "mic.fill" : "mic"
            title = " Speak"
            background = .systemBlue
        }

        dictateButton.setImage(
            UIImage(systemName: symbol)?.applyingSymbolConfiguration(
                .init(pointSize: 22, weight: .semibold)),
            for: .normal)
        dictateButton.setTitle(title, for: .normal)
        dictateButton.backgroundColor = background
        renderModeButton(
            canChange: phase == .idle || phase == .failed || phase == .recording)
        // Also while recording. Stop and Discard are different things — one pays for the words
        // and one throws them away — and until now the second was reachable only by letting the
        // recording finish and deleting what it typed.
        cancelButton.isHidden = phase == .idle || phase == .failed
        // The button is 58pt wide and says "Cancel" in every state; which of the two it is lives
        // in the accessibility label, in the same words the app's own screen prints on its button.
        cancelButton.accessibilityLabel =
            phase == .recording ? "Discard recording" : "Cancel transcription"
        switch phase {
        case .waiting:
            dictateButton.accessibilityLabel = "Starting dictation"
            dictateButton.accessibilityHint = "Use the separate Cancel button to stop."
        case .transcribing:
            dictateButton.accessibilityLabel = "Transcribing"
            dictateButton.accessibilityHint = "Use the separate Cancel button to stop."
        case .recording:
            dictateButton.accessibilityLabel = "Stop dictating"
            dictateButton.accessibilityHint =
                "Stops recording and starts transcription. Cancel discards it instead."
        case .idle, .failed:
            dictateButton.accessibilityLabel = "Dictate"
            dictateButton.accessibilityHint = sessionWarm
                ? "Tap to start and stop. Touch and hold to record only while held."
                : "Opens DoNotType once to activate its microphone, then returns here."
        }
    }

    // MARK: - Dictation gesture

    private var idleCallToAction: String {
        voiceBridge.rewriteModeEnabled == true
            ? "Tap Speak to rewrite, or hold to talk"
            : "Tap Speak to dictate, or hold to talk"
    }

    private func renderModeButton(canChange: Bool) {
        // A target language set in the app is what the dictation will actually do, so the chip
        // says so — and stops being a toggle, because the keyboard cannot clear a setting it does
        // not own. A chip reading "Rewrite" over a dictation coming back in another language would
        // be worse than no chip at all.
        let translating = !voiceBridge.translationTarget.isEmpty
        let rewrite = !translating && voiceBridge.rewriteModeEnabled == true
        var configuration = UIButton.Configuration.filled()
        configuration.cornerStyle = .capsule
        configuration.image = UIImage(
            systemName: translating
                ? "character.bubble" : (rewrite ? "wand.and.sparkles" : "mic.fill"))
        configuration.preferredSymbolConfigurationForImage = .init(
            pointSize: 11, weight: .semibold)
        configuration.imagePadding = 3
        configuration.contentInsets = .init(top: 5, leading: 6, bottom: 5, trailing: 6)
        configuration.title = translating ? "Translate" : (rewrite ? "Rewrite" : "Dictate")
        configuration.titleTextAttributesTransformer = .init { attributes in
            var attributes = attributes
            attributes.font = .systemFont(ofSize: 12, weight: .semibold)
            return attributes
        }
        configuration.baseBackgroundColor =
            translating ? .systemTeal : (rewrite ? .systemPurple : .systemBlue)
        configuration.baseForegroundColor = .white
        modeButton.configuration = configuration
        modeButton.isEnabled = canChange && !translating
        modeButton.accessibilityLabel = translating
            ? "Translating into \(voiceBridge.translationTarget)"
            : (rewrite ? "Rewrite mode" : "Dictate mode")
        modeButton.accessibilityValue = "Selected"
        modeButton.accessibilityHint = translating
            ? "Clear the target language in DoNotType to change this."
            : (rewrite ? "Switches to Dictate mode." : "Switches to Rewrite mode.")
    }

    @objc private func toggleMode() {
        guard voiceBridge.translationTarget.isEmpty else { return }
        voiceBridge.setRewriteModeEnabled(voiceBridge.rewriteModeEnabled != true)
        transientStatus = nil
        reload()
    }

    @objc private func dictateTouchDown() {
        transientStatus = nil
        stopWhenRecordingStarts = false
        pressStartedAt = Date()
        pressStartedRecording = false

        switch voiceBridge.snapshot.phase {
        case .idle, .failed:
            pressStartedRecording = true
            voiceBridge.setReturnHostBundleIdentifier(keyboardHostBundleIdentifier())
            let wasWarm = voiceBridge.requestStart()
            reload()
            if wasWarm {
                scheduleColdLaunchFallback()
            } else {
                openContainingApp()
            }
        case .recording:
            voiceBridge.requestStop()
            reload()
        case .waiting, .transcribing:
            break
        }
    }

    @objc private func dictateTouchUp() {
        defer {
            pressStartedAt = nil
            pressStartedRecording = false
        }
        guard pressStartedRecording, let startedAt = pressStartedAt,
            Date().timeIntervalSince(startedAt) >= PressGesture.holdThreshold
        else { return }

        switch voiceBridge.snapshot.phase {
        case .recording:
            voiceBridge.requestStop()
            reload()
        case .waiting:
            stopWhenRecordingStarts = true
        case .idle, .transcribing, .failed:
            break
        }
    }

    private func scheduleColdLaunchFallback() {
        launchFallback?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.voiceBridge.snapshot.phase == .waiting else { return }
            self.openContainingApp()
        }
        launchFallback = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    private func openContainingApp() {
        guard appLauncher.open(URL(string: "donottype://dictate")) else {
            statusLabel.text = "Open DoNotType to activate dictation, then return here."
            return
        }
        statusLabel.text = "Starting DoNotType dictation…"
    }

    @objc private func openSettings() {
        guard appLauncher.open(URL(string: "donottype://settings")) else {
            statusLabel.text = "Open DoNotType to configure Settings."
            return
        }
        statusLabel.text = "Opening DoNotType Settings…"
    }

    /// `NSExtensionContext` does not publicly expose the application hosting a custom keyboard,
    /// but iOS carries the identifier on the context. Capture it before the deep link replaces the
    /// host on screen; the containing app needs it to return to the exact text field's app.
    private func keyboardHostBundleIdentifier() -> String? {
        var objects: [NSObject] = [self]
        if let context = extensionContext { objects.append(context) }
        if let window = view.window { objects.append(window) }
        if let inputView { objects.append(inputView) }
        if let parent { objects.append(parent) }
        if let proxy = textDocumentProxy as? NSObject { objects.append(proxy) }

        var responder = next
        while let current = responder {
            objects.append(current)
            responder = current.next
        }

        let names = [
            "__hostBundleIdentifier", "_hostBundleIdentifier", "hostBundleIdentifier",
            "_hostBundleID", "hostBundleID", "_hostApplicationBundleIdentifier",
            "_sourceBundleIdentifier", "sourceBundleIdentifier",
        ]
        for object in objects {
            for name in names {
                let selector = NSSelectorFromString(name)
                guard object.responds(to: selector),
                    let rawValue = object.perform(selector)?.takeUnretainedValue() as? String,
                    let value = KeyboardHostIdentifier.normalized(rawValue),
                    value != Bundle.main.bundleIdentifier,
                    value != "app.donottype"
                else { continue }
                return value
            }

            // `_UIHostedWindow` keeps this value in `__hostBundleIdentifier` without exposing a
            // getter for it. `responds(to:)` therefore says false even though the ivar already
            // contains the application that owns the text field. Read object-valued host ivars
            // through the Objective-C runtime before falling back to an audit token.
            if let value = privateHostIdentifierIvar(on: object) { return value }
        }
        return hostSigningIdentifier(in: objects)
    }

    private func privateHostIdentifierIvar(on object: NSObject) -> String? {
        let names = ["__hostBundleIdentifier", "_hostBundleIdentifier", "_hostBundleID"]
        for name in names {
            guard let ivar = class_getInstanceVariable(type(of: object), name),
                let encoding = ivar_getTypeEncoding(ivar), encoding.pointee == 64,
                let rawValue = object_getIvar(object, ivar) as? String,
                let value = KeyboardHostIdentifier.normalized(rawValue),
                value != Bundle.main.bundleIdentifier,
                value != "app.donottype"
            else { continue }
            return value
        }
        return nil
    }

    /// The extension context owns a copy of the caller's audit token. Do not call UIKit's similarly
    /// named `_hostAuditToken` on the view controller: a custom keyboard has no view-service host
    /// operator there, and iOS 26.6 dereferences that null operator inside UIKit.
    private func hostSigningIdentifier(in objects: [NSObject]) -> String? {
        for object in objects {
            for name in ["_extensionHostAuditToken"] {
                let selector = NSSelectorFromString(name)
                guard object.responds(to: selector),
                    let method = class_getInstanceMethod(type(of: object), selector),
                    let encoding = method_getTypeEncoding(method), encoding.pointee == 123,
                    let implementation = object.method(for: selector)
                else { continue }

                typealias AuditTokenGetter = @convention(c) (AnyObject, Selector) -> audit_token_t
                let getter = unsafeBitCast(implementation, to: AuditTokenGetter.self)
                if let identifier = signingIdentifier(for: getter(object, selector)),
                    identifier != Bundle.main.bundleIdentifier,
                    identifier != "app.donottype"
                {
                    return identifier
                }
            }
        }
        return nil
    }

    private func signingIdentifier(for auditToken: audit_token_t) -> String? {
        typealias CreateTask = @convention(c) (CFAllocator?, audit_token_t) -> Unmanaged<CFTypeRef>?
        typealias CopySigningIdentifier = @convention(c) (
            CFTypeRef, UnsafeMutablePointer<Unmanaged<CFError>?>?
        ) -> Unmanaged<CFString>?
        // Darwin's RTLD_DEFAULT is the sentinel `(void *)-2`; Swift's iOS overlay omits the name.
        let defaultSymbolScope = UnsafeMutableRawPointer(bitPattern: -2)
        guard let createSymbol = dlsym(defaultSymbolScope, "SecTaskCreateWithAuditToken"),
            let copySymbol = dlsym(defaultSymbolScope, "SecTaskCopySigningIdentifier")
        else { return nil }

        let createTask = unsafeBitCast(createSymbol, to: CreateTask.self)
        let copySigningIdentifier = unsafeBitCast(copySymbol, to: CopySigningIdentifier.self)
        guard let task = createTask(kCFAllocatorDefault, auditToken)?.takeRetainedValue(),
            let identifier = copySigningIdentifier(task, nil)?.takeRetainedValue() as String?
        else { return nil }
        return KeyboardHostIdentifier.normalized(identifier)
    }

    @objc private func cancelDictation() {
        let discarding = voiceBridge.snapshot.phase == .recording
        voiceBridge.requestCancel()
        transientStatus = discarding ? "Recording discarded" : "Cancelled"
        reload()
    }

    @objc private func insertReturn() {
        textDocumentProxy.insertText("\n")
    }

    @objc private func startBackspacePress() {
        stopBackspaceRepeat()
        isBackspaceHeld = true
        textDocumentProxy.deleteBackward()

        let delay = DispatchWorkItem { [weak self] in
            guard let self, self.isBackspaceHeld else { return }
            let timer = Timer(
                timeInterval: 0.065, target: self,
                selector: #selector(repeatBackspace), userInfo: nil, repeats: true)
            backspaceRepeatTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        backspaceRepeatDelay = delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.38, execute: delay)
    }

    @objc private func finishBackspacePress() {
        // Accessibility activation can arrive without a preceding touch-down.
        let needsSingleDelete = !isBackspaceHeld
        stopBackspaceRepeat()
        if needsSingleDelete { textDocumentProxy.deleteBackward() }
    }

    @objc private func cancelBackspacePress() {
        stopBackspaceRepeat()
    }

    @objc private func repeatBackspace() {
        guard isBackspaceHeld else {
            stopBackspaceRepeat()
            return
        }
        textDocumentProxy.deleteBackward()
    }

    private func stopBackspaceRepeat() {
        isBackspaceHeld = false
        backspaceRepeatDelay?.cancel()
        backspaceRepeatDelay = nil
        backspaceRepeatTimer?.invalidate()
        backspaceRepeatTimer = nil
    }

    // MARK: - Insertion and correction learning

    private func insert(_ text: String) {
        let correction = dictionaryStore.load().learnsFromEdits
            ? correctionAnchor(for: text) : nil
        textDocumentProxy.insertText(text)
        if let correction {
            correctionStore.save(correction)
            observePendingCorrection()
        } else {
            correctionStore.clear()
        }
        if let entry = entries.first(where: { $0.text == text && !$0.inserted }) {
            store.markInserted(entry.id)
        }
    }

    @objc private func statusTapped() {
        guard !lastLearnedTerms.isEmpty else { return }
        if let snapshot = try? dictionaryStore.forgetLearned(lastLearnedTerms) {
            transientStatus =
                "Removed learned spelling · \(snapshot.all.count) dictionary entries"
            statusLabel.text = transientStatus
        }
        lastLearnedTerms = []
    }

    private func correctionAnchor(for inserted: String) -> CorrectionObservationStore.Pending? {
        let before = textDocumentProxy.documentContextBeforeInput
        let after = textDocumentProxy.documentContextAfterInput
        guard before != nil || after != nil else { return nil }
        return .init(
            documentID: textDocumentProxy.documentIdentifier,
            prefix: String((before ?? "").suffix(32)),
            suffix: String((after ?? "").prefix(32)),
            inserted: inserted)
    }

    private func observePendingCorrection() {
        correctionTask?.cancel()
        guard dictionaryStore.load().learnsFromEdits,
            let pending = correctionStore.load(),
            pending.documentID == textDocumentProxy.documentIdentifier
        else { return }

        correctionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var prior: String?
            var stableReads = 0
            for _ in 0..<80 {
                try? await Task.sleep(for: .milliseconds(750))
                guard !Task.isCancelled,
                    pending.documentID == textDocumentProxy.documentIdentifier
                else { return }
                guard let edited = observedInsertion(pending) else { return }
                if edited == pending.inserted {
                    prior = nil
                    stableReads = 0
                    continue
                }
                if edited == prior { stableReads += 1 }
                else { prior = edited; stableReads = 1 }
                guard stableReads >= 2 else { continue }

                let candidates = PersonalDictionary.learnedCandidates(
                    from: pending.inserted, corrected: edited)
                if let (_, added) = try? dictionaryStore.learn(candidates), !added.isEmpty {
                    lastLearnedTerms = added
                    transientStatus = "Learned \(added.joined(separator: ", ")) — tap to undo"
                    statusLabel.text = transientStatus
                }
                correctionStore.clear()
                return
            }
        }
    }

    private func observedInsertion(_ pending: CorrectionObservationStore.Pending) -> String? {
        let before = textDocumentProxy.documentContextBeforeInput
        let after = textDocumentProxy.documentContextAfterInput
        guard before != nil || after != nil else { return nil }
        let combined = (before ?? "") + (after ?? "")

        let start: String.Index
        if pending.prefix.isEmpty { start = combined.startIndex }
        else {
            guard let anchor = combined.range(of: pending.prefix, options: .backwards) else {
                return nil
            }
            start = anchor.upperBound
        }

        let end: String.Index
        if pending.suffix.isEmpty { end = combined.endIndex }
        else {
            guard let anchor = combined.range(of: pending.suffix, range: start..<combined.endIndex)
            else { return nil }
            end = anchor.lowerBound
        }
        guard start <= end else { return nil }
        return String(combined[start..<end])
    }
}
