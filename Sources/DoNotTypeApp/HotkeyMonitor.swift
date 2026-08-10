import AppKit
import CoreGraphics
import os

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

    /// How holding the key relates to recording.
    ///
    /// `automatic` is the default because it needs no decision from the user: a quick tap starts a
    /// hands-free recording that a second tap ends, and anything held past the threshold behaves
    /// as push-to-talk. Short utterances suit the hold; long ones suit not having to hold.
    enum Mode: String, CaseIterable, Sendable {
        /// Record while held, stop on release.
        case pushToTalk
        /// Tap once to start, tap again to stop.
        case handsFree
        /// Tap toggles; holding past `holdThreshold` becomes push-to-talk.
        case automatic

        var label: String {
            switch self {
            case .pushToTalk: "Hold to talk"
            case .handsFree: "Tap to start, tap to stop"
            case .automatic: "Tap to toggle, hold to talk"
            }
        }

        /// Shown in the recording overlay, so it always says how to stop.
        var overlayHint: String {
            switch self {
            case .pushToTalk: "Release to send"
            case .handsFree: "Tap again to send"
            case .automatic: "Release or tap to send"
            }
        }
    }

    /// A press shorter than this counts as a tap. 250 ms is comfortably longer than an intentional
    /// tap and comfortably shorter than the shortest useful dictation.
    static let holdThreshold: TimeInterval = 0.25

    var trigger: Trigger = .rightCommand
    var mode: Mode = .automatic

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
    /// Fires when the user taps Escape while recording.
    var onCancel: (() -> Void)?

    /// Extra chorded shortcuts that work whether or not a recording is in flight.
    ///
    /// Keyed by (keyCode, required flags). Kept separate from the push-to-talk trigger because
    /// these are ordinary shortcuts — press and go — rather than a held modifier.
    var chords: [(keyCode: CGKeyCode, flags: CGEventFlags, action: () -> Void)] = []
    /// Set by the owner so tap-toggle knows whether a tap should start or stop.
    var isRecording: () -> Bool = { false }

    private let log = Logger(subsystem: "ai.19pine.donottype", category: "hotkey")
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var watchdog: Timer?
    private var isHeld = false
    private var pressedAt: Date?
    /// Whether the in-flight recording began with this press, for `automatic` mode.
    private var startedByTap = false
    /// Which key began the in-flight recording, so release routes to the same style.
    private var usedSecondary = false
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

        // Listen-only: we observe the modifier without consuming it, so Right ⌘ keeps working as
        // a modifier for anything else the user presses.
        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .listenOnly,
                eventsOfInterest: CGEventMask(mask),
                callback: { _, type, event, refcon in
                    guard let refcon else { return Unmanaged.passUnretained(event) }
                    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                    MainActor.assumeIsolated { monitor.handle(type: type, event: event) }
                    return Unmanaged.passUnretained(event)
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

    private func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // Re-enable immediately rather than waiting for the next watchdog tick.
            reviveIfDisabled()

        case .flagsChanged:
            let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            let isSecondary = secondaryTrigger.map { $0.keyCode == keyCode } ?? false
            guard keyCode == trigger.keyCode || isSecondary else { return }

            let active = isSecondary ? secondaryTrigger! : trigger
            let down = event.flags.contains(active.flag)
            guard down != isHeld else { return }
            isHeld = down
            if down {
                usedSecondary = isSecondary
                handlePress()
            } else {
                handleRelease()
            }

        case .keyDown:
            let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

            // Escape aborts a recording in flight without inserting anything.
            if isRecording(), keyCode == 53 {
                onCancel?()
                return
            }

            let flags = event.flags.intersection([.maskCommand, .maskShift, .maskControl, .maskAlternate])
            for chord in chords where chord.keyCode == keyCode && flags == chord.flags {
                chord.action()
                return
            }

        default:
            break
        }
    }

    // MARK: - Press semantics

    private func handlePress() {
        pressedAt = Date()
        onPressStyled?(usedSecondary)
        switch mode {
        case .pushToTalk:
            onPress?()
        case .handsFree:
            isRecording() ? onRelease?() : onPress?()
        case .automatic:
            // Start immediately either way: waiting to see whether this becomes a hold would
            // clip the first word off every push-to-talk dictation.
            if isRecording() {
                startedByTap = false
            } else {
                startedByTap = true
                onPress?()
            }
        }
    }

    private func handleRelease() {
        let held = pressedAt.map { Date().timeIntervalSince($0) } ?? 0
        pressedAt = nil

        switch mode {
        case .pushToTalk:
            onRelease?()
        case .handsFree:
            break  // toggling already happened on press
        case .automatic:
            if !startedByTap {
                // The press that landed while recording was the second tap of a hands-free
                // session; it stopped on press and there is nothing to do here.
                onRelease?()
            } else if held >= Self.holdThreshold {
                onRelease?()  // it was a hold, so release ends it
            }
            // Otherwise it was a tap: recording continues until the next press.
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
