using DoNotType.Core;
using Xunit;

namespace DoNotType.Core.Tests;

public sealed class FinishAndSendActionTests
{
    [Theory]
    [InlineData(FinishAndSendAction.Enter)]
    [InlineData(FinishAndSendAction.ModifiedEnter)]
    public void EnabledActionsCaptureEnterOnlyWhileRecording(FinishAndSendAction action)
    {
        Assert.True(FinishAndSendActionPolicy.CapturesEnter(action, true));
        Assert.False(FinishAndSendActionPolicy.CapturesEnter(action, false));
    }

    [Fact]
    public void DisabledNeverCapturesEnter()
    {
        Assert.False(FinishAndSendActionPolicy.CapturesEnter(FinishAndSendAction.Disabled, true));
        Assert.False(FinishAndSendActionPolicy.CapturesEnter(FinishAndSendAction.Disabled, false));
    }
}
