namespace DoNotType.Core;

/// <summary>
/// The recording overlay's second row: the keys that can still act on a dictation under way.
/// </summary>
/// <remarks>
/// <para>
/// Composed here rather than at each call site because there are two call sites per desktop and
/// two desktops, the row is one line, and a hint that is missing is a feature the user does not
/// know they have. Cancelling mid-recording was reachable on both desktops long before anything on
/// screen said so.
/// </para>
/// <para>
/// The key names themselves are not here. macOS says Return and Windows says Enter, which is what
/// is printed on each keyboard, so naming that key belongs to the client. What belongs here is the
/// order and the join, so the row cannot read one way on one platform and another on the other.
/// The Swift port is <c>Sources/DoNotTypeCore/RecordingHint.swift</c>.
/// </para>
/// </remarks>
public static class RecordingHint
{
    /// <summary>
    /// A middle dot rather than a comma: two independent offers, not a list. A comma inside a hint
    /// reads as a sentence that was cut short.
    /// </summary>
    public const string Separator = " · ";

    /// <param name="finish">
    /// The finish-and-send hint in this platform's own key name, or empty when the action is off —
    /// which is its default, since sending a message is not something to do by accident.
    /// </param>
    /// <param name="cancel">The configured cancel shortcut.</param>
    public static string Secondary(string finish, CancelShortcut cancel) =>
        string.Join(
            Separator,
            new[] { finish, CancelShortcutPolicy.OverlayHint(cancel) }
                .Where(part => !string.IsNullOrEmpty(part)));
}
