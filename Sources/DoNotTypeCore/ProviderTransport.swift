import Foundation

/// Which connection a request wants: the pooled one, or one that has never been used.
public enum ConnectionPreference: Sendable, Equatable {
    /// The connection the last request used, provided it was used recently enough to trust.
    case pooled
    /// A connection opened for this request alone. Retires the pooled one on the way past.
    ///
    /// Asked for by the two callers that already know the pooled connection is suspect: the stall
    /// hedge, and every retry after a failure.
    case fresh
}

/// Decides which connection a provider request goes out on, and when to stop trusting the one it
/// has.
///
/// ## The problem this exists for
///
/// Measured on a real history of 63 dictations: median wait 4.4 s, p75 7.5 s, then a cliff — p90
/// 52 s, p95 65 s, worst 69 s. Twenty-four percent of dictations landed above ten seconds. The
/// tail had nothing to do with how much audio was sent (a 1.5 s clip took 4.2 s; a 69.8 s clip
/// took 4.9 s) and nothing to do with the model: replaying the *same* recording and the *same*
/// screen context 102 times over twenty minutes on a warm connection gave p50 2.10 s, p95 2.62 s,
/// worst 4.07 s, and not one failure.
///
/// What the tail was is visible in the log once you look at which requests fail together. Every
/// one of the ten failure events killed two or three in-flight requests **in the same
/// millisecond** — including requests started nine, seventeen and forty seconds apart, and
/// including an unrelated settings key-probe that had nothing to do with any dictation. They were
/// all on one `URLSession.shared`, so HTTP/2 had multiplexed them onto one TCP connection. One
/// connection dies, everything on it dies.
///
/// Caught live, with a probe running against the same endpoint throughout:
///
/// ```
/// app     21:12:32.731  request 1 starts
/// app     21:12:40.945  hedge starts (stalled at 8.0 s)
/// probe   21:12:44  2.04 s ✓   21:12:53  2.21 s ✓   21:13:01  1.94 s ✓
/// probe   21:13:10  2.05 s ✓   21:13:18  2.14 s ✓   21:13:27  2.17 s ✓
/// app     21:13:32.745  request 1 FAILED ms=60013
/// app     21:13:32.745  hedge     FAILED ms=51799   ← never reached its own timeout
/// app     21:13:33.595  retry on a new connection → 4.2 s, done
/// ```
///
/// The network was fine and the model was fine. One dead pooled connection held the dictation for
/// sixty-five seconds while a new one answered in two. Note the hedge: it died at 51.8 s without
/// having timed out, because it was a second stream on the connection that died.
///
/// ## What is done about it
///
/// **Connections are trusted for ``maxIdleSeconds`` and no longer.** Every slow request in that
/// history followed a gap: nothing that came within 60 s of the previous request was ever slow
/// (0 of 26), while 16 of 42 above that were. TCP keepalive is off by default on macOS
/// (`net.inet.tcp.always_keepalive = 0`, `keepidle = 7200 s`), so a connection a NAT or proxy has
/// quietly forgotten is never probed — the app finds out by writing a dictation into it.
///
/// **The handshake is paid while the user is still speaking.** ``warmUp(_:)`` is called when
/// recording starts, not when the request is sent, and there is between one and seventy seconds of
/// speech to hide it behind. Opening a connection costs 0.91–2.26 s (median 1.15 s) measured
/// through this machine's proxy, which is why doing it on the critical path was never an option
/// and doing it here costs nothing.
///
/// Warm-up does double duty: it *validates*. A connection that has gone bad is found and replaced
/// while the user is mid-sentence, rather than eight seconds into a wait they are watching.
///
/// **A hedge or a retry gets its own connection.** `.fresh` retires the pooled connection and
/// installs a new one, so a second attempt is a genuinely independent draw rather than another
/// stream on the same dead pipe. That was the flaw that made the stall hedge useless: it fired
/// three times in that history and lost all three, each time dying in the same millisecond as the
/// request it was hedging.
///
/// ## What is deliberately not done
///
/// **No keep-alive pings.** Keeping the connection warm means guessing a timeout that belongs to
/// whatever middlebox is in the path — a proxy today, hotel wifi tomorrow — with no feedback when
/// the guess is wrong except a dictation that hangs. It costs a request every N seconds all day
/// for a tool that is idle most of the day, `URLSession` exposes no HTTP/2 PING to do it cheaply,
/// and it cannot help the case that hurts most: the first dictation after sleep, wake, or a
/// network change, when no ping was running and the connection is dead.
///
/// **Reuse is not abandoned either.** Never pooling costs 1.08 s on *every* dictation (measured:
/// 3.18 s median cold against 2.10 s warm) to fix a tail that only appears after a gap. Taxing the
/// case that already works is the wrong shape; bounding how long the connection is trusted is not.
public actor ProviderTransport {
    /// The app's transport. Providers use it unless a test hands them a session directly.
    public static let shared = ProviderTransport()

    /// How long a connection may sit unused and still be handed to a dictation.
    ///
    /// Thirty seconds against an observed clean band of sixty: no request that followed the
    /// previous one within a minute was ever slow, so this sits inside that with the margin
    /// doubled. Above it the connection is not *known* to be bad — it is merely no longer known to
    /// be good, and the cost of being wrong is asymmetric. A needless handshake costs about a
    /// second and is usually hidden by ``warmUp(_:)``; trusting a dead connection costs a minute.
    public static let maxIdleSeconds: TimeInterval = 30

    /// Idle timeout for a provider request.
    ///
    /// Was 120. A healthy request answers in 2.6 s at p95 and model time barely moves with audio
    /// length — 69.8 s of speech transcribed in 4.9 s — so two minutes was never a wait anybody
    /// wanted, only a long delay before the retry that was going to fix it. This is `URLSession`'s
    /// *idle* timeout rather than a total, so a slow upload does not trip it as long as bytes keep
    /// moving.
    public static let requestTimeoutSeconds: TimeInterval = 25

    /// Timeout for the warm-up request.
    ///
    /// Much shorter than a real request because its job is the opposite: not to wait for an answer
    /// but to find out quickly that there is not going to be one, while there is still speech left
    /// to hide the replacement behind.
    public static let warmUpTimeoutSeconds: TimeInterval = 5

    static let log = Log("transport")

    /// One pooled session per host, because "recently used" is a fact about a connection and
    /// connections are per host. Without this a rewrite through xAI would refresh the timestamp
    /// that a Gemini dictation then trusts.
    private struct Pooled {
        var session: URLSession
        var lastUsed: Date
        var warmUp: Task<Void, Never>?
    }

    private var pools: [String: Pooled] = [:]

    public init() {}

    /// The session a request to `url` should go out on.
    ///
    /// Waits for a warm-up already in flight for that host rather than racing it, so a dictation
    /// that arrives while the connection is still being opened uses the one being opened instead
    /// of starting a second.
    public func session(for url: URL, connection: ConnectionPreference = .pooled) async -> URLSession
    {
        let host = url.host ?? url.absoluteString

        if connection == .pooled, let pending = pools[host]?.warmUp {
            await pending.value
        }

        let now = Date()
        if connection == .pooled, let pooled = pools[host],
            now.timeIntervalSince(pooled.lastUsed) <= Self.maxIdleSeconds
        {
            pools[host]?.lastUsed = now
            return pooled.session
        }

        if let previous = pools[host] {
            let age = now.timeIntervalSince(previous.lastUsed)
            Self.log.debug(
                "replacing the connection",
                [
                    "host": host,
                    "reason": connection == .fresh ? "caller asked for a fresh one" : "idle",
                    "idleSeconds": String(format: "%.0f", age),
                ])
            // Lets whatever is still in flight finish — the original request of a hedged pair is
            // usually one of them, and cancelling a draw that might still answer would be the
            // opposite of the point.
            previous.session.finishTasksAndInvalidate()
        }

        let session = Self.makeSession()
        pools[host] = Pooled(session: session, lastUsed: now, warmUp: nil)
        return session
    }

    /// Opens — and thereby proves — a connection to `origin`, ahead of the request that needs it.
    ///
    /// Fire and forget. Called when recording starts; by the time the user stops speaking the
    /// connection is open and was answering seconds ago. A failure here is not reported to anyone,
    /// because nothing has been asked for yet: it simply retires the connection so the dictation
    /// that follows starts from a new one.
    public func warmUp(_ origin: URL) {
        let host = origin.host ?? origin.absoluteString
        // One at a time. Holding the key down twice in three seconds should not open two.
        if let existing = pools[host]?.warmUp, !existing.isCancelled { return }

        let now = Date()
        if let pooled = pools[host], now.timeIntervalSince(pooled.lastUsed) <= Self.maxIdleSeconds {
            return
        }
        if let previous = pools[host] { previous.session.finishTasksAndInvalidate() }

        let session = Self.makeSession()
        let task = Task { [weak self] in
            let started = Date()
            var request = URLRequest(url: origin)
            request.httpMethod = "GET"
            request.timeoutInterval = Self.warmUpTimeoutSeconds
            do {
                // Any answer will do, including a 404. The question is whether bytes come back,
                // not what they say.
                _ = try await session.data(for: request)
                Self.log.debug(
                    "connection ready",
                    [
                        "host": host,
                        "ms": LogClock.ms(Date().timeIntervalSince(started)),
                    ])
                await self?.warmUpFinished(host: host, healthy: true)
            } catch {
                // Info rather than debug: this is the app having found a dead connection before it
                // cost anybody a dictation, which is the whole point and should be visible.
                Self.log.info(
                    "connection was not usable; it will be replaced",
                    [
                        "host": host,
                        "error": error.localizedDescription,
                        "ms": LogClock.ms(Date().timeIntervalSince(started)),
                    ])
                await self?.warmUpFinished(host: host, healthy: false)
            }
        }
        pools[host] = Pooled(session: session, lastUsed: now, warmUp: task)
    }

    private func warmUpFinished(host: String, healthy: Bool) {
        guard var pooled = pools[host] else { return }
        pooled.warmUp = nil
        if healthy {
            pooled.lastUsed = Date()
            pools[host] = pooled
        } else {
            // Dated into the past so the next `session(for:)` cannot treat it as recently used.
            pooled.session.finishTasksAndInvalidate()
            pools.removeValue(forKey: host)
        }
    }

    /// The session a provider should use, honouring a test's injected one.
    ///
    /// Every provider needs these three lines and none of them should be the place the rule is
    /// decided, so it lives here: an injected session wins, otherwise the transport picks.
    public static func session(
        override: URLSession?, for url: URL, connection: ConnectionPreference
    ) async -> URLSession {
        if let override { return override }
        return await shared.session(for: url, connection: connection)
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = requestTimeoutSeconds
        // A dictation nobody is waiting for any more is not worth finishing.
        configuration.timeoutIntervalForResource = 300
        // Requests that go out together — a hedge and its original, in the days before they were
        // given separate sessions — must not queue behind each other.
        configuration.httpMaximumConnectionsPerHost = 6
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }
}

extension URL {
    /// `scheme://host[:port]` — what a connection is actually to, with the API path dropped.
    ///
    /// Warm-up needs this because opening a connection is a fact about the host, while the
    /// endpoint a provider is configured with is a path on it that costs money to call.
    public var origin: URL? {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.path = "/"
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        return components.url
    }
}
