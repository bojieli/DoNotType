namespace DoNotType.Core;

/// <summary>Which connection a request wants: the pooled one, or one that has never been used.</summary>
public enum ConnectionPreference
{
    /// <summary>The connection the last request used, if it was used recently enough to trust.</summary>
    Pooled,

    /// <summary>
    /// A connection opened for this request alone. Retires the pooled one on the way past.
    /// </summary>
    /// <remarks>
    /// Asked for by the two callers that already know the pooled connection is suspect: the stall
    /// hedge, and every retry after a failure.
    /// </remarks>
    Fresh,
}

/// <summary>
/// Decides which connection a provider request goes out on, and when to stop trusting the one it
/// has.
/// </summary>
/// <remarks>
/// <para>
/// Ported from the macOS <c>ProviderTransport</c>, where the problem was measured. Across 63 real
/// dictations the median wait was 4.4 s and p95 was 65 s, and the tail had nothing to do with how
/// much audio was sent -- a 1.5 s clip took 4.2 s and a 69.8 s clip took 4.9 s. Replaying one
/// recording with its screen context 102 times over twenty minutes, on connections in continuous
/// use, gave p50 2.10 s, p95 2.62 s, worst 4.07 s and no failures. The model was never the slow
/// part.
/// </para>
/// <para>
/// What the tail was is visible in which requests fail together: every failure event killed two or
/// three in-flight requests in the same millisecond, including ones started 9, 17 and 40 seconds
/// apart. They shared one pooled connection. Reproduced directly by firing two identical requests
/// at the same instant after a 150-second gap -- the reused connection timed out at 60.01 s while
/// the new one answered in 3.09 s.
/// </para>
/// <para>
/// And every slow request followed a gap: 0 of 26 that came within a minute of the previous one
/// were slow, against 16 of 42 above that. So connections are trusted for
/// <see cref="MaxIdle"/> and no longer, the handshake is paid during
/// <see cref="WarmUpAsync"/> while the user is still speaking, and a hedge or retry gets a pool of
/// its own.
/// </para>
/// <para>
/// <b>Not keep-alive pings.</b> Keeping a connection warm means guessing a timeout that belongs to
/// whatever middlebox is in the path, with no feedback when the guess is wrong except a dictation
/// that hangs -- and it cannot help the first dictation after sleep or a network change, which is
/// the case that hurts most. <b>Not abandoning reuse either:</b> never pooling costs a measured
/// 1.08 s on every request to fix a tail that only follows a gap.
/// </para>
/// <para>
/// .NET's own <c>PooledConnectionIdleTimeout</c> defaults to one minute, which lands exactly on the
/// boundary this was measured at. That is why the value is set here rather than left alone.
/// </para>
/// </remarks>
public static class ProviderTransport
{
    /// <summary>How long a connection may sit unused and still be handed to a dictation.</summary>
    /// <remarks>
    /// Thirty seconds against an observed clean band of sixty, so the margin is doubled. Above it
    /// the connection is not known to be bad -- it is merely no longer known to be good, and the
    /// cost of being wrong is asymmetric. A needless handshake costs about a second and is usually
    /// hidden by <see cref="WarmUpAsync"/>; trusting a dead connection costs a minute.
    /// </remarks>
    public static readonly TimeSpan MaxIdle = TimeSpan.FromSeconds(30);

    /// <summary>Timeout for a provider request. Was 150 seconds.</summary>
    /// <remarks>
    /// A healthy request answers in 2.6 s at p95 and model time barely moves with audio length --
    /// 69.8 s of speech transcribed in 4.9 s -- so two and a half minutes was never a wait anybody
    /// wanted, only a long delay before the retry that was going to fix it.
    /// </remarks>
    public static readonly TimeSpan RequestTimeout = TimeSpan.FromSeconds(25);

    /// <summary>Timeout for the warm-up request.</summary>
    /// <remarks>
    /// Much shorter than a real request because its job is the opposite: not to wait for an answer
    /// but to find out quickly that there is not going to be one, while there is still speech left
    /// to hide the replacement behind.
    /// </remarks>
    public static readonly TimeSpan WarmUpTimeout = TimeSpan.FromSeconds(5);

    private static readonly Log Log = new("transport");

    private sealed class Pool
    {
        public required HttpClient Client { get; set; }
        public DateTimeOffset LastUsed { get; set; }
    }

    // One pool per host, because "recently used" is a fact about a connection and connections are
    // per host. Without this a rewrite through one backend would refresh the timestamp a dictation
    // to another then trusts -- and trusting it is the entire failure mode.
    private static readonly Dictionary<string, Pool> Pools = [];
    private static readonly Lock Gate = new();

