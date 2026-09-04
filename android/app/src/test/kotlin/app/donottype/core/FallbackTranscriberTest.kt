package app.donottype.core

import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
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

    private companion object {
        /**
         * The two spellings the hedge can log, repeated verbatim in each platform's test suite
         * rather than shared from one file, per `docs/PARITY.md`.
         */
        const val STALLED_MESSAGE = "primary stalled; starting the fallback"
        const val FAILED_MESSAGE = "primary failed; starting the fallback"
    }

    private lateinit var sink: MemoryLogSink

    @Before
    fun setUp() {
        sink = MemoryLogSink()
        LogRouter.install(listOf(sink), LogLevel.TRACE)
    }

    @After
    fun tearDown() {
        LogRouter.install(emptyList(), LogLevel.OFF)
    }

    /** The line that announced the handover, the first thing the category logs. */
    private val handoverLine: LogEvent?
        get() = sink.events.firstOrNull { it.category == "fallback" }

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

    /**
     * A stall and a failure are different problems, so the log has to name which one happened.
     *
     * "The primary is slow" and "the primary is broken" want opposite responses from whoever
     * reads the log, and for as long as both said "stalled" the log pointed at the wrong one.
     */
    @Test
    fun `a stalled primary is logged as a stall`() = runBlocking {
        FallbackTranscriber(
            primary = backend(30_000, "primary"),
            secondary = backend(10, "secondary"),
            hedgeAfterMillis = 20,
        ).transcribe("primary", "p-model", "secondary", "s-model")

        assertEquals(STALLED_MESSAGE, handoverLine?.message)
        assertEquals("primary", handoverLine?.fields?.get("primary"))
        assertEquals("secondary", handoverLine?.fields?.get("fallback"))
        assertEquals("20", handoverLine?.fields?.get("afterMs"))
    }

    /**
     * The delay is deliberately absent: nothing waited it out, so reporting it would describe a
     * wait that never happened.
     */
    @Test
    fun `a failed primary is logged as a failure and reports no delay`() = runBlocking {
        FallbackTranscriber(
            primary = backend(5, "", ProviderException("boom")),
            secondary = backend(10, "secondary"),
            hedgeAfterMillis = 8_000,
        ).transcribe("primary", "p-model", "secondary", "s-model")

        assertEquals(FAILED_MESSAGE, handoverLine?.message)
        assertEquals("primary", handoverLine?.fields?.get("primary"))
        assertEquals("secondary", handoverLine?.fields?.get("fallback"))
        assertNull("nothing waited, so there is no delay", handoverLine?.fields?.get("afterMs"))
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
