import XCTest

@testable import DoNotTypeCore

final class FinishAndSendActionTests: XCTestCase {
    func testEveryActionCapturesReturnOnlyWhileRecording() {
        for action in FinishAndSendAction.allCases {
            XCTAssertTrue(action.capturesReturn(whileRecording: true))
            XCTAssertFalse(action.capturesReturn(whileRecording: false))
        }
    }
}
