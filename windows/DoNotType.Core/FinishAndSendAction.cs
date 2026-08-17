namespace DoNotType.Core;

/// <summary>
/// The key emitted after insertion when Enter finishes an active recording. Disabled means insert
/// only; it does not disable Enter as a recording control.
/// </summary>
public enum FinishAndSendAction
{
    Disabled,
    Enter,
    ModifiedEnter,
}

/// <summary>
/// Keeps Enter routing testable and prevents a recording shortcut from becoming a system-wide one.
/// Enter is captured only while audio is actually being recorded.
/// </summary>
public static class FinishAndSendActionPolicy
{
    public static bool CapturesEnter(FinishAndSendAction action, bool isRecording) => isRecording;
}
