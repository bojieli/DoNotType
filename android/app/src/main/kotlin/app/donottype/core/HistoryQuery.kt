package app.donottype.core

import java.text.Normalizer

/**
 * Filtering and search over stored dictations.
 *
 * In the core rather than the settings screen so the rules are testable without a UI and behave
 * identically to the other platforms. Search is the point of keeping history at all — a log you
 * cannot search is just storage.
 */
data class HistoryQuery(
    val text: String = "",
    val status: StatusFilter = StatusFilter.ALL,
    val appName: String? = null,
    val since: Long? = null,
) {
    enum class StatusFilter(val label: String) {
        ALL("All"),
        COMPLETED("Completed"),
        NEEDS_ATTENTION("Needs retry"),
    }

    val isEmpty: Boolean
        get() = text.isBlank() && status == StatusFilter.ALL && appName == null && since == null

    /** Applies the filters, newest first. */
    fun apply(records: List<DictationRecord>): List<DictationRecord> {
        val needle = text.trim()
        return records
            .filter {
                when (status) {
                    StatusFilter.ALL -> true
                    StatusFilter.COMPLETED -> it.status == DictationRecord.Status.COMPLETED
                    StatusFilter.NEEDS_ATTENTION -> it.status != DictationRecord.Status.COMPLETED
                }
            }
            .filter { appName == null || it.appName == appName }
            .filter { since == null || it.createdAt >= since }
            .filter { needle.isEmpty() || matches(it, needle) }
            .sortedByDescending { it.createdAt }
    }

    /**
     * The error message is searched as well as the transcript: when hunting a failure the message
     * is what you remember, and the transcript is empty.
     */
    private fun matches(record: DictationRecord, needle: String): Boolean =
        listOf(record.text, record.errorMessage.orEmpty(), record.appName.orEmpty())
            .any { it.foldForSearch().contains(needle.foldForSearch()) }

    companion object {
        /** Apps present in the history, for a filter control. */
        fun appNames(records: List<DictationRecord>): List<String> =
            records.mapNotNull { it.appName }.filter { it.isNotEmpty() }.distinct().sorted()

        /** Case- and diacritic-insensitive, so "cafe" finds "café". */
        private fun String.foldForSearch(): String =
            Normalizer.normalize(this, Normalizer.Form.NFD)
                .replace(Regex("\\p{Mn}+"), "")
                .lowercase()
    }
}
