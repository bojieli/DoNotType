using DoNotType.Core;
using Xunit;

namespace DoNotType.Core.Tests;

public sealed class FinishAndSendActionTests
{
    [Theory]
    [InlineData(FinishAndSendAction.Disabled)]
    [InlineData(FinishAndSendAction.Enter)]
    [InlineData(FinishAndSendAction.ModifiedEnter)]
    public void EveryActionCapturesEnterOnlyWhileRecording(FinishAndSendAction action)
    {
        Assert.True(FinishAndSendActionPolicy.CapturesEnter(action, true));
        Assert.False(FinishAndSendActionPolicy.CapturesEnter(action, false));
    }
}
