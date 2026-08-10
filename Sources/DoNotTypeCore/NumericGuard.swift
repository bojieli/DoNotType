import Foundation

/// Takes digit sequences from an audio-only transcript and puts them into a grounded one.
///
/// The suite has been consistent about where grounding goes wrong. Word-level near-misses pass —
/// names, acronym chains, jargon, brands, code-switched Mandarin — while **every** measured
/// regression has been a number: `1.5` → `2.5`, `4240` → `1024`, `4240` → `3240`. A value on
/// screen is a strong prior, and unlike a misspelled name a wrong number is not recoverable by
/// reading it; nothing in the sentence marks it as wrong.
///
/// So this is deliberately not a general "trust the audio more" mechanism. It is scoped to the one
/// span type that measurably regresses, and it takes those spans from a run that could not have
/// seen the screen at all. The two requests are independent, so the cost is tokens rather than
/// latency when they are issued concurrently.
///
/// Whether this is worth its cost is an empirical question, not an argument:
/// `dnt-eval ablate --conditions verbatim,no-context,digit-guard`.
public enum NumericGuard {
    /// A digit run, with any separators that sit *between* digits — so `3.5`, `1,024` and `16:9`
    /// survive as one token while a trailing full stop does not become part of the number.
    /// Computed rather than stored: `Regex` is not `Sendable`, and building one costs nothing
    /// next to the HTTP round trips that produced the transcripts.
    static var pattern: Regex<Substring> { /[0-9]+(?:[.,:\-][0-9]+)*/ }

    public struct Reconciliation: Sendable, Equatable {
        public var text: String
        /// Numbers taken from the audio-only run, as (was, became).
        public var corrections: [(String, String)]
        /// True when the two transcripts disagreed on how many numbers there were.
        public var skippedForMismatch: Bool

        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.text == rhs.text && lhs.skippedForMismatch == rhs.skippedForMismatch
                && lhs.corrections.map(\.0) == rhs.corrections.map(\.0)
                && lhs.corrections.map(\.1) == rhs.corrections.map(\.1)
        }
    }

    /// Replaces each number in `grounded` with the number in the same position from `audioOnly`.
    ///
    /// Positional alignment is only safe when both transcripts found the same *count* of numbers.
    /// When they disagree, one of them heard an extra figure or dropped one, and matching them up
    /// by index would move a value to somewhere it was never spoken — a worse failure than the one
    /// being fixed. In that case the grounded transcript is returned untouched and the caller can
    /// see why.
    public static func reconcile(grounded: String, audioOnly: String) -> Reconciliation {
        let groundedNumbers = numbers(in: grounded)
        let audioNumbers = numbers(in: audioOnly)

        guard !groundedNumbers.isEmpty else {
            return Reconciliation(text: grounded, corrections: [], skippedForMismatch: false)
        }
        guard groundedNumbers.count == audioNumbers.count else {
            return Reconciliation(text: grounded, corrections: [], skippedForMismatch: true)
        }

        var corrections: [(String, String)] = []
        var result = ""
        var cursor = grounded.startIndex

        for (index, match) in grounded.matches(of: pattern).enumerated() {
            let grounded_ = String(match.output)
            let spoken = audioNumbers[index]

            result += grounded[cursor..<match.range.lowerBound]
            result += spoken
            cursor = match.range.upperBound

            if grounded_ != spoken { corrections.append((grounded_, spoken)) }
        }
        result += grounded[cursor...]

        return Reconciliation(
            text: result, corrections: corrections, skippedForMismatch: false)
    }

    static func numbers(in text: String) -> [String] {
        text.matches(of: pattern).map { String($0.output) }
    }
}

extension NumericGuard {
    /// When a dictation is in the regime where a screen number is likely to overwrite a spoken one.
    ///
    /// Measured, and the two channels are not close. The same contradicting value substitutes for
    /// what the speaker said 3/10 of the time from the visible-text section and 7/10 from the caret
    /// window — the text the user has already typed into the field they are dictating into. The
    /// guard is worth its second request in both, but it is worth it far more in the second:
    ///
    /// | decoy in | without guard | with guard |
    /// |---|---|---|
    /// | visible text | 30% | 8% |
    /// | caret window | 75% | 20% |
    ///
    /// So the trigger is digits near the caret, not digits anywhere on screen. The visible text is
    /// ten times the budget and routinely contains numbers that have nothing to do with the
    /// utterance — a sidebar, a timestamp, a row count — and spending a second request on those
    /// would make the cost constant while the benefit stayed occasional.
    ///
    /// The worst case this identifies is also the most ordinary one: dictating a correction into a
    /// document that already shows the value being corrected.
    public static func isHighRisk(_ context: ScreenContext?) -> Bool {
        guard let context else { return false }
        return [context.textBeforeCaret, context.textAfterCaret, context.selectedText]
            .contains { $0?.contains(where: \.isNumber) == true }
    }
}

/// When to spend a second, screen-blind request to check the numbers.
public enum NumberCheckPolicy: String, Codable, Sendable, CaseIterable {
    case never
    /// Only when the text around the caret contains digits — where substitution is worst.
    case whenCaretHasNumbers
    case always

    public var label: String {
        switch self {
        case .never: "Never"
        case .whenCaretHasNumbers: "When the text you're editing contains numbers"
        case .always: "Always"
        }
    }

    public var detail: String {
        switch self {
        case .never:
            "Fastest. A number on screen can overwrite a number you said."
        case .whenCaretHasNumbers:
            """
            Spends a second request only in the case that measurably needs it: a value on screen \
            beside your caret substitutes for the one you spoke 75% of the time, and the check \
            cuts that to 20%.
            """
        case .always:
            "Checks every dictation, including the ones with no numbers to check."
        }
    }

    public func applies(to context: ScreenContext?) -> Bool {
        switch self {
        case .never: false
        case .always: true
        case .whenCaretHasNumbers: NumericGuard.isHighRisk(context)
        }
    }
}
