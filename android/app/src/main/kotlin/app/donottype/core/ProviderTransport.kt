package app.donottype.core

import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.ConcurrentHashMap

/**
 * Decides how long a connection is trusted, and opens one before the dictation needs it.
 *
 * ## The problem this exists for
 *
 * Ported from the macOS `ProviderTransport`, where it was measured. Across 63 real dictations the
 * median wait was 4.4 s and p95 was 65 s, and the tail had nothing to do with how much audio was
 * sent — a 1.5 s clip took 4.2 s and a 69.8 s clip took 4.9 s. Replaying one recording with its
 * screen context 102 times over twenty minutes, on connections in continuous use, gave p50 2.10 s,
 * p95 2.62 s, worst 4.07 s and no failures. The model was never the slow part.
 *
 * What the tail was is visible in which requests fail together: every failure event killed the
 * in-flight requests at the same millisecond, because they shared one pooled connection. Reproduced
 * directly by firing two identical requests at the same instant after a 150-second gap — the reused
 * connection timed out at 60.01 s while the new one answered in 3.09 s.
 *
 * And every slow request followed a gap: 0 of 26 that came within a minute of the previous one were
 * slow, against 16 of 42 above that. A keepalive-less connection that a NAT or a carrier has quietly
 * forgotten is never probed. The app finds out by writing a dictation into it.
 *
 * ## What is done about it here
 *
 * **The handshake is paid while the user is still speaking.** [warmUp] runs when recording starts,
 * and there is between one and seventy seconds of speech to hide it behind. It validates as well as
 * opens: a connection that has gone bad fails the warm-up inside [WARM_UP_TIMEOUT_MS] and is dropped
 * from the pool by that failure, so the dictation that follows starts from a new one.
 *
 * **A connection past [MAX_IDLE_MS] is not carried forward.** A request made after the window sends
 * `Connection: close`, so a socket nobody can vouch for is used at most once more and never becomes
 * the one the *next* dictation inherits.
 *
 * **The read timeout is 25 s, not 120.** A healthy request answers in 2.6 s at p95 and model time
 * barely moves with audio length, so two minutes was never a wait anybody wanted — only a long delay
 * before the retry that was going to fix it.
 *
 * ## What Android cannot do, and is not pretended
 *
 * `HttpURLConnection` exposes no way to demand a connection that has never been used: the pool is
 * OkHttp's, inside the platform, and picking from it is not the caller's decision. So the macOS and
 * Windows `ConnectionPreference.Fresh` — a hedge or a retry given a pool of its own — has no exact
 * equivalent here, and this file does not fake one. What replaces it is that a failed exchange
 * evicts its own connection, which is why a retry recovers, plus the warm-up above turning "find out
 * during the dictation" into "find out during the sentence".
 *
 * **No keep-alive pings.** Keeping a connection warm means guessing a timeout belonging to whatever
 * middlebox is in the path, with no feedback when the guess is wrong except a dictation that hangs,
 * and it cannot help the first dictation after the screen has been off — which on a phone is most of
 * them.
 */
object ProviderTransport {
    private val log = Log("transport")

    /**
     * How long a connection may sit unused and still be trusted.
     *
     * Thirty seconds against an observed clean band of sixty, so the margin is doubled. Past it the
     * connection is not known to be bad — it is merely no longer known to be good, and the cost of
     * being wrong is asymmetric. A needless handshake costs about a second and is usually hidden by
     * [warmUp]; trusting a dead connection costs a minute.
     */
    const val MAX_IDLE_MS = 30_000L

    /** Read timeout for a provider request. Was 120 seconds. */
    const val REQUEST_TIMEOUT_MS = 25_000

    /** Connect timeout. A handshake that has not landed in ten seconds is not going to. */
    const val CONNECT_TIMEOUT_MS = 10_000

    /**
     * Timeout for the warm-up request.
     *
     * Much shorter than a real request because its job is the opposite: not to wait for an answer
     * but to find out quickly that there is not going to be one, while there is still speech left to
     * hide the replacement behind.
     */
    const val WARM_UP_TIMEOUT_MS = 5_000

    private val lastUsed = ConcurrentHashMap<String, Long>()

    /** `scheme://host[:port]/` — what a connection is actually to, with the API path dropped. */
    fun origin(endpoint: String): String? {
        val url = runCatching { URL(endpoint) }.getOrNull() ?: return null
        val port = if (url.port == -1) "" else ":${url.port}"
        return "${url.protocol}://${url.host}$port/"
    }

    /** True when nothing has used this host recently enough for its connection to be trusted. */
    fun isStale(host: String, now: Long = System.currentTimeMillis()): Boolean {
        val seen = lastUsed[host] ?: return true
        return now - seen > MAX_IDLE_MS
    }

    /**
     * Applies the connection policy to a request that is about to be made.
     *
     * Called from every client, so the timeouts and the staleness rule live in one place rather than
     * in five copies that drift.
     */
    fun HttpURLConnection.applyPolicy(endpoint: String) {
        connectTimeout = CONNECT_TIMEOUT_MS
        readTimeout = REQUEST_TIMEOUT_MS

        val host = runCatching { URL(endpoint).host }.getOrNull() ?: return
        if (isStale(host)) {
            // Used at most once more, and never inherited by the next dictation. The platform will
            // not let this request pick a different socket, but it can be stopped from making a
            // socket nobody can vouch for into the one that is waiting next time.
            setRequestProperty("Connection", "close")
            log.debug(mapOf("host" to host)) { "connection not trusted; not keeping it" }
        }
        lastUsed[host] = System.currentTimeMillis()
    }

    /**
     * Opens — and thereby proves — a connection to the host, ahead of the request that needs it.
     *
     * Blocking; call it from an IO dispatcher. Fire and forget: a failure here is reported to nobody
     * because nothing has been asked for yet. Its value is the failure happening now, against speech
     * the user was going to produce anyway, rather than in front of them afterwards.
     */
    fun warmUp(endpoint: String) {
        val origin = origin(endpoint) ?: return
        val host = runCatching { URL(origin).host }.getOrNull() ?: return
        if (!isStale(host)) return

        val startedAt = System.currentTimeMillis()
        var connection: HttpURLConnection? = null
        try {
            connection = (URL(origin).openConnection() as HttpURLConnection).apply {
                requestMethod = "GET"
                connectTimeout = WARM_UP_TIMEOUT_MS
                readTimeout = WARM_UP_TIMEOUT_MS
            }
            // Any answer will do, including a 404. The question is whether bytes come back, not what
            // they say.
            val status = connection.responseCode
            lastUsed[host] = System.currentTimeMillis()
            log.debug(
                mapOf(
                    "host" to host,
                    "status" to status.toString(),
                    "ms" to (System.currentTimeMillis() - startedAt).toString(),
                )
            ) { "connection ready" }
        } catch (error: Exception) {
            // Info rather than debug: this is the app having found a dead connection before it cost
            // anybody a dictation, which is the whole point and should be visible. The failed
            // exchange is also what drops the socket out of the platform's pool.
            lastUsed.remove(host)
            log.info(
                mapOf(
                    "host" to host,
                    "error" to (error.message ?: error.javaClass.simpleName),
                    "ms" to (System.currentTimeMillis() - startedAt).toString(),
                )
            ) { "connection was not usable; it will be replaced" }
        } finally {
            connection?.disconnect()
        }
    }

    /** Forgets what it knows about every host. For tests, which must not inherit each other's state. */
    fun reset() = lastUsed.clear()
}
