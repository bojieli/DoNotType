import AppKit
import CoreGraphics
import DoNotTypeCore

/// Global push-to-talk key, via a CGEvent tap.
///
/// The watchdog is not optional. macOS silently disables an event tap whose callback overruns its
/// timeout, and it does so without any notification — the app simply stops responding to the
/// hotkey forever. Typeless ships a restart timer and a metric counting how often it fires, which
/// is a good indication of how routine this is.
@MainActor
final class HotkeyMonitor {
    /// A physical key plus the modifiers that must be held when it is pressed.
    ///
    /// The four original values keep their old persisted strings, so existing defaults and
    /// settings-transfer files remain valid. Recorded combinations use a versioned string with
    /// the key code, flags and display label. The key code makes the shortcut physical (and thus
    /// stable if the keyboard layout changes); the label preserves what the user saw while
    /// recording it.
    struct Trigger: RawRepresentable, Hashable {
        let rawValue: String
        let keyCode: CGKeyCode
        let modifiers: CGEventFlags
        private let keyLabel: String

        static let rightCommand = Trigger(
            legacy: "rightCommand", keyCode: 54, modifiers: .maskCommand,
            keyLabel: "Right ⌘")
        static let rightOption = Trigger(
            legacy: "rightOption", keyCode: 61, modifiers: .maskAlternate,
            keyLabel: "Right ⌥")
        static let rightControl = Trigger(
            legacy: "rightControl", keyCode: 62, modifiers: .maskControl,
            keyLabel: "Right ⌃")
        static let fnKey = Trigger(
            legacy: "fnKey", keyCode: 63, modifiers: .maskSecondaryFn, keyLabel: "fn")

        private static let persistedPrefix = "shortcut.1"
        static let modifierMask: CGEventFlags = [
            .maskCommand, .maskShift, .maskControl, .maskAlternate, .maskSecondaryFn,
        ]

        init?(rawValue: String) {
            switch rawValue {
            case Self.rightCommand.rawValue: self = .rightCommand
            case Self.rightOption.rawValue: self = .rightOption
            case Self.rightControl.rawValue: self = .rightControl
            case Self.fnKey.rawValue: self = .fnKey
            default:
                let pieces = rawValue.split(separator: ":", maxSplits: 3)
                guard pieces.count == 4, pieces[0] == Substring(Self.persistedPrefix),
                    let keyCode = CGKeyCode(pieces[1]),
                    let flags = UInt64(pieces[2]),
                    let labelData = Data(base64Encoded: String(pieces[3])),
                    let keyLabel = String(data: labelData, encoding: .utf8), !keyLabel.isEmpty
                else { return nil }
                self.rawValue = rawValue
                self.keyCode = keyCode
                self.modifiers = CGEventFlags(rawValue: flags).intersection(Self.modifierMask)
                self.keyLabel = keyLabel
            }
        }

        init(keyCode: CGKeyCode, modifiers: CGEventFlags, keyLabel: String) {
            let normalized = modifiers.intersection(Self.modifierMask)
            let encodedLabel = Data(keyLabel.utf8).base64EncodedString()
            rawValue = "\(Self.persistedPrefix):\(keyCode):\(normalized.rawValue):\(encodedLabel)"
            self.keyCode = keyCode
            self.modifiers = normalized
            self.keyLabel = keyLabel
        }

        private init(
            legacy: String, keyCode: CGKeyCode, modifiers: CGEventFlags, keyLabel: String
        ) {
            rawValue = legacy
            self.keyCode = keyCode
            self.modifiers = modifiers
            self.keyLabel = keyLabel
        }

        static func == (lhs: Trigger, rhs: Trigger) -> Bool {
            lhs.keyCode == rhs.keyCode && lhs.modifiers == rhs.modifiers
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(keyCode)
            hasher.combine(modifiers.rawValue)
        }

        var label: String {
            guard !isModifierKey else {
                let otherModifiers = modifiers.subtracting(modifierFlag ?? [])
                let symbols = Self.modifierSymbols(otherModifiers)
                return symbols.isEmpty ? keyLabel : "\(symbols) \(keyLabel)"
            }
            return Self.modifierSymbols(modifiers) + keyLabel
        }

        var isModifierKey: Bool { Self.modifierFlag(for: keyCode) != nil }
        private var modifierFlag: CGEventFlags? { Self.modifierFlag(for: keyCode) }

