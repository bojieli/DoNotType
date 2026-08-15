using DoNotType.Core;
using Xunit;

namespace DoNotType.Core.Tests;

/// <summary>
/// What a person is told when a dictation fails.
/// </summary>
/// <remarks>
/// These are the sentences a user actually sees, so they are asserted as text. The rules match
/// `Sources/DoNotTypeCore/Reachability.swift` deliberately: the same failure on a laptop and a
/// desktop should read the same way, and the tests are duplicated in both languages because a
/// shared fixture would be read by whichever platform remembered to read it.
/// </remarks>
public sealed class FailureAdviceTests
{
    private static FailureAdvice.Guidance Http(int status, string body = "") =>
        FailureAdvice.Describe(
            new ProviderException($"HTTP {status}: {body}") { Status = status, Body = body });

    [Fact]
    public void OfflineIsQueuedAndNeedsNoAction()
    {
        var advice = FailureAdvice.Describe(new ProviderException("whatever"), isOnline: false);
        Assert.True(advice.IsQueued);
        Assert.False(advice.NeedsUserAction);
        Assert.Contains("reconnect", advice.Message);
    }

    [Fact]
    public void ABadKeyNeedsUserActionAndIsNotQueued()
    {
        var advice = Http(401);
        Assert.True(advice.NeedsUserAction);
        Assert.False(advice.IsRetryable);
        Assert.False(advice.IsQueued);
        Assert.Contains("Settings", advice.Message);
    }

    /// <summary>
    /// The exact response xAI returns for a bad key: a 400, not a 401. Classified by status alone
    /// it reads as a transient request problem, and the user is told to retry a dictation that is
    /// guaranteed to fail the same way.
    /// </summary>
    [Fact]
    public void ABadKeyReportedAsA400IsStillABadKey()
    {
        var advice = Http(400, "Incorrect API key provided. You can obtain one from console.x.ai.");
        Assert.True(advice.NeedsUserAction);
        Assert.False(advice.IsRetryable);
    }

    /// <summary>The reattribution above stays narrow: an ordinary 400 is this app's bug.</summary>
    [Fact]
    public void AnOrdinary400IsNotBlamedOnTheKey()
    {
        var advice = Http(400, "unsupported sample rate");
        Assert.False(advice.NeedsUserAction);
        Assert.True(advice.IsQueued);
    }

    // ---- What the provider itself said ---------------------------------------------------------

    /// <summary>
    /// A status code cannot express "this model does not accept audio input". The provider can,
    /// and it knows what it refused.
    /// </summary>
    [Fact]
    public void TheProvidersOwnExplanationSurvives()
    {
        var advice = Http(
            400, """{"error": {"message": "This model does not accept audio input."}}""");
        Assert.Contains("does not accept audio input", advice.Message);
    }

    [Fact]
    public void AMessageAtTheTopLevelIsFoundToo()
    {
        var advice = Http(404, """{"message": "Unknown model: gemini-9"}""");
        Assert.Contains("gemini-9", advice.Message);
    }

    /// <summary>A user reading an overlay is not debugging.</summary>
    [Theory]
    [InlineData("""{"trace_id": "abc123", "status": {"code": 13}}""")]
    [InlineData("<html><head><title>502 Bad Gateway</title></head></html>")]
    public void NothingUnreadableIsShown(string body)
    {
        var advice = Http(500, body);
        Assert.DoesNotContain("{", advice.Message);
        Assert.DoesNotContain("<", advice.Message);
    }

    /// <summary>
    /// A gateway answers in lower case and this leads the message, so it is capitalised on the way
    /// past — its words are what has to survive, not its typography.
    /// </summary>
    [Fact]
    public void AShortGatewayMessageIsKept()
    {
        var advice = Http(503, "upstream connect error before headers");
        Assert.Contains("upstream connect error", advice.Message.ToLowerInvariant());
    }

    [Fact]
    public void ALongMessageIsCutRatherThanFillingTheScreen()
    {
        var advice = Http(400, string.Join(" ", Enumerable.Repeat("verbose", 200)));
        Assert.True(advice.Message.Length <= 260, advice.Message);
    }

    [Fact]
    public void AMultiLineMessageBecomesOneLine()
    {
        var advice = Http(400, "it failed\nand here is why\nat length");
        Assert.DoesNotContain("\n", advice.Message);
    }

    // ---- Advice that can actually work ---------------------------------------------------------

    /// <summary>
    /// A 4xx is a request this app got wrong and will get wrong again identically. "Saved, retry
    /// from History" was offered for every unhandled one.
    /// </summary>
    [Theory]
    [InlineData(415)]
    [InlineData(422)]
    public void AnUnhandledClientErrorDoesNotPromiseARetryThatCannotWork(int status)
    {
        var advice = Http(status);
        Assert.False(advice.IsRetryable);
        Assert.Contains("not change it", advice.Message);
        // Nothing in Settings fixes a malformed request.
        Assert.False(advice.NeedsUserAction);
        Assert.True(advice.IsQueued);
    }

    [Theory]
    [InlineData(500)]
    [InlineData(502)]
    [InlineData(503)]
    [InlineData(429)]
    [InlineData(408)]
    public void AServerErrorIsStillWorthRetrying(int status)
    {
        var advice = Http(status);
        Assert.True(advice.IsRetryable);
        Assert.True(advice.IsQueued);
    }

    [Fact]
    public void ATooLargeRecordingIsNotOfferedAsARetry()
    {
        var advice = Http(413);
        Assert.False(advice.IsRetryable);
        Assert.Contains("too large", advice.Message);
    }

    [Fact]
    public void NetworkTroubleIsQueuedRatherThanBlamedOnAnybody()
    {
        var advice = FailureAdvice.Describe(new HttpRequestException("connection refused"));
        Assert.True(advice.IsQueued);
        Assert.True(advice.IsRetryable);
        Assert.False(advice.NeedsUserAction);
    }

    /// <summary>Nothing here should read as a log line.</summary>
    [Theory]
    [InlineData(401)]
    [InlineData(429)]
    [InlineData(500)]
    [InlineData(418)]
    public void EveryMessageIsASentence(int status)
    {
        var message = Http(status).Message;
        Assert.False(string.IsNullOrWhiteSpace(message));
        Assert.True(char.IsUpper(message[0]), message);
        Assert.DoesNotContain("HTTP 401:", message);
    }

    /// <summary>
    /// The retry loop and the sentence shown for the same failure have to agree. Telling somebody
    /// "saved, retry from History" about a failure the retry loop has already written off is worse
    /// than saying nothing, and the two rules live in different files.
    /// </summary>
    [Theory]
    [InlineData(400)]
    [InlineData(401)]
    [InlineData(403)]
    [InlineData(404)]
    [InlineData(408)]
    [InlineData(413)]
    [InlineData(422)]
    [InlineData(429)]
    [InlineData(500)]
    [InlineData(502)]
    [InlineData(503)]
    public void TheGuidanceAndTheRetryRuleAgreeAboutEveryStatus(int status)
    {
        var error = new ProviderException($"HTTP {status}")
        {
            Status = status,
            IsTransient = status is 408 or 429 or >= 500,
        };
        Assert.Equal(
            TranscriptionService.IsTransient(error),
            FailureAdvice.Describe(error).IsRetryable);
    }
}
