import DoNotTypeCore
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
    /// Darwin notifications can reach this controller after Notes has hidden its keyboard. Its
    /// `textDocumentProxy` still exists then, but inserting through it is a no-op. Never consume a
    /// result until UIKit has attached this keyboard to a visible document again.
    private var isKeyboardVisible = false

    /// This keyboard supplies its own recognition pipeline. Returning `true` from the property,
    /// rather than setting it after the view loads, prevents iOS from ever adding the system
    /// dictation key while constructing the keyboard chrome.
    override var hasDictationKey: Bool {
        get { true }
        set {}
    }

    private lazy var appLauncher = KeyboardContainingAppLauncher { [weak self] in self }
    private lazy var statusLabel = UILabel()
    private lazy var dictateButton = UIButton(type: .system)
    private lazy var nextKeyboardButton = UIButton(type: .system)
    private lazy var latestButton = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
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

        dictateButton.accessibilityIdentifier = "kb-dictate"
        dictateButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        dictateButton.tintColor = .white
        dictateButton.layer.cornerRadius = 58
        dictateButton.clipsToBounds = true
        dictateButton.translatesAutoresizingMaskIntoConstraints = false
        dictateButton.addTarget(self, action: #selector(dictateTouchDown), for: .touchDown)
        dictateButton.addTarget(
            self, action: #selector(dictateTouchUp), for: [.touchUpInside, .touchUpOutside])

        nextKeyboardButton.setTitle("🌐", for: .normal)
        nextKeyboardButton.accessibilityIdentifier = "kb-next"
        nextKeyboardButton.accessibilityLabel = "Next keyboard"
        nextKeyboardButton.titleLabel?.font = .systemFont(ofSize: 22)
        nextKeyboardButton.addTarget(
            self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
        nextKeyboardButton.translatesAutoresizingMaskIntoConstraints = false

        latestButton.setTitle("Insert latest", for: .normal)
        latestButton.accessibilityIdentifier = "kb-insert-latest"
        latestButton.addTarget(self, action: #selector(insertLatest), for: .touchUpInside)
        latestButton.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(statusLabel)
        view.addSubview(dictateButton)
        view.addSubview(nextKeyboardButton)
        view.addSubview(latestButton)

        NSLayoutConstraint.activate([
            view.heightAnchor.constraint(equalToConstant: 300),

            statusLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),

            dictateButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            dictateButton.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: 4),
            dictateButton.widthAnchor.constraint(equalToConstant: 116),
            dictateButton.heightAnchor.constraint(equalToConstant: 116),

            nextKeyboardButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            nextKeyboardButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
            nextKeyboardButton.widthAnchor.constraint(equalToConstant: 44),
            nextKeyboardButton.heightAnchor.constraint(equalToConstant: 36),

            latestButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            latestButton.centerYAnchor.constraint(equalTo: nextKeyboardButton.centerYAnchor),
            latestButton.heightAnchor.constraint(equalToConstant: 36),
        ])
    }

    private func reload() {
        entries = store.load()
        latestButton.isHidden = entries.isEmpty

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
            statusLabel.text = transientStatus ?? (voiceBridge.isSessionWarm
                ? "Tap to dictate, or hold to talk"
                : "Tap to dictate · DoNotType opens once to activate the microphone")
        case .waiting:
            statusLabel.text = voiceBridge.isSessionWarm
                ? "Starting dictation…" : "Opening DoNotType to activate the microphone…"
        case .recording:
            statusLabel.text = "Listening… tap to stop"
        case .transcribing:
            statusLabel.text = "Transcribing… tap × to cancel"
        case .failed:
            statusLabel.text = current.message ?? "Dictation failed — tap to try again"
        }
        renderButton(phase: current.phase, sessionWarm: voiceBridge.isSessionWarm)
    }

    private func renderButton(phase: VoiceKeyboardBridge.Phase, sessionWarm: Bool) {
        let symbol: String
        let background: UIColor
        switch phase {
        case .recording:
            symbol = "stop.fill"
            background = .systemRed
        case .waiting, .transcribing:
            symbol = "xmark"
            background = .systemGray
        case .idle, .failed:
            symbol = sessionWarm ? "mic.fill" : "mic"
            background = .systemBlue
        }

        dictateButton.setImage(
            UIImage(systemName: symbol)?.applyingSymbolConfiguration(
                .init(pointSize: 42, weight: .semibold)),
            for: .normal)
        dictateButton.backgroundColor = background
        switch phase {
        case .waiting:
            dictateButton.accessibilityLabel = "Cancel dictation"
            dictateButton.accessibilityHint = "Cancels microphone activation."
        case .transcribing:
            dictateButton.accessibilityLabel = "Cancel transcription"
            dictateButton.accessibilityHint = "Stops waiting and discards this transcription."
        case .recording:
            dictateButton.accessibilityLabel = "Stop dictating"
            dictateButton.accessibilityHint = "Stops recording and starts transcription."
        case .idle, .failed:
            dictateButton.accessibilityLabel = "Dictate"
            dictateButton.accessibilityHint = sessionWarm
                ? "Tap to start and stop. Touch and hold to record only while held."
                : "Opens DoNotType once to activate its microphone, then returns here."
        }
    }

    // MARK: - Dictation gesture

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
            voiceBridge.requestCancel()
            transientStatus = "Cancelled"
            reload()
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

    /// `NSExtensionContext` does not publicly expose the application hosting a custom keyboard,
    /// but iOS carries the identifier on the context. Capture it before the deep link replaces the
    /// host on screen; the containing app needs it to return to the exact text field's app.
    private func keyboardHostBundleIdentifier() -> String? {
        guard let context = extensionContext else { return nil }
        for name in ["_hostBundleIdentifier", "hostBundleIdentifier"] {
            let selector = NSSelectorFromString(name)
            guard context.responds(to: selector),
                let value = context.perform(selector)?.takeUnretainedValue() as? String,
                !value.isEmpty
            else { continue }
            return value
        }
        return nil
    }

    // MARK: - Insertion and correction learning

    @objc private func insertLatest() {
        guard let entry = entries.first else { return }
        insert(entry.text)
        store.markInserted(entry.id)
        transientStatus = "Inserted latest transcript"
        reload()
    }

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