        /// Plain letters, digits and punctuation cannot safely be global triggers: binding one
        /// would steal normal typing in every application. Modifier keys and function keys are
        /// useful by themselves; ordinary keys need Command, Option or Control.
        var isSafeForGlobalUse: Bool {
            if isModifierKey { return true }
            if !modifiers.intersection([.maskCommand, .maskAlternate, .maskControl]).isEmpty {
                return true
            }
            return Self.functionKeyCodes.contains(keyCode)
        }

        /// Return and Escape already have recording-only meanings configured elsewhere.
        var isReserved: Bool { keyCode == 36 || keyCode == 76 || keyCode == 53 }

        static func modifierFlag(for keyCode: CGKeyCode) -> CGEventFlags? {
            switch keyCode {
            case 54, 55: .maskCommand
            case 56, 60: .maskShift
            case 58, 61: .maskAlternate
            case 59, 62: .maskControl
            case 63: .maskSecondaryFn
            default: nil
            }
        }

        static func modifierLabel(for keyCode: CGKeyCode) -> String? {
            switch keyCode {
            case 54: "Right ⌘"
            case 55: "Left ⌘"
            case 56: "Left ⇧"
            case 60: "Right ⇧"
            case 58: "Left ⌥"
            case 61: "Right ⌥"
            case 59: "Left ⌃"
            case 62: "Right ⌃"
            case 63: "fn"
            default: nil
            }
        }

        static func normalizedModifiers(_ flags: CGEventFlags) -> CGEventFlags {
            flags.intersection(modifierMask)
        }

        private static func modifierSymbols(_ flags: CGEventFlags) -> String {
            var result = ""
            if flags.contains(.maskControl) { result += "⌃" }
            if flags.contains(.maskAlternate) { result += "⌥" }
            if flags.contains(.maskShift) { result += "⇧" }
            if flags.contains(.maskCommand) { result += "⌘" }
            if flags.contains(.maskSecondaryFn) { result += "fn " }
            return result
        }

        private static let functionKeyCodes: Set<CGKeyCode> = [
            122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64,
            79, 80, 90,
        ]
    }

    /// How holding the key relates to recording. Shared with the other clients, and tested there:
    /// see `PressGesture`.
    typealias Mode = PressGesture.Mode

    /// A press shorter than this counts as a tap. See `PressGesture.holdThreshold`.
    static let holdThreshold = PressGesture.holdThreshold

    var trigger: Trigger = .rightCommand
    var mode: Mode = .automatic
    var cancelShortcut: CancelShortcut = .escape
    var finishAndSendAction: FinishAndSendAction = .disabled

    /// Optional key bound to a rewrite style.
    ///
    /// A key per mode rather than a mode toggle because the choice is per-utterance, not
    /// per-session: the same person wants verbatim for a chat message and formal for the email
    /// they write ten seconds later. A toggle would make them remember which mode they left it in.
    var rewriteTrigger: Trigger?

    /// Optional key bound to the configured target language.
    ///
    /// The third key exists because the alternative was a setting that quietly took the other two
    /// over: a target language used to make *every* key translate, including the main one, which
    /// is the single place this product broke its own promise that the main key is verbatim. The
    /// phones answered the same question with a three-way chip; a desktop answers it with which
    /// key is held. See `docs/PARITY.md`.
    var translateTrigger: Trigger?

    /// Fires with the mode whose key started the recording.
    var onPressMode: ((LiveMode) -> Void)?

    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    /// Fires when the physical trigger changes state, so automatic mode can show the exact gesture
    /// that will finish the recording instead of the ambiguous "release or tap".
    var onHoldChange: ((Bool) -> Void)?
    /// Fires when the configured cancel key is pressed during recording or transcription.
    var onCancel: (() -> Void)?
    /// Fires when Return ends a recording. The action decides whether insertion is also submitted.
    var onFinishWithReturn: ((FinishAndSendAction) -> Void)?

    /// Extra chorded shortcuts that work whether or not a recording is in flight.
    ///
    /// Keyed by (keyCode, required flags). Kept separate from the push-to-talk trigger because
    /// these are ordinary shortcuts — press and go — rather than a held modifier.
    var chords: [(keyCode: CGKeyCode, flags: CGEventFlags, action: () -> Void)] = []
    /// Set by the owner so tap-toggle knows whether a tap should start or stop.
    var isRecording: () -> Bool = { false }
    /// Unlike `isRecording`, this includes the request and optional rewrite after key-up.
    var isDictationActive: () -> Bool = { false }

