import XCTest

@testable import DoNotTypeCore

final class FinishAndSendActionTests: XCTestCase {
    func testEnabledActionsCaptureReturnOnlyWhileRecording() {
        for action in [FinishAndSendAction.returnKey, .modifiedReturn] {
            XCTAssertTrue(action.capturesReturn(whileRecording: true))
            XCTAssertFalse(action.capturesReturn(whileRecording: false))
        }
    }

    func testDisabledNeverCapturesReturn() {
        XCTAssertFalse(FinishAndSendAction.disabled.capturesReturn(whileRecording: true))
        XCTAssertFalse(FinishAndSendAction.disabled.capturesReturn(whileRecording: false))
    }
}
