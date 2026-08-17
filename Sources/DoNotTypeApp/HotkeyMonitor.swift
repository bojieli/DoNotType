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
    /// Held-modifier push-to-talk. Right Command by default: it is reachable, rarely bound, and
    /// unlike Fn+Space it does not collide with other dictation tools.
    enum Trigger: String, CaseIterable {
        case rightCommand, rightOption, rightControl, fnKey

        var keyCode: CGKeyCode {
            switch self {
            case .rightCommand: 54
            case .rightOption: 61
            case .rightControl: 62
            case .fnKey: 63
            }
        }

        var flag: CGEventFlags {
            switch self {
            case .rightCommand: .maskCommand
            case .rightOption: .maskAlternate
            case .rightControl: .maskControl
            case .fnKey: .maskSecondaryFn
            }
        }

        var label: String {
            switch self {
            case .rightCommand: "Right ⌘"
            case .rightOption: "Right ⌥"
            case .rightControl: "Right ⌃"
            case .fnKey: "fn"
            }
        }
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

    /// Optional second key bound to a rewrite style.
    ///
    /// Two keys rather than a mode toggle because the choice is per-utterance, not per-session:
    /// the same person wants verbatim for a chat message and formal for the email they write ten
    /// seconds later. A toggle would make them remember which mode they left it in.
    var secondaryTrigger: Trigger?

    /// Fires with `true` when the secondary key started the recording.
    var onPressStyled: ((Bool) -> Void)?

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
    /// Which key began the in-flight recording, so release routes to the same style.
    private var usedSecondary = false
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
            let isSecondary = secondaryTrigger.map { $0.keyCode == keyCode } ?? false
            guard keyCode == trigger.keyCode || isSecondary else { return false }

            let active = isSecondary ? secondaryTrigger! : trigger
            let down = event.flags.contains(active.flag)
            guard down != isHeld else { return false }
            isHeld = down
            onHoldChange?(down)
            if down {
                usedSecondary = isSecondary
                handlePress(at: event.timestamp)
            } else {
                handleRelease(at: event.timestamp)
            }

        case .keyDown, .keyUp:
            // Synthetic paste/submit events from this process are output, never controls. Without
            // this, a submit racing a newly started recording could finish that new recording.
            if event.getIntegerValueField(.eventSourceUnixProcessID)
                == Int64(ProcessInfo.processInfo.processIdentifier)
            {
                return false
            }
            let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

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

            guard type == .keyDown else { return false }
            let flags = event.flags.intersection([.maskCommand, .maskShift, .maskControl, .maskAlternate])
            for chord in chords where chord.keyCode == keyCode && flags == chord.flags {
                chord.action()
                return false
            }

        default:
            break
        }
        return false
    }

    // MARK: - Press semantics

    private func handlePress(at stamp: CGEventTimestamp) {
        pressedAt = stamp
        onPressStyled?(usedSecondary)

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
