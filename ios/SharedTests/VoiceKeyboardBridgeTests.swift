import Foundation
import XCTest

@testable import DoNotType

final class VoiceKeyboardBridgeTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var bridge: VoiceKeyboardBridge!

    override func setUp() {
        super.setUp()
        suiteName = "VoiceKeyboardBridgeTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        bridge = VoiceKeyboardBridge(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        bridge = nil
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testColdStartRequestPersistsUntilTheAppLaunches() {
        XCTAssertFalse(bridge.requestStart())
        XCTAssertEqual(bridge.snapshot.phase, .waiting)
        XCTAssertNil(bridge.snapshot.result)
    }

    func testWarmHeartbeatMakesTheNextStartAvoidAColdLaunch() {
        bridge.touchSession()
        XCTAssertTrue(bridge.isSessionWarm)
        XCTAssertTrue(bridge.requestStart())
    }

    func testRecordingTranscribingAndResultRoundTrip() {
        bridge.requestStart()
        bridge.publishRecordingStarted()
        XCTAssertEqual(bridge.snapshot.phase, .recording)

        bridge.requestStop()
        XCTAssertEqual(bridge.snapshot.phase, .transcribing)

        bridge.publishResult("spoken words")
        XCTAssertEqual(bridge.snapshot.phase, .idle)
        XCTAssertEqual(bridge.snapshot.result, "spoken words")

        bridge.acknowledgeResult()
        XCTAssertNil(bridge.snapshot.result)
    }

    func testFailureReplacesAnOldResult() {
        bridge.publishResult("old")
        bridge.publishFailure("No speech detected")

        XCTAssertEqual(bridge.snapshot.phase, .failed)
        XCTAssertNil(bridge.snapshot.result)
        XCTAssertEqual(bridge.snapshot.message, "No speech detected")
    }

    func testEndingSessionMakesTheNextRequestCold() {
        bridge.touchSession()
        XCTAssertTrue(bridge.isSessionWarm)
        bridge.endSession()
        XCTAssertFalse(bridge.isSessionWarm)

        bridge.touchSession()
        XCTAssertTrue(bridge.isSessionWarm, "ending a session must reset heartbeat throttling")
    }

    func testStaleHeartbeatIsCold() {
        defaults.set(
            Date().addingTimeInterval(-VoiceKeyboardBridge.sessionFreshness - 1)
                .timeIntervalSince1970,
            forKey: "voiceKeyboard.heartbeat")

        XCTAssertFalse(bridge.isSessionWarm)
    }

    func testKeyboardReportsThatItAppearedWithoutFullAccess() {
        XCTAssertNil(bridge.keyboardSetupStatus.lastSeen)
        XCTAssertNil(bridge.keyboardSetupStatus.hasFullAccess)

        bridge.publishKeyboardSetupStatus(hasFullAccess: false)

        XCTAssertNotNil(bridge.keyboardSetupStatus.lastSeen)
        XCTAssertEqual(bridge.keyboardSetupStatus.hasFullAccess, false)
    }

    func testKeyboardReportsFullAccess() {
        bridge.publishKeyboardSetupStatus(hasFullAccess: true)
        XCTAssertEqual(bridge.keyboardSetupStatus.hasFullAccess, true)
    }
}
