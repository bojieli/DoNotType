package app.donottype.core

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.coroutines.selects.select

/**
 * Runs a second backend when the first one is taking too long, and returns whichever answers.
 * Port of the macOS `FallbackTranscriber`.
 *
 * The first-party Gemini API is the most accurate backend measured and its latency is *bimodal*
 * rather than slow: six sequential requests for one three-second clip took 4.9, 61.6, 50.5, 5.8,
 * 5.9 and 30.2 seconds, with zero thought tokens throughout. A keyboard that usually answers in
 * five seconds and sometimes in sixty is a keyboard people stop using.
 *
 * Three deliberate choices, the same as on the other platforms:
 *
 * - **Hedges rather than racing.** Racing from the start would mean the fast backend nearly always
 *   wins, which is "use the fast backend" at double the cost. A primary answering normally is never
 *   second-guessed and never pays for a second request.
 * - **Attributed, not silent.** The result names the backend that answered, and history records
 *   that rather than the one that was asked.
 * - **Off by default**, with the delay configurable, because that delay is the accuracy-against-
 *   latency dial and the right value depends on which two backends are paired.
 */
class FallbackTranscriber(
    private val primary: Transcriber,
    private val secondary: Transcriber? = null,
    private val hedgeAfterMillis: Long = 8_000,
) {
    /** One backend, already configured with its instruction, fidelity and keyterms. */
    fun interface Transcriber {
        suspend fun transcribe(): TranscriptionResult
    }

    data class Attribution(val provider: String, val model: String, val wasFallback: Boolean)

    data class Outcome(val result: TranscriptionResult, val attribution: Attribution)

    /** Non-experimental peek: the deferred is already complete or it is not. */
    private fun CompletableDeferred<Throwable>.getCompletedOrNull(): Throwable? =
        if (isCompleted) runCatching { @Suppress("OPT_IN_USAGE") getCompleted() }.getOrNull()
        else null

    /**
     * First success wins. A primary that *fails* hands over immediately rather than burning the
     * hedge delay — there is nothing left to wait for. If both fail the primary's error is thrown,
     * because that is the backend the user chose and its error explains their configuration.
     */
    suspend fun transcribe(
        primaryName: String,
        primaryModel: String,
        secondaryName: String = "",
        secondaryModel: String = "",
    ): Outcome = coroutineScope {
        val fallback = secondary
            ?: return@coroutineScope Outcome(
                primary.transcribe(),
                Attribution(primaryName, primaryModel, wasFallback = false),
            )

        val primaryError = CompletableDeferred<Throwable>()

        val first = async {
            try {
                Outcome(primary.transcribe(), Attribution(primaryName, primaryModel, false))
            } catch (cancellation: CancellationException) {
                throw cancellation
            } catch (error: Throwable) {
                primaryError.complete(error)
                null
            }
        }
        val second = async {
            // Wait out the hedge delay, but cut it short if the primary has already failed —
            // there is then nothing left to wait for.
            withTimeoutOrNull(hedgeAfterMillis) { primaryError.await() }
            try {
                Outcome(fallback.transcribe(), Attribution(secondaryName, secondaryModel, true))
            } catch (cancellation: CancellationException) {
                throw cancellation
            } catch (_: Throwable) {
                null
            }
        }

        val winner = select {
            first.onAwait { it }
            second.onAwait { it }
        } ?: run {
            // Whichever finished first came back empty-handed; give the other its chance.
            listOf(first, second).firstNotNullOfOrNull { runCatching { it.await() }.getOrNull() }
        }

        first.cancel()
        second.cancel()

        // The primary's error is the one that explains the user's configuration, so it is the one
        // they see. `runCatching` rather than `getCompleted()` to stay off the experimental API.
        winner ?: throw (
            runCatching { primaryError.getCompletedOrNull() }.getOrNull()
                ?: ProviderException("Model returned no output")
            )
    }
}
