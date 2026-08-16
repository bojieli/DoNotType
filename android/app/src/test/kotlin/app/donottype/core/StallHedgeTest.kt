package app.donottype.core

import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The Kotlin port of `StallHedge` has to behave like the Swift and C# ones.
 *
 * These are the same cases as `Tests/DoNotTypeCoreTests/StallHedgeTests.swift`: a duplicate that
 * fires at a different moment on one platform means the Android app has a different latency profile
 * — and a different bill — from the one the evaluation describes.
 *
 * `runBlocking` with millisecond delays rather than `runTest` on a virtual clock, matching
 * `FallbackTranscriberTest`: the delays are short enough that the suite stays fast.
 */
class StallHedgeTest {

    // MARK: - When a request counts as stalled

    /**
     * The floor. Nothing shorter than 32 seconds of audio can produce a deadline below it, which is
     * every ordinary dictation.
     */
    @Test
    fun `short recordings get the eight second floor`() {
        assertEquals(8_000L, StallHedge.deadlineMillis(0.0))
        assertEquals(8_000L, StallHedge.deadlineMillis(3.0))
        assertEquals(8_000L, StallHedge.deadlineMillis(20.0))
    }

    /**
     * Both conditions have to hold, so at the crossover the floor is still what binds: a quarter of
     * 32 seconds *is* eight, and a hair under it is less.
     */
    @Test
    fun `the floor binds until a quarter of the audio overtakes it`() {
        assertEquals(8_000L, StallHedge.deadlineMillis(31.9))
        assertEquals(8_000L, StallHedge.deadlineMillis(32.0))
        assertEquals(8_100L, StallHedge.deadlineMillis(32.4))
    }

    /**
     * Past the crossover it is the audio that decides: eight seconds is a stall for a three-second
     * clip and a perfectly good pace for a four-minute one.
     */
    @Test
    fun `long recordings get a quarter of their own length`() {
        assertEquals(15_000L, StallHedge.deadlineMillis(60.0))
        assertEquals(60_000L, StallHedge.deadlineMillis(240.0))
    }

    /**
     * A compressed file's length is not readable without decoding it, and a missing duration must
     * not disable the hedge — it falls back to the floor.
     */
    @Test
    fun `an unknown duration gets the floor`() {
        assertEquals(8_000L, StallHedge.deadlineMillis(null))
    }

    // MARK: - Racing

    /** The common case: the request answers normally, so no second one is ever sent. */
    @Test
    fun `a fast request is never duplicated`() = runBlocking {
        val sent = AtomicInteger()

        val value = StallHedge.race(deadlineMillis = 5_000) {
            sent.incrementAndGet()
            "first"
        }

        assertEquals("first", value)
        assertEquals("a request that answered in time must not be second guessed", 1, sent.get())
    }

    /** The case this exists for: the first request is stuck in the tail and the second one lands. */
    @Test
    fun `a stalled request is overtaken by its duplicate`() = runBlocking {
        val sent = AtomicInteger()
        var hedged = false

        val value = StallHedge.race(deadlineMillis = 20, onHedge = { hedged = true }) {
            val attempt = sent.incrementAndGet()
            // The first request stalls for effectively ever; the second answers straight away.
            if (attempt == 1) delay(5_000)
            "attempt $attempt"
        }

        assertEquals("attempt 2", value)
        assertTrue("the caller has to be able to log that it spent a second request", hedged)
    }

    /**
     * Not a timeout: the first request is not abandoned at the deadline. If it answers while the
     * duplicate is still working, it is the one that wins.
     */
    @Test
    fun `the first request still wins if it answers after the deadline`() = runBlocking {
        val sent = AtomicInteger()

        val value = StallHedge.race(deadlineMillis = 20) {
            val attempt = sent.incrementAndGet()
            if (attempt == 1) delay(100)
            if (attempt == 2) delay(5_000)
            "attempt $attempt"
        }

        assertEquals("attempt 1", value)
    }

    /**
     * A failure is the retry ladder's problem, not the hedge's, and its backoff will try again
     * sooner than sitting out the rest of the deadline would.
     */
    @Test
    fun `an early failure is not made to wait out the deadline`() = runBlocking {
        val started = System.currentTimeMillis()

        val error = runCatching {
            StallHedge.race<String>(deadlineMillis = 30_000) { throw ProviderException("boom") }
        }.exceptionOrNull()

        assertEquals("boom", error?.message)
        assertTrue(
            "a failed request must not sit out a deadline meant for a running one",
            System.currentTimeMillis() - started < 5_000,
        )
    }

    /**
     * Once the duplicate is in flight, the first one failing costs nothing: the words can still
     * arrive from the request that is still running.
     */
    @Test
    fun `a failure after the hedge waits for the duplicate`() = runBlocking {
        val sent = AtomicInteger()

        val value = StallHedge.race(deadlineMillis = 20) {
            val attempt = sent.incrementAndGet()
            if (attempt == 1) {
                // Long enough that the duplicate has certainly started before this gives up.
                delay(100)
                throw ProviderException("unavailable")
            }
            delay(200)
            "attempt $attempt"
        }

        assertEquals("attempt 2", value)
    }

    /**
     * When both fail the caller sees the *original* request's error even though the duplicate failed
     * sooner: the duplicate was this object's idea, and the request the caller asked for is the one
     * whose failure explains their configuration.
     */
    @Test
    fun `when both fail the original request error surfaces`() = runBlocking {
        val sent = AtomicInteger()

        val error = runCatching {
            StallHedge.race<String>(deadlineMillis = 20) {
                val attempt = sent.incrementAndGet()
                if (attempt == 1) {
                    delay(100)
                    throw ProviderException("no API key")
                }
                throw ProviderException("boom")
            }
        }.exceptionOrNull()

        assertEquals("no API key", error?.message)
    }

    /** A deadline of zero or less disables hedging rather than duplicating everything instantly. */
    @Test
    fun `a non positive deadline sends one request`() = runBlocking {
        val sent = AtomicInteger()

        val value = StallHedge.race(deadlineMillis = 0) {
            val attempt = sent.incrementAndGet()
            delay(30)
            "attempt $attempt"
        }

        assertEquals("attempt 1", value)
        assertEquals(1, sent.get())
    }
}
