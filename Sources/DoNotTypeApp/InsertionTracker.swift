import AppKit
import DoNotTypeCore
import Foundation

/// Remembers the last thing inserted, so it can be taken back.
///
/// This is the feature the project's whole design makes cheap. The verbatim transcript is stored
/// before anything is done to it, so "that came out wrong" or "that rewrite was too formal" is a
/// key press rather than a retype. A tool that discards what you said cannot offer this at all,
/// which is precisely the difference being argued.
@MainActor
final class InsertionTracker {
    struct Insertion {
        let recordID: UUID
        /// What was actually put into the field.
        let delivered: String
        /// The verbatim transcript, which may differ when a rewrite was applied.
        let verbatim: String
        let at: Date

        /// True when reverting would produce different text.
        var hasVerbatimAlternative: Bool { delivered != verbatim }
    }

    private(set) var last: Insertion?

    /// How long an insertion stays revertible.
    ///
    /// Not forever: deleting characters from a field the user has since moved away from would
    /// destroy unrelated text. A minute covers "that's wrong, undo it" and expires long before the
    /// caret has plausibly moved somewhere dangerous.
    private static let window: TimeInterval = 60

    var canUndo: Bool {
        guard let last else { return false }
        return Date().timeIntervalSince(last.at) < Self.window
    }

    var canRevertToVerbatim: Bool {
        canUndo && last?.hasVerbatimAlternative == true
    }

    func record(recordID: UUID, delivered: String, verbatim: String) {
        last = Insertion(recordID: recordID, delivered: delivered, verbatim: verbatim, at: Date())
    }

    func clear() { last = nil }

    /// Deletes the inserted text, optionally replacing it with the verbatim version.
    ///
    /// Deletion is by simulated backspace rather than by setting the field's value: the target app
    /// is arbitrary and most of them do not expose a settable value, which is the same reason
    /// insertion uses the pasteboard.
    func undo(replacingWithVerbatim: Bool) async -> Bool {
        guard let insertion = last, canUndo else { return false }
        last = nil

        await TextInjector.deleteBackward(count: insertion.delivered.count)
        if replacingWithVerbatim, insertion.hasVerbatimAlternative {
            await TextInjector.insert(insertion.verbatim)
            // The verbatim text is now what is in the field, so undoing again should remove it
            // rather than swapping back and forth.
            last = Insertion(
                recordID: insertion.recordID, delivered: insertion.verbatim,
                verbatim: insertion.verbatim, at: Date())
        }
        return true
    }
}
