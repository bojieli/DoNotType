/// What to emit after inserting a transcript finished with the configured recording shortcut.
/// `disabled` means insert only. The input shortcut is configured separately from this output.
/// Submission remains opt-in and uses the original focused field guard.
public enum FinishAndSendAction: String, CaseIterable, Sendable {
    case disabled
    case returnKey
    case modifiedReturn

    /// Legacy clients still use Return as their fixed recording-only input.
    public func capturesReturn(whileRecording isRecording: Bool) -> Bool {
        isRecording
    }
}
