package app.donottype.core

import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.OutputStreamWriter
import java.nio.charset.StandardCharsets
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
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
    /** What to tell the user: one sentence, from [FailureAdvice]. */
    var errorMessage: String? = null,
    /**
     * The failure exactly as it arrived, uncut.
     *
     * Separate from [errorMessage] because the two have different jobs and one string cannot do
     * both. A list needs a sentence somebody can read at a glance; debugging needs the status, the
     * whole response body and the exception type, with nothing dropped — a body cut at 400
     * characters loses the field name that says which part of the request was wrong, and a
     * half-message pasted into an issue cannot be searched for.
     */
    var errorDetail: String? = null,

    /**
     * A rewrite was asked for and did not happen, so what was delivered is the verbatim text.
     *
     * Recorded rather than inferred from a null [styledText], which is also what a verbatim
     * dictation looks like. The difference matters: one is what was asked for, the other is a
     * second request that failed, and only the second is worth telling somebody about.
     */
    var rewriteFailed: Boolean = false,

    /**
     * The exact context that was sent, so the inspector can show it and a retry can reuse it.
     *
     * Both halves of that matter. Without it a retry re-runs *ungrounded* — a different request
     * from the one that failed, on a row that still names the same provider and model — and the
     * inspector has nothing to inspect.
     *
     * It is screen contents on disk, so it lives and dies with the row: the retention policy
     * deletes it along with everything else, and a context that was never captured (grounding off,
     * or the app on the blocklist) is null here rather than empty.
     *
     * The screenshot is not kept. The index is one JSON file read whole at launch, and a PNG in
     * every row would make its size a function of how many dictations somebody has ever made.
     * Android has no screenshot fallback today; when one arrives the image should go beside the
     * audio, as a file the row points at.
     */
    var context: ScreenContext? = null,
    /**
     * The backend that actually produced this transcript.
     *
     * `var` because a hedged dictation may be answered by the fallback rather than the primary,
     * and a history row naming the backend that was *asked* would make history untrustworthy for
     * exactly the comparisons it exists to support.
     */
    var model: String = "",
    val fidelity: Fidelity = Fidelity.DEFAULT,
    val appName: String? = null,
    var retryCount: Int = 0,
    var audioFileName: String? = null,
    /**
     * Wall clock from the end of speech to text delivered -- what the user actually waits.
     *
     * Measured from key release rather than from the request, because everything in between
     * (reading the screen, a retry) is time spent staring at the overlay.
     * A figure that excluded it would flatter the app.
     */
    var latencyMillis: Long? = null,
    /** Time inside the request alone, for telling a slow model from a slow app. */
    var requestMillis: Long? = null,
    /** Seconds of speech, for the wait-per-second-spoken figure. */
    var durationSeconds: Double = 0.0,
    var audioTokens: Int? = null,
    /**
     * The derived text, when a mode other than verbatim produced one.
     *
     * Kept separate from [text] rather than replacing it. That separation is the whole difference
     * from the tool this project replaces: a rewrite or a summary is a derived artifact, and what
     * you actually said stays recoverable next to it.
     */
    var styledText: String? = null,
    /** Which mode produced [styledText]. Null on rows written before modes existed. */
    var mode: String? = null,
    /**
     * The recording this came from, when it was a file rather than the microphone. Its presence is
     * what distinguishes an offline transcription from a dictation.
     */
    var sourceFileName: String? = null,
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

    /** True when this came from a recording on disk rather than the microphone. */
    val isFromFile: Boolean get() = sourceFileName != null

    /** What was delivered: the derived text when one exists, otherwise the transcript. */
    val deliveredText: String get() = styledText ?: text

    /**
     * The mode, including for rows written before the field existed — every one of those was a
     * verbatim dictation, so the reconstruction is exact rather than a guess.
     */
    val resolvedMode: TranscriptMode
        get() = TranscriptMode.from(mode) ?: TranscriptMode.Verbatim

    val summary: String
        get() = when (status) {
            Status.COMPLETED -> deliveredText
            Status.FAILED -> errorMessage ?: "Failed"
            Status.PENDING -> "Waiting to send"
        }

    fun toJson(): JSONObject = JSONObject()
        .put("id", id)
        .put("createdAt", createdAt)
        .put("status", status.id)
        .put("text", text)
        .put("errorMessage", errorMessage)
        .put("errorDetail", errorDetail)
        .put("rewriteFailed", rewriteFailed)
        .put("context", context?.toJson())
        .put("model", model)
        .put("fidelity", fidelity.id)
        .put("appName", appName)
        .put("retryCount", retryCount)
        .put("audioFileName", audioFileName)
        .put("latencyMillis", latencyMillis)
        .put("requestMillis", requestMillis)
        .put("durationSeconds", durationSeconds)
        .put("audioTokens", audioTokens)
        .put("styledText", styledText)
        .put("mode", mode)
        .put("sourceFileName", sourceFileName)

    companion object {
        fun fromJson(json: JSONObject) = DictationRecord(
            id = json.optString("id", UUID.randomUUID().toString()),
            createdAt = json.optLong("createdAt"),
            status = Status.from(json.optString("status")),
            text = json.optString("text"),
            errorMessage = json.optString("errorMessage").takeIf { it.isNotEmpty() },
            errorDetail = json.optString("errorDetail").takeIf { it.isNotEmpty() },
            rewriteFailed = json.optBoolean("rewriteFailed"),
            context = ScreenContext.fromJson(json.optJSONObject("context")),
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
            // Absent on every row written before modes existed. Reading them as null rather than
            // failing is what keeps an upgrade from emptying somebody's history.
            styledText = json.optString("styledText").takeIf { it.isNotEmpty() },
            mode = json.optString("mode").takeIf { it.isNotEmpty() },
            sourceFileName = json.optString("sourceFileName").takeIf { it.isNotEmpty() },
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

    private val log = Log("history")
    private val indexFile = File(directory, "history.json")
    private val temporaryIndexFile = File(directory, "history.json.tmp")
    private val audioDirectory = File(directory, "audio")

    private var records: MutableList<DictationRecord>? = null
    private var retention: RetentionPolicy = RetentionPolicy.FOREVER
    private var keepAudioForCompleted: Boolean = false

    @Synchronized
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
            audioFile(name)!!.writeBytes(audio)
            record.audioFileName = name
        } else {
            record.audioFileName = null
        }

        list.add(0, record)
        persist()
        log.debug(
            mapOf(
                "status" to record.status.id,
                "mode" to record.resolvedMode.id,
                "audio" to if (record.audioFileName == null) "discarded" else "kept",
                "source" to (record.sourceFileName ?: "microphone"),
            ),
        ) { "stored" }
        return record
    }

    @Synchronized
    fun update(record: DictationRecord) {
        val list = loaded()
        val index = list.indexOfFirst { it.id == record.id }
        if (index < 0) return

        // A successful retry releases the recording it was holding.
        if (record.status == DictationRecord.Status.COMPLETED && !keepAudioForCompleted) {
            record.audioFileName?.let { audioFile(it)?.delete() }
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
        loaded().mapNotNull { it.audioFileName?.let(::audioFile) }.sumOf(File::length)

    fun audioFor(record: DictationRecord): ByteArray? {
        val name = record.audioFileName ?: return null
        val file = audioFile(name) ?: return null
        return if (file.exists()) file.readBytes() else null
    }

    // MARK: - Private

    private fun loaded(): MutableList<DictationRecord> {
        records?.let { return it }

        val list = mutableListOf<DictationRecord>()
        if (indexFile.exists()) {
            val parsed = runCatching {
                val array = JSONArray(indexFile.readText())
                val decoded = mutableListOf<DictationRecord>()
                for (i in 0 until array.length()) {
                    array.optJSONObject(i)?.let { decoded += DictationRecord.fromJson(it) }
                }
                decoded
            }.onFailure { error ->
                log.error(
                    mapOf("type" to error.javaClass.simpleName),
                ) { "history index is unreadable; leaving it untouched" }
            }.getOrNull()
            if (parsed != null) list += parsed
        }
        records = list
        applyRetention()
        return list
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

        // Deleting the user's transcripts is worth a line even when they asked for it: "where did
        // my history go" has a retention policy as its answer, and nothing else records the moment.
        log.info(
            mapOf("removed" to expired.size.toString(), "policy" to retention.id),
        ) { "retention pruned history" }
        expired.forEach(::removeAudio)
        list.removeAll { it.createdAt < cutoff }
        persist()
    }

    private fun removeAudio(record: DictationRecord) {
        record.audioFileName?.let { audioFile(it)?.delete() }
    }

    private fun persist() {
        if (retention == RetentionPolicy.NEVER) {
            indexFile.delete()
            temporaryIndexFile.delete()
            return
        }
        val array = JSONArray()
        records?.forEach { array.put(it.toJson()) }
        runCatching {
            if (!directory.exists() && !directory.mkdirs()) {
                throw IOException("the history directory could not be created")
            }

            // Flush a complete sibling first, then replace the index in one filesystem operation.
            // An interrupted in-place write used to turn every history row into invalid JSON.
            FileOutputStream(temporaryIndexFile).use { output ->
                val writer = OutputStreamWriter(output, StandardCharsets.UTF_8)
                writer.write(array.toString())
                writer.flush()
                output.fd.sync()
            }
            try {
                Files.move(
                    temporaryIndexFile.toPath(), indexFile.toPath(),
                    StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING,
                )
            } catch (_: AtomicMoveNotSupportedException) {
                Files.move(
                    temporaryIndexFile.toPath(), indexFile.toPath(),
                    StandardCopyOption.REPLACE_EXISTING,
                )
            }
        }.onFailure { error ->
            temporaryIndexFile.delete()
            log.error(
                mapOf("type" to error.javaClass.simpleName),
            ) { "could not persist history; the previous index is still intact" }
        }
    }

    /** A history file is data, not authority to read or delete an arbitrary path. */
    private fun audioFile(name: String): File? {
        if (name.isBlank() || File(name).isAbsolute || File(name).name != name ||
            name.contains('/') || name.contains('\\')
        ) {
            log.warn { "ignored an unsafe audio filename in history" }
            return null
        }
        return File(audioDirectory, name)
    }
}
