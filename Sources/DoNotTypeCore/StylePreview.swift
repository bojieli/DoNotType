import Foundation

/// The shape of a settings preview, and the words it is presented with.
///
/// Here rather than in each client because the four have to describe the same thing the same way —
/// somebody comparing a laptop to a phone is comparing the same product — and because *which
/// baseline to use* is a rule rather than a preference, and a rule stated once cannot drift.
///
/// The preview exists because every control in a settings panel is a *cause* and what a user needs
/// is the *effect*. The label that read `Chat — short lines, light punctuation` was describing its
/// effect accurately while being read as a mood, and the line breaks that followed were
/// untraceable from anything on screen.
public enum StylePreview {
    /// Where the left-hand pane's text comes from.
    public enum Baseline: Sendable, Equatable {
        /// A dictation already in History: its stored transcript is a real past result, is free,
        /// and is the most honest "before" there is.
        case stored
        /// A clip just recorded, which has no past. The baseline has to be computed, so it is the
        /// same audio sent with the example box emptied — the one comparison that answers "what is
        /// my example actually doing".
        case withoutExample
        /// A clip recorded while the box is empty. There is nothing to compare against, so the
        /// second request is not made: it would be the same request twice.
        case none

        public var label: String {
            switch self {
            case .stored: "What you got"
            case .withoutExample: "Without your example"
            case .none: "Your transcript"
            }
        }
    }

    public static let styledLabel = "With these settings"

    /// How many model requests a preview of a freshly recorded clip will cost.
    ///
    /// Stated as a function rather than assumed at each call site, because the answer is the
    /// difference between one request and two and the user is told which before pressing.
    public static func baseline(forClipWithExample example: String) -> Baseline {
        Typography.sanitizedSample(example).isEmpty ? .none : .withoutExample
    }

    /// What the button says it will cost. A preview is a real request, so it says so.
    public static func costNote(for baseline: Baseline) -> String {
        switch baseline {
        case .stored:
            "Sends your most recent recording again with the settings above, and shows both "
                + "answers. One request."
        case .withoutExample:
            "Records a clip, then transcribes it twice — once with your example and once without — "
                + "so you can see what the example is doing. Two requests."
        case .none:
            "Records a clip and transcribes it with the settings above. One request."
        }
    }

    /// Said where a preview cannot run at all, rather than leaving a control disabled in silence.
    public static let noStoredRecording =
        "No kept recording to try this on. Record a clip instead, or turn on Keep audio and make a "
        + "dictation."
}
