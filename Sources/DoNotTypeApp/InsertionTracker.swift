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
    private var learningTask: Task<Void, Never>?

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
        learningTask?.cancel()
        last = Insertion(recordID: recordID, delivered: delivered, verbatim: verbatim, at: Date())
    }

    func clear() {
        learningTask?.cancel()
        learningTask = nil
        last = nil
    }

    /// Watches the exact field span that was just inserted and reports stable spelling fixes.
    ///
    /// Two equal observations are required so deleting half a word while typing its correction is
    /// never learned. The core classifier admits spelling changes only; normal continuation,
    /// rewording and number edits produce no candidates.
    func watchForCorrections(
        to delivered: String, onLearn: @escaping @MainActor ([String]) -> Void
    ) {
        learningTask?.cancel()
        learningTask = Task { @MainActor in
            guard let initial = await AccessibilityReader.focusedTextSnapshot(),
                let anchor = CorrectionAnchor(snapshot: initial, delivered: delivered)
            else { return }

            var stable: [String] = []
            var stableObservations = 0
            let expires = Date().addingTimeInterval(60)
            while !Task.isCancelled, Date() < expires {
                try? await Task.sleep(for: .milliseconds(750))
                guard !Task.isCancelled,
                    let current = await AccessibilityReader.focusedTextSnapshot(),
                    current.pid == anchor.pid,
                    current.elementToken == anchor.elementToken,
                    let edited = anchor.insertedSegment(in: current.value)
                else { return }

                let candidates = PersonalDictionary.learnedCandidates(
                    from: anchor.original, corrected: edited)
                if candidates.isEmpty {
                    stable = []
                    stableObservations = 0
                } else if candidates == stable {
                    stableObservations += 1
                    if stableObservations >= 2 {
                        onLearn(candidates)
                        return
                    }
                } else {
                    stable = candidates
                    stableObservations = 1
                }
            }
        }
    }

    /// Deletes the inserted text, optionally replacing it with the verbatim version.
    ///
    /// Deletion is by simulated backspace rather than by setting the field's value: the target app
    /// is arbitrary and most of them do not expose a settable value, which is the same reason
    /// insertion uses the pasteboard.
    func undo(replacingWithVerbatim: Bool) async -> Bool {
        guard let insertion = last, canUndo else { return false }
        learningTask?.cancel()
        learningTask = nil
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

    // MARK: - Correction anchoring

    private struct CorrectionAnchor {
        let pid: pid_t
        let elementToken: UInt
        let prefix: String
        let suffix: String
        let original: String

        init?(snapshot: AccessibilityReader.FocusedTextSnapshot, delivered: String) {
            guard snapshot.selectionLength == 0 else { return nil }
            let value = snapshot.value as NSString
            let deliveredLength = (delivered as NSString).length
            let end = snapshot.selectionLocation
            let start = end - deliveredLength
            guard start >= 0, end <= value.length,
                value.substring(with: NSRange(location: start, length: deliveredLength)) == delivered
            else { return nil }

            pid = snapshot.pid
            elementToken = snapshot.elementToken
            prefix = value.substring(to: start)
            suffix = value.substring(from: end)
            original = delivered
        }

        func insertedSegment(in value: String) -> String? {
            guard value.hasPrefix(prefix), value.hasSuffix(suffix),
                value.utf16.count >= prefix.utf16.count + suffix.utf16.count
            else { return nil }
            let start = value.index(value.startIndex, offsetBy: prefix.count)
            let end = value.index(value.endIndex, offsetBy: -suffix.count)
            guard start <= end else { return nil }
            return String(value[start..<end])
        }
    }
}