    /// <summary>The client a request to <paramref name="url"/> should go out on.</summary>
    public static HttpClient Client(Uri url, ConnectionPreference connection = ConnectionPreference.Pooled)
    {
        var host = url.Host;
        HttpClient? retired = null;

        lock (Gate)
        {
            var now = DateTimeOffset.UtcNow;
            if (connection == ConnectionPreference.Pooled
                && Pools.TryGetValue(host, out var pooled)
                && now - pooled.LastUsed <= MaxIdle)
            {
                pooled.LastUsed = now;
                return pooled.Client;
            }

            if (Pools.TryGetValue(host, out var previous))
            {
                Log.Debug(() => "replacing the connection", new Dictionary<string, string>
                {
                    ["host"] = host,
                    ["reason"] = connection == ConnectionPreference.Fresh
                        ? "caller asked for a fresh one"
                        : "idle",
                    ["idleSeconds"] = ((long)(now - previous.LastUsed).TotalSeconds).ToString(),
                });
                retired = previous.Client;
            }

            var client = NewClient();
            Pools[host] = new Pool { Client = client, LastUsed = now };
            if (retired is not null) RetireLater(retired);
            return client;
        }
    }

    /// <summary>Opens -- and thereby proves -- a connection to <paramref name="origin"/>.</summary>
    /// <remarks>
    /// Called when recording starts, so the handshake and the "is it still alive?" question are
    /// both answered against speech the user was going to produce anyway. A failure here is
    /// reported to nobody, because nothing has been asked for yet: the connection is simply
    /// replaced, and the dictation that follows starts from a new one.
    /// </remarks>
    public static async Task WarmUpAsync(Uri origin, CancellationToken cancellationToken = default)
    {
        var host = origin.Host;
        lock (Gate)
        {
            if (Pools.TryGetValue(host, out var pooled)
                && DateTimeOffset.UtcNow - pooled.LastUsed <= MaxIdle)
            {
                return;
            }
        }

        var client = Client(origin, ConnectionPreference.Fresh);
        var started = DateTimeOffset.UtcNow;
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(WarmUpTimeout);

        try
        {
            // Any answer will do, including a 404. The question is whether bytes come back, not
            // what they say.
            using var response = await client
                .GetAsync(origin, HttpCompletionOption.ResponseHeadersRead, timeout.Token)
                .ConfigureAwait(false);
            Log.Debug(() => "connection ready", new Dictionary<string, string>
            {
                ["host"] = host,
                ["ms"] = ((long)(DateTimeOffset.UtcNow - started).TotalMilliseconds).ToString(),
            });
            lock (Gate)
            {
                if (Pools.TryGetValue(host, out var pooled)) pooled.LastUsed = DateTimeOffset.UtcNow;
            }
        }
        catch (Exception error)
        {
            // Info rather than debug: this is the app having found a dead connection before it cost
            // anybody a dictation, which is the whole point and should be visible.
            Log.Info(() => "connection was not usable; it will be replaced", new Dictionary<string, string>
            {
                ["host"] = host,
                ["error"] = error.Message,
                ["ms"] = ((long)(DateTimeOffset.UtcNow - started).TotalMilliseconds).ToString(),
            });
            lock (Gate)
            {
                if (Pools.TryGetValue(host, out var pooled) && ReferenceEquals(pooled.Client, client))
                {
                    Pools.Remove(host);
                    RetireLater(client);
                }
            }
        }
    }

    /// <summary>
    /// <c>scheme://host[:port]/</c> -- what a connection is actually to, with the API path dropped.
    /// </summary>
    /// <remarks>
    /// Warm-up needs this because opening a connection is a fact about the host, while the endpoint
    /// a provider is configured with is a path on it that costs money to call.
    /// </remarks>
    public static Uri Origin(Uri url) =>
        new UriBuilder(url.Scheme, url.Host, url.Port) { Path = "/" }.Uri;

    /// <summary>
    /// Disposes a replaced client once anything still using it has had time to finish.
    /// </summary>
    /// <remarks>
    /// Not immediately: the original request of a hedged pair is usually still in flight on it, and
    /// cancelling a draw that might still answer would be the opposite of the point.
    /// </remarks>
    private static void RetireLater(HttpClient client) =>
        _ = Task.Delay(RequestTimeout + TimeSpan.FromSeconds(5))
            .ContinueWith(_ => client.Dispose(), TaskScheduler.Default);

    private static HttpClient NewClient() => new(NewHandler())
    {
        Timeout = RequestTimeout,
    };

    /// <summary>The handler policy shared by every provider connection.</summary>
    /// <remarks>
    /// API keys are carried in both standard and provider-specific headers. Automatic redirects
    /// have header-preservation rules that vary by header and runtime; refusing them prevents a
    /// provider or endpoint override from forwarding a key to an origin the user did not choose.
    /// </remarks>
    internal static SocketsHttpHandler NewHandler() =>
        new()
        {
            AllowAutoRedirect = false,
            // Belt and braces with the bookkeeping above: even inside one client, a connection this
            // old is not one to hand a dictation.
            PooledConnectionIdleTimeout = MaxIdle,
            // Nothing here needs a connection that has been alive for hours, and a bounded lifetime
            // is what lets DNS changes and failovers be noticed at all.
            PooledConnectionLifetime = TimeSpan.FromMinutes(5),
            ConnectTimeout = TimeSpan.FromSeconds(10),
        };
}
