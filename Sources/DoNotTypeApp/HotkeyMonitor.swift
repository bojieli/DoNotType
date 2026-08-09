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

    var trigger: Trigger = .rightCommand
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    /// Fires when the user taps Escape while recording.
    var onCancel: (() -> Void)?

    private let log = Logger(subsystem: "ai.19pine.donottype", category: "hotkey")
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var watchdog: Timer?
    private var isHeld = false
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
            guard CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode)) == trigger.keyCode
            else { return }
            let down = event.flags.contains(trigger.flag)
            guard down != isHeld else { return }
            isHeld = down
            down ? onPress?() : onRelease?()

        case .keyDown:
            // Escape aborts a recording in flight without inserting anything.
            if isHeld, event.getIntegerValueField(.keyboardEventKeycode) == 53 {
                isHeld = false
                onCancel?()
            }

        default:
            break
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
