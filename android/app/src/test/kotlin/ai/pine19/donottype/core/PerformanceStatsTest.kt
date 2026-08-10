package ai.pine19.donottype.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * The same invariants the Swift and C# suites assert.
 *
 * Three ports of one calculation are three chances for it to disagree with itself, and a stats
 * screen that reports different numbers on different platforms is worse than no stats screen.
 */
class PerformanceStatsTest {
    private fun record(
        status: DictationRecord.Status = DictationRecord.Status.COMPLETED,
        text: String = "one two three",
        latency: Long? = 3_000,
        spoken: Double = 6.0,
        retries: Int = 0,
        model: String = "gemini-3.6-flash",
    ) = DictationRecord(model = model).apply {
        this.status = status
        this.text = text
        latencyMillis = latency
        durationSeconds = spoken
        retryCount = retries
    }

    @Test
    fun `empty history produces no misleading zeroes`() {
        val stats = PerformanceStats.compute(emptyList())
        assertEquals(0, stats.total)
        assertNull(stats.medianLatencyMillis)
        assertNull("0/0 is not a 0% success rate", stats.successRate)
        assertNull(stats.realTimeFactor)
    }

    @Test
    fun `counts by status`() {
        val stats = PerformanceStats.compute(
            listOf(
                record(), record(),
                record(status = DictationRecord.Status.FAILED, latency = null),
                record(status = DictationRecord.Status.PENDING, latency = null),
            )
        )
        assertEquals(4, stats.total)
        assertEquals(2, stats.completed)
        assertEquals(1, stats.failed)
        assertEquals(1, stats.pending)
        assertEquals(0.5, stats.successRate!!, 0.001)
    }

    /**
     * A failure's latency measures how long an error took to arrive. Folding it in would make a
     * fast app with a bad key look slow.
     */
    @Test
    fun `failed dictations do not contribute timings`() {
        val stats = PerformanceStats.compute(
            listOf(
                record(latency = 2_000),
                record(status = DictationRecord.Status.FAILED, latency = 90_000),
            )
        )
        assertEquals(2_000L, stats.medianLatencyMillis)
    }

    @Test
    fun `median is not dragged by an outlier`() {
        val stats = PerformanceStats.compute(
            listOf(
                record(latency = 2_000), record(latency = 2_000), record(latency = 3_000),
                record(latency = 3_000), record(latency = 120_000),
            )
        )
        assertEquals(3_000L, stats.medianLatencyMillis)
        assertEquals("p95 is where the bad case is meant to show up", 120_000L, stats.p95LatencyMillis)
    }

    @Test
    fun `percentile uses nearest rank`() {
        val values = (1L..10L).toList()
        assertEquals(5L, PerformanceStats.percentile(values, 0.5))
        assertEquals(10L, PerformanceStats.percentile(values, 0.95))
        assertNull(PerformanceStats.percentile(emptyList(), 0.5))
        assertEquals(7L, PerformanceStats.percentile(listOf(7L), 0.95))
    }

    /** Zero means "not measured", like null does — never "instant". */
    @Test
    fun `unmeasured records are excluded rather than counted as instant`() {
        val stats = PerformanceStats.compute(
            listOf(record(latency = null), record(latency = 0), record(latency = 4_000))
        )
        assertEquals(4_000L, stats.medianLatencyMillis)
    }

    @Test
    fun `real time factor compares wait to speech`() {
        val stats = PerformanceStats.compute(listOf(record(latency = 3_000, spoken = 6.0)))
        assertEquals(0.5, stats.realTimeFactor!!, 0.001)
    }

    @Test
    fun `retries are counted per dictation not per attempt`() {
        val stats = PerformanceStats.compute(
            listOf(record(retries = 3), record(retries = 0), record(retries = 1))
        )
        assertEquals(2, stats.retried)
    }

    @Test
    fun `words and speech accumulate`() {
        val stats = PerformanceStats.compute(
            listOf(
                record(text = "one two three", spoken = 6.0),
                record(text = "four five", spoken = 4.0),
            )
        )
        assertEquals(5, stats.words)
        assertEquals(10.0, stats.spokenSeconds, 0.001)
    }

    @Test
    fun `duration formatting matches the other ports`() {
        assertEquals("420 ms", PerformanceStats.formatMillis(420))
        assertEquals("3.5 s", PerformanceStats.formatMillis(3_460))
        assertEquals("2m 5s", PerformanceStats.formatMillis(125_000))
        assertEquals("1h 2m", PerformanceStats.formatMillis(3_725_000))
        assertEquals("—", PerformanceStats.formatMillis(null))
    }

    @Test
    fun `breakdown groups by model most used first`() {
        val breakdown = ModelPerformance.breakdown(
            listOf(
                record(model = "gemini-3.6-flash"), record(model = "gemini-3.6-flash"),
                record(model = "gemini-2.5-flash"),
            )
        )
        assertEquals(2, breakdown.size)
        assertEquals("gemini-3.6-flash", breakdown[0].model)
        assertEquals(2, breakdown[0].stats.total)
    }

    /** Timings must survive a round trip, or history loses them at the next launch. */
    @Test
    fun `timings survive json round trip`() {
        val original = record(latency = 4_200).apply {
            requestMillis = 3_100
            audioTokens = 190
        }
        val restored = DictationRecord.fromJson(original.toJson())

        assertEquals(4_200L, restored.latencyMillis)
        assertEquals(3_100L, restored.requestMillis)
        assertEquals(6.0, restored.durationSeconds, 0.001)
        assertEquals(190, restored.audioTokens)
    }

    /** An old record has no timings, and must decode as "unmeasured" rather than as zero. */
    @Test
    fun `records written before timings existed decode as unmeasured`() {
        val legacy = org.json.JSONObject()
            .put("id", "abc")
            .put("status", "completed")
            .put("text", "hello")
        val restored = DictationRecord.fromJson(legacy)

        assertNull(restored.latencyMillis)
        assertNull(restored.requestMillis)
        assertNull(restored.audioTokens)
    }
}
