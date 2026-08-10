package app.donottype.core

/**
 * What the app has actually cost you, computed from the history.
 *
 * A port of `PerformanceStats.swift`, kept deliberately close to it: the same fields, the same
 * nearest-rank percentile, the same refusal to turn a missing value into a zero. Two platforms
 * reporting different numbers for the same history would make both untrustworthy.
 *
 * Median and p95 rather than a mean. A mean is dragged upwards by the one dictation that hit a
 * retry storm, which makes the typical case look worse than it is; p95 is the separate and more
 * useful question of how bad the bad ones get.
 */
data class PerformanceStats(
    val total: Int = 0,
    val completed: Int = 0,
    val failed: Int = 0,
    val pending: Int = 0,
    /** Dictations that needed at least one retry -- the honest measure of network trouble. */
    val retried: Int = 0,
    val medianLatencyMillis: Long? = null,
    val p95LatencyMillis: Long? = null,
    val medianRequestMillis: Long? = null,
    val spokenSeconds: Double = 0.0,
    val words: Int = 0,
    val audioTokens: Int = 0,
) {
    /** Null rather than zero when nothing has been recorded: 0/0 is not a 0% success rate. */
    val successRate: Double? get() = if (total == 0) null else completed.toDouble() / total

    /**
     * Wait per second of speech. Below 1.0 means the transcript arrives faster than it took to
     * say -- the number that decides whether dictation feels immediate or laborious.
     */
    val realTimeFactor: Double?
        get() {
            val median = medianLatencyMillis ?: return null
            if (spokenSeconds <= 0 || completed == 0) return null
            val meanSpoken = spokenSeconds / completed
            return if (meanSpoken > 0) (median / 1000.0) / meanSpoken else null
        }

    /** Typing time saved, at a generous 40 wpm. An estimate, and labelled as one wherever shown. */
    val estimatedTypingMinutesSaved: Double get() = words / 40.0

    companion object {
        fun compute(records: List<DictationRecord>): PerformanceStats {
            var completed = 0
            var failed = 0
            var pending = 0
            var retried = 0
            var spokenSeconds = 0.0
            var words = 0
            var audioTokens = 0
            val latencies = mutableListOf<Long>()
            val requests = mutableListOf<Long>()

            for (record in records) {
                when (record.status) {
                    DictationRecord.Status.COMPLETED -> completed++
                    DictationRecord.Status.FAILED -> failed++
                    DictationRecord.Status.PENDING -> pending++
                }
                if (record.retryCount > 0) retried++

                // Timings only come from successes. A failure's latency measures how long an error
                // took to arrive, which is a different quantity and would poison the median.
                if (record.status != DictationRecord.Status.COMPLETED) continue

                record.latencyMillis?.takeIf { it > 0 }?.let { latencies += it }
                record.requestMillis?.takeIf { it > 0 }?.let { requests += it }
                spokenSeconds += record.durationSeconds
                words += record.text.split(Regex("\\s+")).count { it.isNotEmpty() }
                audioTokens += record.audioTokens ?: 0
            }

            return PerformanceStats(
                total = records.size,
                completed = completed,
                failed = failed,
                pending = pending,
                retried = retried,
                medianLatencyMillis = percentile(latencies, 0.5),
                p95LatencyMillis = percentile(latencies, 0.95),
                medianRequestMillis = percentile(requests, 0.5),
                spokenSeconds = spokenSeconds,
                words = words,
                audioTokens = audioTokens,
            )
        }

        /**
         * Nearest-rank percentile. No interpolation: with the handful of samples a new user has,
         * interpolating invents precision that is not there.
         */
        fun percentile(values: List<Long>, fraction: Double): Long? {
            if (values.isEmpty()) return null
            val sorted = values.sorted()
            val rank = Math.ceil(fraction * sorted.size).toInt()
            return sorted[rank.coerceIn(1, sorted.size) - 1]
        }

        /** "--" rather than "0 s": an unmeasured value must not read as an instant one. */
        fun formatMillis(millis: Long?): String {
            if (millis == null) return "—"
            if (millis < 1_000) return "$millis ms"
            val seconds = millis / 1000.0
            if (seconds < 60) return String.format("%.1f s", seconds)
            val minutes = (seconds / 60).toInt()
            if (minutes < 60) return "${minutes}m ${(seconds % 60).toInt()}s"
            return "${minutes / 60}h ${minutes % 60}m"
        }

        fun formatSeconds(seconds: Double): String = formatMillis((seconds * 1000).toLong())

        fun formatCount(value: Int): String =
            if (value >= 10_000) String.format("%.1fk", value / 1000.0) else value.toString()
    }
}

/** Per-model figures, so switching model shows its effect rather than being taken on faith. */
data class ModelPerformance(val model: String, val stats: PerformanceStats) {
    companion object {
        fun breakdown(records: List<DictationRecord>): List<ModelPerformance> =
            records.groupBy { it.model }
                .map { (model, group) -> ModelPerformance(model, PerformanceStats.compute(group)) }
                // A model tried twice is noise next to one used for a month.
                .sortedByDescending { it.stats.total }
    }
}
