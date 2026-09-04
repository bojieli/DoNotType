package app.donottype.core

import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.system.measureTimeMillis

/**
 * The Kotlin port of `FallbackTranscriber` has to behave like the Swift one.
 *
 * These are the same cases as `Tests/DoNotTypeCoreTests/FallbackTranscriberTests.swift`: a hedge
 * that fires at a different moment on one platform means the Android app has a different latency
 * profile from the one the evaluation describes.
 *
 * `runBlocking` with millisecond delays rather than `runTest` on a virtual clock, to avoid adding
 * kotlinx-coroutines-test for five tests. The Swift port does the same, and the delays are short
 * enough that the suite stays fast.
 */
class FallbackTranscriberTest {

    private fun backend(delayMillis: Long, text: String, failure: Throwable? = null) =
        FallbackTranscriber.Transcriber {
            delay(delayMillis)
            failure?.let { throw it }
            TranscriptionResult(Transcript(text, "en"), TokenUsage(), text)
        }

    /** The common case: the primary answers normally, so the hedge never fires and never bills. */
    @Test
    fun `a fast primary is never second guessed`() = runBlocking {
        val outcome = FallbackTranscriber(
            primary = backend(10, "primary"),
            secondary = backend(10, "secondary"),
            hedgeAfterMillis = 5_000,
        ).transcribe("primary", "p-model", "secondary", "s-model")

        assertEquals("primary", outcome.result.transcript.transcript)
        assertFalse(outcome.attribution.wasFallback)
        assertEquals("primary", outcome.attribution.provider)
    }

    /** The case this exists for: the primary stalls, the hedge fires, the user gets words. */
    @Test
    fun `a stalled primary is overtaken by the hedge`() = runBlocking {
        val outcome = FallbackTranscriber(
            primary = backend(5_000, "primary"),
            secondary = backend(20, "secondary"),
            hedgeAfterMillis = 20,
        ).transcribe("primary", "p-model", "secondary", "s-model")

        assertEquals("secondary", outcome.result.transcript.transcript)
        assertTrue("the caller has to be able to say so", outcome.attribution.wasFallback)
        assertEquals("secondary", outcome.attribution.provider)
    }

    /** Nothing left to wait for: a failing primary hands over without burning the delay. */
    @Test
    fun `a failing primary falls back without waiting out the delay`() = runBlocking {
        lateinit var outcome: FallbackTranscriber.Outcome
        val elapsedMillis = measureTimeMillis {
            outcome = FallbackTranscriber(
                primary = backend(5, "", ProviderException("boom")),
                secondary = backend(10, "secondary"),
                hedgeAfterMillis = 8_000,
            ).transcribe("primary", "p-model", "secondary", "s-model")
        }

        assertEquals("secondary", outcome.result.transcript.transcript)
        assertTrue(outcome.attribution.wasFallback)
        // The elapsed time is the claim, not which transcript came back: "secondary" arrives
        // either way, just eight seconds later. This case passed against a Swift port that always
        // slept the full delay, because only the transcript was ever checked.
        assertTrue(
            "the hedge waited out its delay after the primary had already failed ($elapsedMillis ms)",
            elapsedMillis < 1_000,
        )
    }

    /** The primary's error explains the user's configuration, so it is the one they see. */
    @Test
    fun `when both fail the primary error surfaces`() = runBlocking {
        val error = runCatching {
            FallbackTranscriber(
                primary = backend(5, "", ProviderException("primary failed")),
                secondary = backend(5, "", ProviderException("secondary failed")),
                hedgeAfterMillis = 1,
            ).transcribe("primary", "p-model", "secondary", "s-model")
        }.exceptionOrNull()

        assertEquals("primary failed", error?.message)
    }

    /** No secondary is the default, and must behave exactly as before this type existed. */
    @Test
    fun `without a secondary it is a transparent pass through`() = runBlocking {
        val outcome = FallbackTranscriber(primary = backend(5, "primary"))
            .transcribe("primary", "p-model")

        assertEquals("primary", outcome.result.transcript.transcript)
        assertFalse(outcome.attribution.wasFallback)
    }
}
