import Foundation

/// The rules that turn one key press into a recording.
///
/// Lives here rather than next to the macOS event tap because it is the one piece of the gesture
/// that is pure arithmetic, it is hand-ported to three other clients, and the app target has no
/// tests. Both bugs this type exists to prevent were invisible in a running app on the machine
/// that shipped them: one was a unit conversion that is correct on Intel and wrong by 41x on Apple
/// silicon, the other was two constants that disagreed. Neither is visible by reading the call
/// site, and both are one assertion away from being obvious.
public enum PressGesture {

    /// How holding the key relates to recording.
    ///
    /// `automatic` is the default because it needs no decision from the user: a quick tap starts a
    /// hands-free recording that a second tap ends, and anything held past the threshold behaves
    /// as push-to-talk. Short utterances suit the hold; long ones suit not having to hold.
    public enum Mode: String, CaseIterable, Sendable {
        /// Record while held, stop on release.
        case pushToTalk
        /// Tap once to start, tap again to stop.
        case handsFree
        /// Tap toggles; holding past `holdThreshold` becomes push-to-talk.
        case automatic

        public var label: String {
            switch self {
            case .pushToTalk: "Hold to talk"
            case .handsFree: "Tap to start, tap to stop"
            case .automatic: "Tap to toggle, hold to talk"
            }
        }

        /// Shown in the recording overlay, so it always says how to stop.
        public var overlayHint: String {
            switch self {
            case .pushToTalk: "Release to send"
            case .handsFree: "Tap again to send"
            case .automatic: "Release or tap to send"
            }
        }
    }

    /// The shortest recording worth sending. Below this there is no utterance in the file, only
    /// the sound of a key being pressed.
    public static let minimumRecordingSeconds: TimeInterval = 0.5

    /// A press shorter than this is a tap, and a tap leaves the recording running.
    ///
    /// It is `minimumRecordingSeconds` exactly, and the two are the same number on purpose: a
    /// release may only end a recording the recorder would accept. When this was the shorter 0.25 s
    /// it read as the more comfortable choice — quicker to fall into push-to-talk — but it opened a
    /// 250 ms window where a press was long enough to be called a hold and too short to survive
    /// `minimumRecordingSeconds`. A press landing in it stopped the recording and then threw it
    /// away, so the gesture that felt most like a tap was the one guaranteed to produce nothing.
    ///
    /// Nobody says anything in under half a second, so this costs the push-to-talk user nothing:
    /// every press that used to send still sends. What changes is the outcome of a press between
    /// 0.25 s and 0.5 s, which now leaves the recording running with the overlay up saying so,
    /// instead of discarding it in silence.
    public static let holdThreshold: TimeInterval = minimumRecordingSeconds

    /// What one half of the gesture does to the recording.
    public enum Action: Equatable, Sendable {
        /// Begin recording.
        case start
        /// End the recording and transcribe it.
        case stop
        /// Leave the recording as it is. For a release, that means the press was a tap and the
        /// recording stays on until the next press.
        case nothing
    }

    /// What a key-down does.
    ///
    /// Recording starts on the press in every mode. Waiting to see whether the press becomes a
    /// hold would clip the first word off every push-to-talk dictation, which is the word people
    /// say fastest.
    public static func press(mode: Mode, isRecording: Bool) -> Action {
        guard isRecording else { return .start }
        switch mode {
        case .pushToTalk:
            return .nothing
        case .handsFree:
            return .stop  // the second tap, and it ends on the way down
        case .automatic:
            // Also the second tap, but it ends on the way *up*, so that one press cannot both end
            // the previous recording and be mistaken for the start of the next one.
            return .nothing
        }
    }

    /// What a key-up does.
    ///
    /// - Parameters:
    ///   - held: how long the key was down, from the events' own clock. See
    ///     `seconds(fromNanoseconds:to:)`.
    ///   - startedByTap: whether this press is the one that started the in-flight recording.
    public static func release(mode: Mode, held: TimeInterval, startedByTap: Bool) -> Action {
        switch mode {
        case .pushToTalk:
            return .stop
        case .handsFree:
            return .nothing  // toggling already happened on the press
        case .automatic:
            // A press that landed while already recording was the second tap of a hands-free
            // session, and ends it however briefly it was held.
            if !startedByTap { return .stop }
            return held >= holdThreshold ? .stop : .nothing
        }
    }

    /// Converts two event timestamps into the seconds between them.
    ///
    /// The timestamps have to come from the events rather than from a clock read while handling
    /// them. `handlePress` calls straight into `beginRecording`, and the first dictation of a
    /// launch pays the audio stack's cold start there — measured at ~250 ms of `AVAudioEngine`
    /// setup plus the overlay's one-off panel and the first accessibility read, ~300 ms in total.
    /// All of it runs inside the event tap callback, so the release event waits in the queue until
    /// it returns. Timed at handling time, a 40 ms tap measured as a 300 ms hold, crossed
    /// `holdThreshold`, and stopped the recording it had just started.
    ///
    /// Both arguments are **nanoseconds since startup**, which is what `CGEventTimestamp` holds:
    ///
    ///     /* Event timestamp; roughly, nanoseconds since startup. */
    ///     typedef uint64_t CGEventTimestamp;
    ///
    /// Reading them as `mach_absolute_time` ticks instead — plausible, since they are a bare
    /// `uint64_t` on the same monotonic clock — is what made the first fix worse than the bug it
    /// replaced. The two units are identical on Intel, where a mach tick is a nanosecond, so the
    /// conversion looked right everywhere it was read. On Apple silicon a tick is 125/3 ns, so
    /// every gesture was inflated 41.67x: the 0.5 s threshold was crossed by a 12 ms press, every
    /// physical press became a hold, and tap-to-toggle could not be performed by a human at all.
    public static func seconds(fromNanoseconds start: UInt64, to end: UInt64) -> TimeInterval {
        // A synthesised event can carry a zero timestamp. Reading a non-positive delta as a tap
        // leaves the recording running, which costs a second key press; reading it as a hold would
        // cut the recording off, which costs the dictation.
        guard end > start else { return 0 }
        return TimeInterval(end - start) / 1_000_000_000
    }
}
