using DoNotType.Core;
using Xunit;

namespace DoNotType.Core.Tests;

/// <summary>
/// The rules that decide which connection a dictation goes out on.
/// </summary>
/// <remarks>
/// Cheap assertions about object identity rather than anything touching a network, and that is
/// deliberate: the failure they exist to catch was invisible to every functional test the app had.
/// Transcripts were correct, retries recovered, nothing threw -- and on macOS, where this was
/// measured, a quarter of dictations took a minute because two requests shared one dead connection.
/// What went wrong was <em>which connection the request used</em>, so that is what is checked.
/// </remarks>
public class ProviderTransportTests
{
    private static readonly Uri Endpoint =
        new("https://generativelanguage.googleapis.com/v1beta/interactions");

    /// <summary>
    /// Back-to-back dictations reuse the connection. Never reusing costs a measured 1.08 s on every
    /// request, and inside the idle window there is nothing wrong with the one already open.
    /// </summary>
    [Fact]
    public void AConnectionIsReusedWhileItIsStillFresh()
    {
        var first = ProviderTransport.Client(Endpoint);
        var second = ProviderTransport.Client(Endpoint);

        Assert.Same(first, second);
    }

    /// <summary>
    /// The whole point. A caller that knows the pooled connection is suspect -- the stall hedge, or
    /// any retry after a failure -- must not be handed it back.
    /// </summary>
    [Fact]
    public void AskingForAFreshConnectionReplacesThePooledOne()
    {
        var pooled = ProviderTransport.Client(new Uri("https://fresh.example.com/v1"));
        var fresh = ProviderTransport.Client(
            new Uri("https://fresh.example.com/v1"), ConnectionPreference.Fresh);

        Assert.NotSame(pooled, fresh);
    }

    /// <summary>And the replacement sticks: the next ordinary request uses the new connection.</summary>
    [Fact]
    public void TheFreshConnectionBecomesThePooledOne()
    {
        var host = new Uri("https://sticks.example.com/v1");
        ProviderTransport.Client(host);
        var fresh = ProviderTransport.Client(host, ConnectionPreference.Fresh);
        var next = ProviderTransport.Client(host);

        Assert.Same(fresh, next);
    }

    /// <summary>
    /// Two backends, two connections. Without this a rewrite through one provider would refresh the
    /// "recently used" timestamp that a dictation to another then trusts -- and trusting it is the
    /// entire failure mode.
    /// </summary>
    [Fact]
    public void HostsDoNotShareAConnection()
    {
        var google = ProviderTransport.Client(Endpoint);
        var xai = ProviderTransport.Client(new Uri("https://api.x.ai/v1/stt"));

        Assert.NotSame(google, xai);
    }

    /// <summary>
    /// The window is bounded, and the bound is the measured one: no request that followed the
    /// previous one inside a minute was ever slow, and thirty seconds doubles that margin.
    /// </summary>
    [Fact]
    public void TheIdleWindowIsThirtySeconds()
    {
        Assert.Equal(TimeSpan.FromSeconds(30), ProviderTransport.MaxIdle);
    }

    /// <summary>
    /// Two and a half minutes was never a wait anybody wanted -- a healthy request answers in 2.6 s
    /// at p95 -- only a long delay before the retry that was going to fix it.
    /// </summary>
    [Fact]
    public void TheRequestTimeoutIsNotTwoAndAHalfMinutes()
    {
        Assert.Equal(TimeSpan.FromSeconds(25), ProviderTransport.RequestTimeout);
        Assert.True(
            ProviderTransport.WarmUpTimeout < ProviderTransport.RequestTimeout,
            "warm-up exists to find a dead connection fast, not to wait for a slow one");
    }

    /// <summary>
    /// Warm-up opens a connection to the host and must not call the API path: any answer from the
    /// host proves the connection, while a GET to the endpoint would be a real request with a real
    /// bill attached.
    /// </summary>
    [Fact]
    public void TheWarmUpTargetIsTheHostAndNotTheEndpoint()
    {
        Assert.Equal(
            "https://generativelanguage.googleapis.com/", ProviderTransport.Origin(Endpoint).ToString());
    }

    /// <summary>A non-default port is part of which connection this is, so it survives.</summary>
    [Fact]
    public void AnOriginKeepsItsPort()
    {
        Assert.Equal(
            "http://localhost:8000/",
            ProviderTransport.Origin(new Uri("http://localhost:8000/v1/chat/completions")).ToString());
    }

    /// <summary>
    /// Every backend the app ships knows where it will be connecting, so every one of them can be
    /// warmed. A provider returning null here would silently go back to paying for the handshake in
    /// front of the user.
    /// </summary>
    [Fact]
    public void EveryShippedProviderKnowsItsOrigin()
    {
        ITranscriptionProvider[] providers =
        [
            new GeminiProvider("k"),
            new OpenAiCompatibleProvider(
                "openrouter", "https://openrouter.ai/api/v1/chat/completions", "k", "m"),
            new DeepgramProvider("k"),
            new MistralProvider("k"),
            new XAISpeechProvider("k"),
        ];

        foreach (var provider in providers)
        {
            Assert.True(provider.EndpointOrigin is not null, $"{provider.Name} cannot be warmed up");
            Assert.Equal("/", provider.EndpointOrigin!.AbsolutePath);
        }
    }
}
