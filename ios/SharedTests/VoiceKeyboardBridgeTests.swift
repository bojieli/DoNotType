import DoNotTypeCore
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

    func testKeyboardPersistsTheModeSeparatelyFromWhatEachModeProduces() {
        XCTAssertNil(bridge.liveMode, "nil is an install that has never chosen, not Dictate")

        for mode in LiveMode.allCases {
            bridge.setLiveMode(mode)
            XCTAssertEqual(bridge.liveMode, mode)
        }
    }

    /// An install that used the two-state switch keeps whichever half of it it was on. Reading the
    /// old key rather than resetting matters: the chip is the control people set once.
    func testTheOldTwoStateSwitchMigratesIntoTheMode() {
        defaults.set(true, forKey: "voiceKeyboard.rewriteModeEnabled")
        XCTAssertEqual(bridge.liveMode, .rewrite)

        defaults.set(false, forKey: "voiceKeyboard.rewriteModeEnabled")
        XCTAssertEqual(bridge.liveMode, .dictate)

        // A choice made since then wins over the migrated one.
        bridge.setLiveMode(.translate)
        XCTAssertEqual(bridge.liveMode, .translate)
    }

    /// The keyboard cannot read the app's Keychain, so the app publishes which case the shared rule
    /// landed on and the keyboard rebuilds the sentence from it. The wording stays in one place.
    func testTheKeyboardLearnsWhyASecondStageCannotRun() {
        XCTAssertEqual(bridge.secondStageBlocker, .none)
        XCTAssertTrue(
            bridge.secondStageBlocker.availability(for: .rewrite, translationTarget: "")
                .isAvailable)

        bridge.publishSecondStageBlocker(SecondStageBlocker(.noKey(.rewriting)))
        XCTAssertEqual(bridge.secondStageBlocker, .noKey)
        XCTAssertEqual(
            bridge.secondStageBlocker.availability(for: .translate, translationTarget: "French"),
            .noKey(.translating),
            "the job is whichever mode is asking, not the one the app happened to resolve")

        bridge.publishSecondStageBlocker(
            SecondStageBlocker(.backendCannotRewrite(.deepgram, .rewriting)))
        XCTAssertEqual(bridge.secondStageBlocker, .backend(.deepgram))

        bridge.publishSecondStageBlocker(SecondStageBlocker(.available))
        XCTAssertEqual(bridge.secondStageBlocker, .none)
    }

    /// Dictation has no second stage to be missing, and Translate needs a language before it needs
    /// a backend — the same order `LiveMode.availability` uses on Android.
    func testTheKeyboardCanAlwaysDictateAndNeedsALanguageToTranslate() {
        bridge.publishSecondStageBlocker(SecondStageBlocker(.noKey(.rewriting)))
        XCTAssertTrue(
            bridge.secondStageBlocker.availability(for: .dictate, translationTarget: "")
                .isAvailable)

        bridge.publishSecondStageBlocker(SecondStageBlocker(.available))
        XCTAssertEqual(
            bridge.secondStageBlocker.availability(for: .translate, translationTarget: " "),
            .noTargetLanguage)
    }

    func testKeyboardPersistsAndClearsTheCallingApplication() {
        XCTAssertNil(bridge.returnHostBundleIdentifier)

        bridge.setReturnHostBundleIdentifier("com.apple.mobilenotes")
        XCTAssertEqual(bridge.returnHostBundleIdentifier, "com.apple.mobilenotes")

        bridge.setReturnHostBundleIdentifier(nil)
        XCTAssertNil(bridge.returnHostBundleIdentifier)
    }

    func testKeyboardRejectsNullHostPlaceholders() {
        for placeholder in ["<null>", "(null)", "null", "nil", "", "not-a-bundle-id"] {
            bridge.setReturnHostBundleIdentifier(placeholder)
            XCTAssertNil(bridge.returnHostBundleIdentifier, placeholder)
        }
    }

    func testKeyboardIgnoresAPreviouslyPersistedNullHostPlaceholder() {
        defaults.set("<null>", forKey: "voiceKeyboard.returnHostBundleIdentifier")
        XCTAssertNil(bridge.returnHostBundleIdentifier)
    }

    func testCancelReturnsTheSharedStateToIdle() {
        bridge.requestStart()
        bridge.publishRecordingStarted()
        bridge.requestStop()
        XCTAssertEqual(bridge.snapshot.phase, .transcribing)

        bridge.requestCancel()
        XCTAssertEqual(bridge.snapshot.phase, .idle)
        XCTAssertNil(bridge.snapshot.result)
    }
}
