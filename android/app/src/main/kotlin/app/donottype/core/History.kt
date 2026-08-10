package app.donottype.core

import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.UUID

/**
 * One dictation, and everything needed to try it again.
 *
 * Retry is what makes this hold more than text. A dictation that failed because the phone lost
 * signal is not lost work: the recording is still on disk, so the request can simply be reissued.
 * That means audio retention is not purely a privacy setting — a failed entry keeps its audio
 * until it succeeds, or Retry would be a button that cannot work.
 */
data class DictationRecord(
    val id: String = UUID.randomUUID().toString(),
    val createdAt: Long = System.currentTimeMillis(),
    var status: Status = Status.PENDING,
    var text: String = "",
    var errorMessage: String? = null,
    val model: String = "",
    val fidelity: Fidelity = Fidelity.DEFAULT,
    val appName: String? = null,
    var retryCount: Int = 0,
    var audioFileName: String? = null,
    /**
     * Wall clock from the end of speech to text delivered -- what the user actually waits.
     *
     * Measured from key release rather than from the request, because everything in between
     * (reading the screen, a failed pre-upload, a retry) is time spent staring at the overlay.
     * A figure that excluded it would flatter the app.
     */
    var latencyMillis: Long? = null,
    /** Time inside the request alone, for telling a slow model from a slow app. */
    var requestMillis: Long? = null,
    /** Seconds of speech, for the wait-per-second-spoken figure. */
    var durationSeconds: Double = 0.0,
    var audioTokens: Int? = null,
) {
    enum class Status(val id: String) {
        COMPLETED("completed"),
        FAILED("failed"),
        PENDING("pending");

        val isRetryable: Boolean get() = this != COMPLETED

        companion object {
            fun from(id: String?) = entries.firstOrNull { it.id == id } ?: PENDING
        }
    }

    val canRetry: Boolean get() = status.isRetryable && audioFileName != null

    val summary: String
        get() = when (status) {
            Status.COMPLETED -> text
            Status.FAILED -> errorMessage ?: "Failed"
            Status.PENDING -> "Waiting to send"
        }

    fun toJson(): JSONObject = JSONObject()
        .put("id", id)
        .put("createdAt", createdAt)
        .put("status", status.id)
        .put("text", text)
        .put("errorMessage", errorMessage)
        .put("model", model)
        .put("fidelity", fidelity.id)
        .put("appName", appName)
        .put("retryCount", retryCount)
        .put("audioFileName", audioFileName)
        .put("latencyMillis", latencyMillis)
        .put("requestMillis", requestMillis)
        .put("durationSeconds", durationSeconds)
        .put("audioTokens", audioTokens)

    companion object {
        fun fromJson(json: JSONObject) = DictationRecord(
            id = json.optString("id", UUID.randomUUID().toString()),
            createdAt = json.optLong("createdAt"),
            status = Status.from(json.optString("status")),
            text = json.optString("text"),
            errorMessage = json.optString("errorMessage").takeIf { it.isNotEmpty() },
            model = json.optString("model"),
            fidelity = Fidelity.from(json.optString("fidelity")),
            appName = json.optString("appName").takeIf { it.isNotEmpty() },
            retryCount = json.optInt("retryCount"),
            audioFileName = json.optString("audioFileName").takeIf { it.isNotEmpty() },
            // Records written before timings existed have no value here, which must stay null
            // rather than becoming a zero that reads as "instant".
            latencyMillis = if (json.isNull("latencyMillis")) null else json.optLong("latencyMillis"),
            requestMillis = if (json.isNull("requestMillis")) null else json.optLong("requestMillis"),
            durationSeconds = json.optDouble("durationSeconds", 0.0),
            audioTokens = if (json.isNull("audioTokens")) null else json.optInt("audioTokens"),
        )
    }
}

/** How long transcripts are kept. */
enum class RetentionPolicy(val id: String, val label: String, val maxAgeMillis: Long?) {
    NEVER("never", "Don't keep history", 0),
    ONE_DAY("oneDay", "24 hours", 86_400_000),
    ONE_WEEK("oneWeek", "1 week", 604_800_000),
    ONE_MONTH("oneMonth", "1 month", 2_592_000_000),
    FOREVER("forever", "Forever", null);

    companion object {
        fun from(id: String?) = entries.firstOrNull { it.id == id } ?: FOREVER
    }
}

