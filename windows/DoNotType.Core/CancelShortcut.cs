namespace DoNotType.Core;

/// <summary>The configured key for abandoning an active dictation.</summary>
public enum CancelShortcut
{
    Escape,
    Disabled,
}

/// <summary>
/// Keeps Escape routing testable and, most importantly, prevents it becoming an application-wide
/// shortcut. Even when configured, it is captured only while a dictation is actually in flight.
/// </summary>
public static class CancelShortcutPolicy
{
    public static bool CapturesEscape(CancelShortcut shortcut, bool dictationIsActive) =>
        shortcut == CancelShortcut.Escape && dictationIsActive;
}
