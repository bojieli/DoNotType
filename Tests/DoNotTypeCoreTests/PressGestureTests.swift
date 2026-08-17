import XCTest

@testable import DoNotTypeCore

/// The push-to-talk gesture, which had no tests because it lived in the app target and the app
/// target has none. Both bugs pinned here shipped, and neither was visible from the call site.
final class PressGestureTests: XCTestCase {

    // MARK: - The event clock

    /// `CGEventTimestamp` is nanoseconds since startup — Apple's header says so, and a stamped
    /// event agrees with `clock_gettime_nsec_np(CLOCK_UPTIME_RAW)` to nine digits.
    ///
    /// It was read as `mach_absolute_time` ticks instead. On Intel a tick is exactly a nanosecond
    /// so the two agree; on Apple silicon a tick is 125/3 ns and every gesture came out 41.67x too
    /// long. These are the presses from one real log, in nanoseconds, with what the old conversion
    /// made of them.
    func testGestureDurationsAreNanoseconds() {
        let cases: [(nanoseconds: UInt64, seconds: TimeInterval)] = [
            (14_000_000, 0.014),  // read as 0.583 s
            (25_000_000, 0.025),  // read as 1.042 s
            (107_000_000, 0.107),  // read as 4.458 s
            (2_030_000_000, 2.03),
            (32_370_000_000, 32.37),
        ]
        for (nanoseconds, expected) in cases {
            let held = PressGesture.seconds(fromNanoseconds: 1_000, to: 1_000 + nanoseconds)
            XCTAssertEqual(held, expected, accuracy: 1e-9)
        }
    }

    /// The whole bug in one assertion: a 14 ms press is a tap, so the recording it started stays
    /// on. Under the mach-tick reading this came out as a 0.583 s hold, which ended the recording
    /// 14 ms after it began and then discarded it for being under `minimumRecordingSeconds`. Every
    /// physical press was a hold, so tap-to-toggle could not be performed by a human at all.
    func testAFourteenMillisecondPressIsATapAndKeepsRecording() {
        let held = PressGesture.seconds(fromNanoseconds: 1_000, to: 1_000 + 14_000_000)
        XCTAssertEqual(
            PressGesture.release(mode: .automatic, held: held, startedByTap: true), .nothing)
    }

    /// A synthesised event can carry a zero stamp, and the release can be stamped before the press
    /// when the two come from different sources. Reading that as a tap costs one key press;
    /// reading it as a hold costs the dictation.
    func testANonPositiveDeltaReadsAsATap() {
        XCTAssertEqual(PressGesture.seconds(fromNanoseconds: 5_000, to: 0), 0)
        XCTAssertEqual(PressGesture.seconds(fromNanoseconds: 5_000, to: 5_000), 0)
        XCTAssertEqual(PressGesture.seconds(fromNanoseconds: 5_000, to: 4_000), 0)
    }

    // MARK: - Tap and hold

    /// The invariant that closes the dead zone: a release may only end a recording the recorder
    /// would accept. While the threshold was the shorter 0.25 s, a press between the two numbers
    /// was long enough to count as a hold and too short to survive `minimumRecordingSeconds`, so
    /// it stopped the recording and then threw it away without a word.
    func testTheHoldThresholdIsNeverBelowTheShortestSendableRecording() {
        XCTAssertGreaterThanOrEqual(
            PressGesture.holdThreshold, PressGesture.minimumRecordingSeconds)
    }

    func testAPressInsideTheOldDeadZoneKeepsRecording() {
        for held in [0.26, 0.3, 0.35, 0.49] {
            XCTAssertEqual(
                PressGesture.release(mode: .automatic, held: held, startedByTap: true), .nothing,
                "a \(held)s press used to stop the recording and then discard it")
        }
    }

    func testAHoldEndsOnRelease() {
        for held in [0.5, 0.8, 3.0, 30.0] {
            XCTAssertEqual(
                PressGesture.release(mode: .automatic, held: held, startedByTap: true), .stop)
        }
    }

    // MARK: - The three modes

    func testAutomaticTogglesOnTapAndStopsOnTheSecondPressRelease() {
        // First tap starts.
        XCTAssertEqual(PressGesture.press(mode: .automatic, isRecording: false), .start)
        XCTAssertEqual(
            PressGesture.release(mode: .automatic, held: 0.08, startedByTap: true), .nothing)

        // Second tap ends it. It lands while recording, so it ends on the way up whatever the
        // finger did — one press cannot both end a recording and start the next.
        XCTAssertEqual(PressGesture.press(mode: .automatic, isRecording: true), .nothing)
        XCTAssertEqual(
            PressGesture.release(mode: .automatic, held: 0.08, startedByTap: false), .stop)
        XCTAssertEqual(
            PressGesture.release(mode: .automatic, held: 5.0, startedByTap: false), .stop)
    }

    func testPushToTalkAlwaysStopsOnRelease() {
        XCTAssertEqual(PressGesture.press(mode: .pushToTalk, isRecording: false), .start)
        XCTAssertEqual(PressGesture.press(mode: .pushToTalk, isRecording: true), .nothing)
        for held in [0.01, 0.3, 2.0] {
            XCTAssertEqual(
                PressGesture.release(mode: .pushToTalk, held: held, startedByTap: true), .stop)
        }
    }

    func testHandsFreeTogglesEntirelyOnThePress() {
        XCTAssertEqual(PressGesture.press(mode: .handsFree, isRecording: false), .start)
        XCTAssertEqual(PressGesture.press(mode: .handsFree, isRecording: true), .stop)
        for held in [0.01, 0.3, 2.0] {
            XCTAssertEqual(
                PressGesture.release(mode: .handsFree, held: held, startedByTap: true), .nothing)
        }
    }

    /// The overlay always has to say how to stop, whatever the mode.
    func testEveryModeLabelsItselfAndItsOverlayHint() {
        for mode in PressGesture.Mode.allCases {
            XCTAssertFalse(mode.label.isEmpty)
            XCTAssertFalse(mode.overlayHint(isTriggerHeld: false).isEmpty)
            XCTAssertFalse(mode.overlayHint(isTriggerHeld: true).isEmpty)
        }
    }

    func testAutomaticOverlayHintFollowsThePhysicalTrigger() {
        XCTAssertEqual(
            PressGesture.Mode.automatic.overlayHint(isTriggerHeld: true),
            "Release to transcribe")
        XCTAssertEqual(
            PressGesture.Mode.automatic.overlayHint(isTriggerHeld: false),
            "Tap to transcribe")
    }

    func testFixedModesDoNotLieAboutTheirGesture() {
        for held in [false, true] {
            XCTAssertEqual(
                PressGesture.Mode.pushToTalk.overlayHint(isTriggerHeld: held),
                "Release to transcribe")
            XCTAssertEqual(
                PressGesture.Mode.handsFree.overlayHint(isTriggerHeld: held),
                "Tap to transcribe")
        }
    }
}
