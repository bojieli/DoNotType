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

    /// <summary>
    /// What the recording overlay says while the dictation can still be abandoned.
    /// </summary>
    /// <remarks>
    /// Empty when nothing is bound, and that is the important half: an overlay naming a key that
    /// is not intercepted is worse than one naming none, because Escape then still belongs to
    /// whatever application is in front and pressing it does something else entirely. "Esc" rather
    /// than "Escape" because this shares one line with the finish-and-send hint and the pill is not
    /// resized for it; the settings window, which has room, spells it out.
    /// </remarks>
    public static string OverlayHint(CancelShortcut shortcut) =>
        shortcut == CancelShortcut.Escape ? "Esc to cancel" : string.Empty;
}
