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

    func testKeyboardPersistsTheDictateOrRewriteModeSeparatelyFromItsStyle() {
        XCTAssertNil(bridge.rewriteModeEnabled)

        bridge.setRewriteModeEnabled(true)
        XCTAssertEqual(bridge.rewriteModeEnabled, true)

        bridge.setRewriteModeEnabled(false)
        XCTAssertEqual(bridge.rewriteModeEnabled, false)
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

    func testKnownKeyboardHostsResolveToTheirPublicReturnRoutes() {
        XCTAssertEqual(
            KeyboardHostReturnURL.url(for: "com.apple.mobilenotes"),
            URL(string: "mobilenotes:"))
        XCTAssertEqual(
            KeyboardHostReturnURL.url(for: "com.tencent.xin"),
            URL(string: "weixin:"))
        XCTAssertEqual(
            KeyboardHostReturnURL.url(for: "com.openai.chat"),
            URL(string: "openai:"))
        XCTAssertEqual(
            KeyboardHostReturnURL.url(for: "ph.telegra.Telegraph"),
            URL(string: "telegram://resolve"))
    }

    func testUnknownKeyboardHostHasNoInventedReturnRoute() {
        XCTAssertNil(KeyboardHostReturnURL.url(for: "com.example.unsupported"))
    }

    func testReturnPolicyAvoidsLaunchingTransientSystemHosts() {
        let spotlight = KeyboardHostReturnPolicy.resolve("com.apple.Spotlight")
        XCTAssertFalse(spotlight.allowsBundleLaunch)
        XCTAssertEqual(spotlight.guide, .appSwitcher)

        let notes = KeyboardHostReturnPolicy.resolve("com.apple.mobilenotes")
        XCTAssertTrue(notes.allowsBundleLaunch)
        XCTAssertEqual(notes.publicURL, URL(string: "mobilenotes:"))
        XCTAssertEqual(notes.guide, .standard)
    }

    func testReturnGuideIsShownOnceUnlessTheAppReportsFailure() {
        let policy = KeyboardHostReturnPolicy.resolve("com.apple.mobilenotes")
        XCTAssertTrue(bridge.shouldPresentReturnGuide(for: policy))
        bridge.markReturnGuidePresented(for: policy)
        XCTAssertFalse(bridge.shouldPresentReturnGuide(for: policy))
    }

    func testActivationStatusExplainsSetupAndWarmth() {
        XCTAssertEqual(
            bridge.activationStatus(hasFullAccess: false, isOnline: true), .noFullAccess)

        bridge.publishAppReadiness(hasAPIKey: false, microphoneAccess: .unknown)
        XCTAssertEqual(
            bridge.activationStatus(hasFullAccess: true, isOnline: true), .notConfigured)

        bridge.publishAppReadiness(hasAPIKey: true, microphoneAccess: .denied)
        XCTAssertEqual(
            bridge.activationStatus(hasFullAccess: true, isOnline: true), .microphoneDenied)

        bridge.publishAppReadiness(hasAPIKey: true, microphoneAccess: .granted)
        XCTAssertEqual(
            bridge.activationStatus(hasFullAccess: true, isOnline: false), .offline)
        XCTAssertEqual(
            bridge.activationStatus(hasFullAccess: true, isOnline: true), .opensContainingApp)

        bridge.touchSession()
        XCTAssertEqual(bridge.activationStatus(hasFullAccess: true, isOnline: true), .ready)
    }

    func testWarmSessionDurationDefaultsAndPersists() {
        XCTAssertEqual(bridge.warmSessionDuration, .fiveMinutes)
        XCTAssertEqual(bridge.warmSessionDuration.seconds, 300)

        bridge.warmSessionDuration = .twelveHours
        XCTAssertEqual(bridge.warmSessionDuration, .twelveHours)
        XCTAssertEqual(bridge.warmSessionDuration.seconds, 43_200)

        bridge.warmSessionDuration = .untilAppCloses
        XCTAssertNil(bridge.warmSessionDuration.seconds)
    }

    func testInputContextRoundTripsAndLocatesASelection() {
        let context = VoiceKeyboardBridge.InputContext(
            documentIdentifier: "document", textBeforeSelection: "Hello ",
            selectedText: "world", textAfterSelection: "!", keyboardType: 0,
            returnKeyType: 0)
        bridge.setInputContext(context)
        XCTAssertEqual(bridge.inputContext, context)
        XCTAssertEqual(
            context.locateSelection(
                documentIdentifier: "document", selectedText: "world",
                textBeforeCursor: "Hello ", textAfterCursor: "!"),
            .selected)
        XCTAssertEqual(
            context.locateSelection(
                documentIdentifier: "document", selectedText: nil,
                textBeforeCursor: "Hello ", textAfterCursor: "world!"),
            .cursorAtStart)
        XCTAssertEqual(
            context.locateSelection(
                documentIdentifier: "document", selectedText: nil,
                textBeforeCursor: "Hello world", textAfterCursor: "!"),
            .cursorAtEnd)
    }

    func testInputContextRefusesToEditAnotherDocument() {
        let context = VoiceKeyboardBridge.InputContext(
            documentIdentifier: "original", textBeforeSelection: "A",
            selectedText: "selection", textAfterSelection: "B", keyboardType: nil,
            returnKeyType: nil)
        XCTAssertEqual(
            context.locateSelection(
                documentIdentifier: "different", selectedText: "selection",
                textBeforeCursor: "A", textAfterCursor: "B"),
            .unavailable)
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
