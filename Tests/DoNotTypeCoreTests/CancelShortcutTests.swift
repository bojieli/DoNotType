import XCTest

@testable import DoNotTypeCore

final class CancelShortcutTests: XCTestCase {
    func testEscapeIsCapturedOnlyDuringAnActiveDictation() {
        XCTAssertTrue(CancelShortcut.escape.capturesEscape(whileDictationIsActive: true))
        XCTAssertFalse(CancelShortcut.escape.capturesEscape(whileDictationIsActive: false))
    }

    func testDisabledNeverCapturesEscape() {
        XCTAssertFalse(CancelShortcut.disabled.capturesEscape(whileDictationIsActive: true))
        XCTAssertFalse(CancelShortcut.disabled.capturesEscape(whileDictationIsActive: false))
    }

    // The same four cases run in DoNotType.Core.Tests/CancelShortcutTests.cs. The overlay row is
    // the one place a user finds out that Escape is available at all, so the two desktops have to
    // word it identically or the feature has two names.

    func testOverlayNamesNoKeyWhenNoneIsIntercepted() {
        XCTAssertEqual(CancelShortcut.disabled.overlayHint, "")
        XCTAssertEqual(
            RecordingHint.secondary(finish: "", cancel: .disabled), "")
    }

    func testOverlayOffersCancelOnItsOwn() {
        XCTAssertEqual(
            RecordingHint.secondary(finish: "", cancel: .escape), "Esc to cancel")
    }

    func testOverlayOffersSendOnItsOwn() {
        XCTAssertEqual(
            RecordingHint.secondary(finish: "Return to send", cancel: .disabled),
            "Return to send")
    }

    func testOverlayOffersSendBeforeCancel() {
        XCTAssertEqual(
            RecordingHint.secondary(finish: "Enter to send", cancel: .escape),
            "Enter to send · Esc to cancel")
    }
}
