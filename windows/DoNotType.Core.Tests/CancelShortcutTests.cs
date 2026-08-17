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
}
