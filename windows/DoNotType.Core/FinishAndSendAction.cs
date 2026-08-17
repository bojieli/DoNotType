namespace DoNotType.Core;

/// <summary>The key emitted after insertion when Return finishes an active recording.</summary>
public enum FinishAndSendAction
{
    Disabled,
    Enter,
    ModifiedEnter,
}

/// <summary>
/// Keeps Return routing testable and prevents an opt-in recording shortcut from becoming a
/// system-wide one. Return is captured only while audio is actually being recorded.
/// </summary>
public static class FinishAndSendActionPolicy
{
    public static bool CapturesEnter(FinishAndSendAction action, bool isRecording) =>
        action != FinishAndSendAction.Disabled && isRecording;
}
