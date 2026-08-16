package app.donottype.core

import kotlin.math.max
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.selects.select
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Sends a second identical request when the first one has stalled, and keeps whichever answers.
 * Port of the macOS `StallHedge`.
 *
 * Transcription latency is *bimodal* rather than slow. Six sequential requests for one three-second
 * clip took 4.9, 61.6, 50.5, 5.8, 5.9 and 30.2 seconds, with zero thought tokens throughout — that
 * is queueing, not model work. A keyboard that usually answers in five seconds and sometimes in
 * sixty is a keyboard people stop using, and the fix for a draw that landed in the tail is another
 * draw.
 *
 * A request counts as stalled once two conditions both hold: it has been running for at least
 * [FLOOR_SECONDS], *and* for at least [AUDIO_FRACTION] of the recording's own length. The floor
 * exists because eight seconds is a normal response for a short clip and re-sending it would double
 * the bill on requests that were never in trouble. The share-of-audio term exists because "slow" is
 * relative to how much speech was sent: eight seconds is a stall for a three-second clip and a good
 * pace for a four-minute one.
 *
 * Three things it deliberately is not:
 *
 * - **Not a timeout.** The first request is not abandoned at the deadline — it keeps running, and if
 *   it answers first it wins. Cancelling it would throw away a request that has already paid its
 *   queueing cost and might be one second from returning, so the same two requests would cost the
 *   same money and take longer.
 * - **Not a race from t=0.** A request answering normally is never second-guessed and never pays for
 *   a duplicate. Only the tail is hedged.
 * - **Not the provider fallback.** [FallbackTranscriber] reaches for a *different* backend on the
 *   same symptom and is off unless a second provider is configured; this one re-asks the backend the
 *   user chose, so the transcript comes from the model they picked either way.
 */
object StallHedge {
    /** No request is called stalled before this, however short the recording. */
    const val FLOOR_SECONDS = 8.0

    /** The share of the recording's own length a request may take before it counts as stalled. */
    const val AUDIO_FRACTION = 0.25

    /**
     * How long a request gets before a second one is sent alongside it.
     *
     * Unknown durations — a compressed file whose length is not readable without decoding it — get
     * the floor, which is the same answer as for any recording under 32 seconds.
     */
    fun deadlineMillis(audioSeconds: Double?): Long =
        (max(FLOOR_SECONDS, (audioSeconds ?: 0.0) * AUDIO_FRACTION) * 1_000).toLong()

    /** Non-experimental peek: the deferred is already complete or it is not. */
    private fun CompletableDeferred<Throwable>.getCompletedOrNull(): Throwable? =
        if (isCompleted) runCatching { @Suppress("OPT_IN_USAGE") getCompleted() }.getOrNull()
        else null

    /**
     * Runs [attempt], starting a second one if the first has not answered within the deadline.
     *
     * First success wins and the loser is cancelled. If both fail, the *original* request's failure
     * is the one thrown — not whichever failed first. The duplicate is this object's idea rather
     * than the caller's, so its error is a worse explanation of what is wrong: the two can differ,
     * and it is the request the caller asked for whose failure describes their setup.
     *
     * [attempt] is called twice at most, so it must be safe to run concurrently with itself — which
     * for an HTTP request it is, and for anything that writes to shared state it is not.
     */
    suspend fun <T : Any> race(
        deadlineMillis: Long,
        onHedge: () -> Unit = {},
        attempt: suspend () -> T,
    ): T {
        if (deadlineMillis <= 0) return attempt()

        return coroutineScope {
            val originalFailure = CompletableDeferred<Throwable>()

            val original = async {
                try {
                    attempt()
                } catch (cancellation: CancellationException) {
                    throw cancellation
                } catch (error: Throwable) {
                    originalFailure.complete(error)
                    null
                }
            }
            val duplicate = async {
                // Wait out the deadline, but cut it short if the original has already failed: there
                // is then nothing running to overtake, and a failure is the retry ladder's problem
                // rather than this one's — its backoff will try again sooner than the rest of this
                // delay would.
                withTimeoutOrNull(deadlineMillis) { originalFailure.await() }
                if (originalFailure.isCompleted) {
                    return@async null
                }
                // Logged by the caller: this is the app spending a second request on the user's
                // behalf, and a hedge that fires on every dictation is a backend having a bad day
                // rather than a working feature.
                onHedge()
                try {
                    attempt()
                } catch (cancellation: CancellationException) {
                    throw cancellation
                } catch (_: Throwable) {
                    null
                }
            }

            val winner = select {
                original.onAwait { it }
                duplicate.onAwait { it }
            } ?: run {
                // Whichever finished first came back empty-handed; give the other its chance.
                listOf(original, duplicate).firstNotNullOfOrNull {
                    runCatching { it.await() }.getOrNull()
                }
            }

            original.cancel()
            duplicate.cancel()

            winner ?: throw (
                originalFailure.getCompletedOrNull()
                    ?: ProviderException("Model returned no output")
                )
        }
    }
}
