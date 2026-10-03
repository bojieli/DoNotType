import CoreGraphics
import DoNotTypeCore
import XCTest
@testable import DoNotTypeApp

final class FinishShortcutTests: XCTestCase {
    @MainActor
    private static func event(_ code: CGKeyCode, _ type: CGEventType, flags: CGEventFlags = []) -> CGEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: type != .keyUp)!
        event.type = type
        event.flags = flags
        event.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
        return event
    }

    func testDefaultLeavesReturnAndUnmatchedChordsAlone() async {
        await MainActor.run {
            let monitor = HotkeyMonitor()
            monitor.canFinishWithShortcut = { true }
            for code: CGKeyCode in [36, 76, 1] {
                XCTAssertFalse(monitor.handle(type: .keyDown, event: Self.event(code, .keyDown)))
                XCTAssertFalse(monitor.handle(type: .keyUp, event: Self.event(code, .keyUp)))
            }
            XCTAssertFalse(monitor.handle(type: .keyDown,
                event: Self.event(1, .keyDown, flags: [.maskCommand])))
        }
    }

    func testFinishCapturesRepeatsAndReleaseAfterRecordingEnds() async {
        await MainActor.run {
            let monitor = HotkeyMonitor()
            var recording = true
            var actions: [FinishAndSendAction] = []
            monitor.canFinishWithShortcut = { recording }
            monitor.finishShortcut = .init(keyCode: 1, modifiers: [.maskCommand, .maskShift], keyLabel: "S")
            monitor.finishAndSendAction = .returnKey
            monitor.onFinishShortcut = { actions.append($0); recording = false }
            let flags: CGEventFlags = [.maskCommand, .maskShift]
            XCTAssertTrue(monitor.handle(type: .keyDown, event: Self.event(1, .keyDown, flags: flags)))
            XCTAssertTrue(monitor.handle(type: .keyDown, event: Self.event(1, .keyDown, flags: flags)))
            // Releasing modifiers first still consumes the corresponding S key-up.
            XCTAssertTrue(monitor.handle(type: .keyUp, event: Self.event(1, .keyUp)))
            XCTAssertEqual(actions, [.returnKey])
            XCTAssertFalse(monitor.handle(type: .keyDown, event: Self.event(1, .keyDown, flags: flags)))
        }
    }

    func testCustomReturnAndDisabledShortcut() async {
        await MainActor.run {
            let monitor = HotkeyMonitor()
            monitor.canFinishWithShortcut = { true }
            monitor.finishShortcut = .init(keyCode: 36, modifiers: [.maskAlternate], keyLabel: "Return")
            XCTAssertFalse(monitor.handle(type: .keyDown, event: Self.event(36, .keyDown)))
            XCTAssertTrue(monitor.handle(type: .keyDown, event: Self.event(36, .keyDown, flags: .maskAlternate)))
            XCTAssertTrue(monitor.handle(type: .keyUp, event: Self.event(36, .keyUp)))
            monitor.finishShortcut = nil
            XCTAssertFalse(monitor.handle(type: .keyDown, event: Self.event(36, .keyDown, flags: .maskAlternate)))
        }
    }

    func testModifierOnlyFinishAndGlobalTriggerConflict() async {
        await MainActor.run {
            let monitor = HotkeyMonitor()
            var recording = true
            var finishes = 0
            monitor.canFinishWithShortcut = { recording }
            XCTAssertEqual(monitor.finishShortcut, .rightOption)
            monitor.onFinishShortcut = { _ in finishes += 1; recording = false }
            XCTAssertTrue(monitor.handle(type: .flagsChanged, event: Self.event(61, .flagsChanged, flags: .maskAlternate)))
            XCTAssertTrue(monitor.handle(type: .flagsChanged, event: Self.event(61, .flagsChanged)))
            XCTAssertEqual(finishes, 1)
            recording = true
            monitor.finishShortcut = monitor.trigger
            _ = monitor.handle(type: .flagsChanged, event: Self.event(54, .flagsChanged, flags: .maskCommand))
            XCTAssertEqual(finishes, 1)
        }
    }

    func testOneKeyFinishWhileRecordingTriggerIsHeld() async {
        await MainActor.run {
            let monitor = HotkeyMonitor()
            var recording = true
            var finishes = 0
            monitor.canFinishWithShortcut = { recording }
            monitor.onFinishShortcut = { _ in finishes += 1; recording = false }
            _ = monitor.handle(type: .flagsChanged, event: Self.event(54, .flagsChanged, flags: .maskCommand))
            XCTAssertTrue(monitor.isHeld)
            XCTAssertTrue(monitor.handle(type: .flagsChanged,
                event: Self.event(61, .flagsChanged, flags: [.maskCommand, .maskAlternate])))
            XCTAssertEqual(finishes, 1)
            _ = monitor.handle(type: .flagsChanged,
                event: Self.event(54, .flagsChanged, flags: .maskAlternate))
            XCTAssertFalse(monitor.isHeld)
            XCTAssertTrue(monitor.handle(type: .flagsChanged, event: Self.event(61, .flagsChanged)))
        }
    }

    func testFinishingModifierChordStillReleasesRecordingTrigger() async {
        await MainActor.run {
            let monitor = HotkeyMonitor()
            var recording = true
            monitor.canFinishWithShortcut = { recording }
            monitor.finishShortcut = .init(
                keyCode: 61, modifiers: [.maskCommand, .maskAlternate], keyLabel: "Right ⌥")
            monitor.onFinishShortcut = { _ in recording = false }
            _ = monitor.handle(type: .flagsChanged,
                event: Self.event(54, .flagsChanged, flags: .maskCommand))
            XCTAssertTrue(monitor.handle(type: .flagsChanged,
                event: Self.event(61, .flagsChanged, flags: [.maskCommand, .maskAlternate])))
            XCTAssertTrue(monitor.handle(type: .flagsChanged,
                event: Self.event(54, .flagsChanged, flags: .maskAlternate)))
            XCTAssertFalse(monitor.isHeld)
        }
    }

    func testDefaultSingleKeyBelongsToForegroundAppWhenIdle() async {
        await MainActor.run {
            let monitor = HotkeyMonitor()
            XCTAssertFalse(monitor.handle(type: .flagsChanged,
                event: Self.event(61, .flagsChanged, flags: .maskAlternate)))
            XCTAssertFalse(monitor.handle(type: .flagsChanged, event: Self.event(61, .flagsChanged)))
        }
    }

    func testSyntheticOutputNeverFinishesNewRecording() async {
        await MainActor.run {
            let monitor = HotkeyMonitor()
            monitor.canFinishWithShortcut = { true }
            monitor.finishShortcut = .init(keyCode: 36, modifiers: [], keyLabel: "Return")
            let output = Self.event(36, .keyDown)
            output.setIntegerValueField(.eventSourceUnixProcessID, value: Int64(ProcessInfo.processInfo.processIdentifier))
            XCTAssertFalse(monitor.handle(type: .keyDown, event: output))
        }
    }
}