/**
 * Persists dictations and the audio needed to retry them.
 *
 * A JSON index plus an `audio/` directory, mirroring the Swift implementation. Room would be the
 * reflex on Android, but the access pattern is "load a few hundred rows, append one at a time",
 * and a schema plus a migration path is a lot of ceremony for a list.
 */
class HistoryStore(private val directory: File) {

    private val indexFile = File(directory, "history.json")
    private val audioDirectory = File(directory, "audio")

    private var records: MutableList<DictationRecord>? = null
    private var retention: RetentionPolicy = RetentionPolicy.FOREVER
    private var keepAudioForCompleted: Boolean = false

    fun configure(retention: RetentionPolicy, keepAudioForCompleted: Boolean) {
        this.retention = retention
        this.keepAudioForCompleted = keepAudioForCompleted
        records = null // reapply retention on next read
    }

    @Synchronized
    fun all(): List<DictationRecord> = loaded().toList()

    @Synchronized
    fun retryable(): List<DictationRecord> = loaded().filter { it.canRetry }.sortedBy { it.createdAt }

    @Synchronized
    fun insert(record: DictationRecord, audio: ByteArray?): DictationRecord {
        val list = loaded()

        // Kept whenever the entry might still need retrying, regardless of the completed-audio
        // setting: without it, Retry cannot work.
        val needsAudio = record.status.isRetryable || keepAudioForCompleted
        if (audio != null && needsAudio && retention != RetentionPolicy.NEVER) {
            audioDirectory.mkdirs()
            val name = "${record.id}.wav"
            File(audioDirectory, name).writeBytes(audio)
            record.audioFileName = name
        } else {
            record.audioFileName = null
        }

        list.add(0, record)
        persist()
        return record
    }

    @Synchronized
    fun update(record: DictationRecord) {
        val list = loaded()
        val index = list.indexOfFirst { it.id == record.id }
        if (index < 0) return

        // A successful retry releases the recording it was holding.
        if (record.status == DictationRecord.Status.COMPLETED && !keepAudioForCompleted) {
            record.audioFileName?.let { File(audioDirectory, it).delete() }
            record.audioFileName = null
        }
        list[index] = record
        persist()
    }

    @Synchronized
    fun delete(id: String) {
        val list = loaded()
        list.firstOrNull { it.id == id }?.let(::removeAudio)
        list.removeAll { it.id == id }
        persist()
    }

    @Synchronized
    fun deleteAll() {
        loaded().forEach(::removeAudio)
        loaded().clear()
        persist()
    }

    @Synchronized
    fun audioBytes(): Long =
        loaded().mapNotNull { it.audioFileName }.sumOf { File(audioDirectory, it).length() }

    fun audioFor(record: DictationRecord): ByteArray? {
        val name = record.audioFileName ?: return null
        val file = File(audioDirectory, name)
        return if (file.exists()) file.readBytes() else null
    }

    // MARK: - Private

    private fun loaded(): MutableList<DictationRecord> {
        records?.let { return it }

        val list = mutableListOf<DictationRecord>()
        if (indexFile.exists()) {
            runCatching {
                val array = JSONArray(indexFile.readText())
                for (i in 0 until array.length()) {
                    array.optJSONObject(i)?.let { list += DictationRecord.fromJson(it) }
                }
            }
        }
        records = list
        applyRetention()
        return records!!
    }

    private fun applyRetention() {
        val maxAge = retention.maxAgeMillis ?: return
        val list = records ?: return

        if (maxAge == 0L) {
            list.forEach(::removeAudio)
            list.clear()
            persist()
            return
        }
        val cutoff = System.currentTimeMillis() - maxAge
        val expired = list.filter { it.createdAt < cutoff }
        if (expired.isEmpty()) return
        expired.forEach(::removeAudio)
        list.removeAll { it.createdAt < cutoff }
        persist()
    }

    private fun removeAudio(record: DictationRecord) {
        record.audioFileName?.let { File(audioDirectory, it).delete() }
    }

    private fun persist() {
        if (retention == RetentionPolicy.NEVER) {
            indexFile.delete()
            return
        }
        directory.mkdirs()
        val array = JSONArray()
        records?.forEach { array.put(it.toJson()) }
        runCatching { indexFile.writeText(array.toString()) }
    }
}
