using DoNotType.Core;
using Xunit;

namespace DoNotType.Core.Tests;

public sealed class CancelShortcutTests
{
    [Fact]
    public void EscapeIsCapturedOnlyDuringAnActiveDictation()
    {
        Assert.True(CancelShortcutPolicy.CapturesEscape(CancelShortcut.Escape, true));
        Assert.False(CancelShortcutPolicy.CapturesEscape(CancelShortcut.Escape, false));
    }

    [Fact]
    public void DisabledNeverCapturesEscape()
    {
        Assert.False(CancelShortcutPolicy.CapturesEscape(CancelShortcut.Disabled, true));
        Assert.False(CancelShortcutPolicy.CapturesEscape(CancelShortcut.Disabled, false));
    }

    // The same four cases run in Tests/DoNotTypeCoreTests/CancelShortcutTests.swift. The overlay
    // row is the one place a user finds out that Escape is available at all, so the two desktops
    // have to word it identically or the feature has two names.

    [Fact]
    public void OverlayNamesNoKeyWhenNoneIsIntercepted()
    {
        Assert.Equal(string.Empty, CancelShortcutPolicy.OverlayHint(CancelShortcut.Disabled));
        Assert.Equal(
            string.Empty, RecordingHint.Secondary(string.Empty, CancelShortcut.Disabled));
    }

    [Fact]
    public void OverlayOffersCancelOnItsOwn()
    {
        Assert.Equal(
            "Esc to cancel", RecordingHint.Secondary(string.Empty, CancelShortcut.Escape));
    }

    [Fact]
    public void OverlayOffersSendOnItsOwn()
    {
        Assert.Equal(
            "Return to send",
            RecordingHint.Secondary("Return to send", CancelShortcut.Disabled));
    }

    [Fact]
    public void OverlayOffersSendBeforeCancel()
    {
        Assert.Equal(
            "Enter to send · Esc to cancel",
            RecordingHint.Secondary("Enter to send", CancelShortcut.Escape));
    }
}