    private let log = Log("hotkey")
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var watchdog: Timer?
    private(set) var isHeld = false
    /// The press's own event timestamp, not the moment this code got to it. See `seconds(from:to:)`.
    private var pressedAt: CGEventTimestamp?
    /// Whether the in-flight recording began with this press, for `automatic` mode.
    private var startedByTap = false
    /// Which key began the in-flight recording, so release routes to the same mode.
    private var activeMode: LiveMode = .dictate
    /// The full trigger that began the current gesture. Required for chord releases, which may
    /// arrive after their modifier flags have changed.
    private var activeTrigger: Trigger?
    /// Ordinary trigger key-downs are swallowed so they do not type or run another app command.
    /// Their matching key-up must be swallowed too, including when a required modifier was
    /// released first and already ended the gesture.
    private var consumedTriggerKeyCode: CGKeyCode?
    /// Keeps the key-up swallowed after key-down cancellation has already returned the app idle.
    private var isCancellingWithEscape = false
    /// Keeps Return's key-up swallowed after its key-down has moved recording to transcription.
    private var isFinishingWithReturn = false
    private(set) var restartCount = 0

    func start() -> Bool {
        guard installTap() else { return false }
        // 2 s is well inside the window where a user would notice the hotkey being dead.
        watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reviveIfDisabled() }
        }
        return true
    }

    func stop() {
        watchdog?.invalidate()
        watchdog = nil
        isHeld = false
        activeTrigger = nil
        consumedTriggerKeyCode = nil
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        runLoopSource = nil
        tap = nil
    }

    // MARK: - Private

    private func installTap() -> Bool {
        let mask =
            (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)

        // An active tap is required to consume the configured recording-only keys. Every other
        // event is returned unchanged, so Right ⌘ keeps working as a modifier and Return/Escape
        // remain the foreground app's keys at idle.
        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: CGEventMask(mask),
                callback: { _, type, event, refcon in
                    guard let refcon else { return Unmanaged.passUnretained(event) }
                    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                    let consumed = MainActor.assumeIsolated {
                        monitor.handle(type: type, event: event)
                    }
                    return consumed ? nil : Unmanaged.passUnretained(event)
                },
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            )
        else {
            log.error("tapCreate failed — Accessibility permission is probably not granted")
            return false
        }

        self.tap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    /// Returns true only for a configured recording-only keystroke in its active state.
    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // Re-enable immediately rather than waiting for the next watchdog tick.
            reviveIfDisabled()

        case .flagsChanged:
            let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            let flags = Trigger.normalizedModifiers(event.flags)

            // Any required modifier being released ends a modifier-only combination. This also
            // covers combinations such as Right Command + Right Option when Option is released
            // before the final Command key.
            if isHeld, let activeTrigger, activeTrigger.isModifierKey,
                !flags.isSuperset(of: activeTrigger.modifiers)
            {
                isHeld = false
                self.activeTrigger = nil
                onHoldChange?(false)
                handleRelease(at: event.timestamp)
                return false
            }

            guard !isHeld,
                let match = matchingTrigger(keyCode: keyCode, modifiers: flags),
                match.trigger.isModifierKey
            else { return false }

            isHeld = true
            activeTrigger = match.trigger
            activeMode = match.mode
            onHoldChange?(true)
            handlePress(at: event.timestamp)

        case .keyDown, .keyUp:
            // Synthetic paste/submit events from this process are output, never controls. Without
            // this, a submit racing a newly started recording could finish that new recording.
            if event.getIntegerValueField(.eventSourceUnixProcessID)
                == Int64(ProcessInfo.processInfo.processIdentifier)
            {
                return false
            }
            let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

            if type == .keyUp, consumedTriggerKeyCode == keyCode {
                consumedTriggerKeyCode = nil
                if isHeld, activeTrigger?.keyCode == keyCode {
                    isHeld = false
                    activeTrigger = nil
                    onHoldChange?(false)
                    handleRelease(at: event.timestamp)
                }
                return true
            }

            if keyCode == 36 || keyCode == 76 {  // kVK_Return or kVK_ANSI_KeypadEnter
                if type == .keyUp, isFinishingWithReturn {
                    isFinishingWithReturn = false
                    return true
                }
                if type == .keyDown {
                    // Repeats stay swallowed, but only the first key-down finishes the recording.
                    if isFinishingWithReturn { return true }
                    if finishAndSendAction.capturesReturn(whileRecording: isRecording()) {
                        isFinishingWithReturn = true
                        onFinishWithReturn?(finishAndSendAction)
                        return true
                    }
                }
            }

            if keyCode == 53 {  // kVK_Escape
                if type == .keyUp, isCancellingWithEscape {
                    isCancellingWithEscape = false
                    return true
                }
                if type == .keyDown {
                    // Repeated key-downs remain swallowed but only the first one cancels.
                    if isCancellingWithEscape { return true }
                    if cancelShortcut.capturesEscape(
                        whileDictationIsActive: isDictationActive())
                    {
                        isCancellingWithEscape = true
                        onCancel?()
                        return true
                    }
                }
            }

            let flags = event.flags.intersection([.maskCommand, .maskShift, .maskControl, .maskAlternate])
            if type == .keyDown,
                let match = matchingTrigger(
                    keyCode: keyCode, modifiers: Trigger.normalizedModifiers(event.flags)),
                !match.trigger.isModifierKey
            {
                // Repeats remain swallowed without starting the same gesture twice.
                consumedTriggerKeyCode = keyCode
                if !isHeld {
                    isHeld = true
                    activeTrigger = match.trigger
                    activeMode = match.mode
                    onHoldChange?(true)
                    handlePress(at: event.timestamp)
                }
                return true
            }

            guard type == .keyDown else { return false }
            for chord in chords where chord.keyCode == keyCode && flags == chord.flags {
                chord.action()
                return false
            }

        default:
            break
        }
        return false
    }

    /// Which mode's key this keystroke is, if any.
    ///
    /// Ordered deliberately: the main shortcut wins if an imported or hand-edited settings file
    /// contains a duplicate, and rewrite wins over translate on the same reasoning — a key that
    /// silently translated when the user bound it to rewrite is the failure this whole change
    /// exists to remove.
    private func matchingTrigger(
        keyCode: CGKeyCode, modifiers: CGEventFlags
    ) -> (trigger: Trigger, mode: LiveMode)? {
        if trigger.keyCode == keyCode, trigger.modifiers == modifiers {
            return (trigger, .dictate)
        }
        if let rewriteTrigger, rewriteTrigger.keyCode == keyCode,
            rewriteTrigger.modifiers == modifiers
        {
            return (rewriteTrigger, .rewrite)
        }
        if let translateTrigger, translateTrigger.keyCode == keyCode,
            translateTrigger.modifiers == modifiers
        {
            return (translateTrigger, .translate)
        }
        return nil
    }

    // MARK: - Press semantics

    private func handlePress(at stamp: CGEventTimestamp) {
        pressedAt = stamp
        onPressMode?(activeMode)

        let recording = isRecording()
        // Whether the release that follows is ending the recording this press started, or is
        // merely the tail of the second tap of a hands-free session.
        startedByTap = !recording
        switch PressGesture.press(mode: mode, isRecording: recording) {
        case .start: onPress?()
        case .stop: onRelease?()
        case .nothing: break
        }
    }

    private func handleRelease(at stamp: CGEventTimestamp) {
        // `CGEventTimestamp` is nanoseconds since startup, stamped by the window server when the
        // key physically moved — so this is the gesture's own duration rather than a measure of
        // how busy the main thread was while it happened.
        let held = pressedAt.map { PressGesture.seconds(fromNanoseconds: $0, to: stamp) } ?? 0
        pressedAt = nil

        switch PressGesture.release(mode: mode, held: held, startedByTap: startedByTap) {
        case .stop: onRelease?()
        case .start, .nothing: break
        }
    }

    private func reviveIfDisabled() {
        guard let tap, !CGEvent.tapIsEnabled(tap: tap) else { return }
        restartCount += 1
        log.warning("event tap was disabled by the system; restarting (count: \(self.restartCount))")
        CGEvent.tapEnable(tap: tap, enable: true)

        // If re-enabling did not take, the port itself is dead and needs rebuilding.
        if !CGEvent.tapIsEnabled(tap: tap) {
            stop()
            _ = start()
        }
    }
}
