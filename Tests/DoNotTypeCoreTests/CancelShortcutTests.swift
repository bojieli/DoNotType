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
}
