/// What to press after a transcript has been inserted when the user finishes a recording with
/// Return. `disabled` means insert only; it does not disable Return as a recording control.
///
/// Sending is opt-in because Return is often meaningful while somebody is composing. The physical
/// key is captured only during recording; at idle and during transcription it remains the
/// foreground application's key.
public enum FinishAndSendAction: String, CaseIterable, Sendable {
    case disabled
    case returnKey
    case modifiedReturn

    public func capturesReturn(whileRecording isRecording: Bool) -> Bool {
        isRecording
    }
}
