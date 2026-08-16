package app.donottype.core

import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Structured logging, ported from the Swift core so the three platforms produce comparable output.
 *
 * ## Why not just `android.util.Log`
 *
 * Logcat is the right transport and a bad interface for this. It needs a cable and a computer,
 * which rules it out for the person who has the bug; it is ring-buffered by the system, so the
 * interesting lines are gone by the time anyone looks; and an IME is the one process where nobody
 * is watching a console when the failure happens. What was missing is the same four things the
 * desktop was missing: a level you can turn up, a file you can attach to a report, anything at all
 * from inside the core, and a redaction rule that makes the first three safe.
 *
 * Logcat stays as one sink among several, so `adb logcat` keeps working for anyone who already
 * knows how.
 *
 * ## The privacy rule
 *
 * Transcripts and screen contents are content, and content is never written unless the user turns
 * it on. A line records that a 412-character transcript came back, not what it said. [Log.content]
 * is the one door between the two and it is closed by default — which matters more here than on a
 * laptop, because on Android the screen this app reads belongs to whatever app you were using.
 */
enum class LogLevel(val id: String, val severity: Int) {
    /** Per-chunk, per-retry detail. Verbose enough to read a whole dictation from. */
    TRACE("trace", 0),

    /** The decisions: which route, which backend, how big, how long. */
    DEBUG("debug", 1),

    /** One line per meaningful event. The default. */
    INFO("info", 2),

    /** Something degraded but recovered — a fallback fired, an encoder was missing. */
    WARN("warn", 3),

    /** Something failed and the user noticed. */
    ERROR("error", 4),

    /** Nothing at all. */
    OFF("off", 5),
    ;

    /** Fixed width, so a column of log lines stays a column. */
    val padded: String get() = id.uppercase().padEnd(5)

    companion object {
        val DEFAULT = INFO

        /** Accepts the spellings people actually type, including `warning` and `silent`. */
        fun from(id: String?): LogLevel? = when (id?.trim()?.lowercase()) {
            "trace", "verbose" -> TRACE
            "debug" -> DEBUG
            "info", "default" -> INFO
            "warn", "warning" -> WARN
            "error", "err" -> ERROR
            "off", "none", "silent", "quiet" -> OFF
            else -> null
        }
    }
}

/** One line in the log. */
data class LogEvent(
    val id: Long,
    val timestamp: Long,
    val level: LogLevel,
    val category: String,
    val message: String,
    /** Rendered sorted, so two runs of the same code produce comparable output. */
    val fields: Map<String, String> = emptyMap(),
) {
    /**
     * `2026-08-16T12:04:31.512 INFO  dictation  transcribed  chars=142 ms=980`
     *
     * The date is in the stamp because the log file rotates on size rather than on the day, so one
     * file holds however many days it takes to fill and a time-of-day cannot say which of them a
     * line belongs to. One token rather than a space between date and time: the level is found by
     * splitting the line on spaces and taking the second column, and a stamp with a space in it
     * would shift every column silently.
     */
    fun render(includeTime: Boolean = true): String = buildString {
        if (includeTime) {
            append(TIME.format(Date(timestamp)))
            append(' ')
        }
        append(level.padded)
        append(' ')
        append(category.padEnd(12))
        append(' ')
        append(message)
        if (fields.isNotEmpty()) {
            append("  ")
            append(
                fields.keys.sorted().joinToString(" ") { key ->
                    val value = flatten(fields.getValue(key))
                    if (value.contains(' ') || value.isEmpty()) "$key=\"$value\"" else "$key=$value"
                },
            )
        }
    }

    private companion object {
        val TIME = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS", Locale.US)

        /**
         * A field value, kept whole and kept on one line.
         *
         * Escaped rather than shortened. A response body belongs in the log in full — it is the
         * thing somebody is reading the log to see — but a raw newline inside it would split one
         * entry into several, and every line after the first would have no timestamp, level or
         * category. A grep would then find a fragment and show it without the message it belongs to.
         */
        fun flatten(value: String): String = value
            .replace("\\", "\\\\")
            .replace("\n", "\\n")
            .replace("\r", "\\r")
            .replace("\"", "\\\"")
    }
}

/** Somewhere a log line goes. */
interface LogSink {
    fun write(event: LogEvent)
    fun flush() {}
}

/**
 * The one place a log line passes through: filters by level, redacts, fans out to sinks, and keeps
 * the last few thousand events in memory for the in-app viewer.
 *
 * Synchronised rather than suspending, because logging has to be callable from an audio callback
 * and from `InputMethodService` lifecycle methods without a coroutine — a logger you cannot call
 * from the hot path is one nobody calls.
 */
object LogRouter {
    private val lock = Any()
    private var level: LogLevel = LogLevel.DEFAULT
    private var sinks: List<LogSink> = emptyList()
    private val buffer = ArrayDeque<LogEvent>()
    private var capacity = 4_000
    private var nextId = 1L
    private val secrets = mutableListOf<String>()
    private var contentAllowed = false
    private var file: File? = null

    /**
     * Installs the sinks. Called once at startup, and again whenever the level changes.
     *
     * @param directory where the log file goes, or null for logcat and memory only.
     */
    fun start(
        directory: File?,
        level: LogLevel = LogLevel.DEFAULT,
        includesContent: Boolean = false,
        useLogcat: Boolean = true,
        maximumFileBytes: Long = 4L * 1024 * 1024,
    ) {
        val built = buildList<LogSink> {
            if (useLogcat) add(LogcatSink())
            if (directory != null) {
                FileLogSink(File(directory, "donottype.log"), maximumFileBytes)?.let { add(it) }
            }
        }
        synchronized(lock) {
            this.level = level
            this.sinks = built
            this.contentAllowed = includesContent
            this.file = directory?.let { File(it, "donottype.log") }
            trim()
        }
    }

    fun setLevel(newLevel: LogLevel) = synchronized(lock) { level = newLevel }

    fun currentLevel(): LogLevel = synchronized(lock) { level }

    fun includesContent(): Boolean = synchronized(lock) { contentAllowed }

    fun setIncludesContent(allowed: Boolean) = synchronized(lock) { contentAllowed = allowed }

    /** The file being appended to, for the viewer's share button. */
    fun file(): File? = synchronized(lock) { file }

    /**
     * Registers a value that must never appear in a log line, whatever route it takes there.
     *
     * Pattern matching alone is not enough: a key echoed back inside a provider's error body does
     * not look like a key by the time it arrives. The app registers every configured key at
     * startup, so the exact bytes are known.
     */
    fun redact(secret: String?) {
        val trimmed = secret?.trim().orEmpty()
        if (trimmed.length < 8) return
        synchronized(lock) { if (!secrets.contains(trimmed)) secrets.add(trimmed) }
    }

    fun isEnabled(candidate: LogLevel): Boolean = synchronized(lock) {
        level != LogLevel.OFF && candidate.severity >= level.severity
    }

    fun emit(candidate: LogLevel, category: String, message: String, fields: Map<String, String>) {
        val event: LogEvent
        val targets: List<LogSink>
        synchronized(lock) {
            if (level == LogLevel.OFF || candidate.severity < level.severity) return
            val known = secrets.toList()
            event = LogEvent(
                id = nextId++,
                timestamp = System.currentTimeMillis(),
                level = candidate,
                category = category,
                message = Redaction.scrub(message, known),
                fields = fields.mapValues { Redaction.scrub(it.value, known) },
            )
            buffer.addLast(event)
            trim()
            targets = sinks
        }
        targets.forEach { it.write(event) }
    }

    /** Newest last, filtered. The viewer polls this; it is a copy, so the UI never holds the lock. */
    fun recent(
        limit: Int = 500,
        minimumLevel: LogLevel = LogLevel.TRACE,
        containing: String = "",
    ): List<LogEvent> {
        val snapshot = synchronized(lock) { buffer.toList() }
        val needle = containing.trim().lowercase()
        return snapshot.filter { event ->
            event.level.severity >= minimumLevel.severity && (
                needle.isEmpty() ||
                    event.message.lowercase().contains(needle) ||
                    event.category.lowercase().contains(needle) ||
                    event.fields.any {
                        it.key.lowercase().contains(needle) || it.value.lowercase().contains(needle)
                    }
                )
        }.takeLast(limit)
    }

    /** Monotonic count, so the viewer can tell whether anything changed without diffing. */
    fun emittedCount(): Long = synchronized(lock) { nextId - 1 }

    fun clearBuffer() = synchronized(lock) { buffer.clear() }

    fun flush() {
        val targets = synchronized(lock) { sinks }
        targets.forEach { it.flush() }
    }

    /** Test seam: swap the sinks for one that records, without touching the file or logcat. */
    fun install(replacement: List<LogSink>, level: LogLevel = LogLevel.TRACE) = synchronized(lock) {
        sinks = replacement
        this.level = level
        file = null
        secrets.clear()
        buffer.clear()
        contentAllowed = false
    }

    private fun trim() {
        while (buffer.size > capacity) buffer.removeFirst()
    }
}

/**
 * A category handle, held as a `val` on the class that logs.
 *
 * The message is a lambda so building it costs nothing when the level is off, which is what makes
 * it reasonable to leave trace calls in hot paths permanently.
 */
class Log(private val category: String) {

    fun trace(fields: Map<String, String> = emptyMap(), message: () -> String) =
        write(LogLevel.TRACE, fields, message)

    fun debug(fields: Map<String, String> = emptyMap(), message: () -> String) =
        write(LogLevel.DEBUG, fields, message)

    fun info(fields: Map<String, String> = emptyMap(), message: () -> String) =
        write(LogLevel.INFO, fields, message)

    fun warn(fields: Map<String, String> = emptyMap(), message: () -> String) =
        write(LogLevel.WARN, fields, message)

    fun error(fields: Map<String, String> = emptyMap(), message: () -> String) =
        write(LogLevel.ERROR, fields, message)

    /**
     * The user's words, or their screen. The size is always logged; the text only when the user
     * has turned content logging on.
     */
    fun content(message: String, level: LogLevel = LogLevel.DEBUG, text: () -> String) {
        if (!LogRouter.isEnabled(level)) return
        val value = text()
        val fields = buildMap {
            put("chars", value.length.toString())
            if (LogRouter.includesContent()) put("text", value)
        }
        LogRouter.emit(level, category, message, fields)
    }

    private inline fun write(
        level: LogLevel,
        fields: Map<String, String>,
        message: () -> String,
    ) {
        if (!LogRouter.isEnabled(level)) return
        LogRouter.emit(level, category, message(), fields)
    }
}

/**
 * Appends to a file, rotating once it gets big.
 *
 * One previous generation is kept. Two is not obviously better, and "the log ate the storage" is a
 * real way for a keyboard to ruin someone's day.
 */
class FileLogSink private constructor(
    private val file: File,
    private val maximumBytes: Long,
) : LogSink {
    private val lock = Any()

    companion object {
        operator fun invoke(file: File, maximumBytes: Long): FileLogSink? = try {
            file.parentFile?.mkdirs()
            if (!file.exists()) file.createNewFile()
            FileLogSink(file, maximumBytes)
        } catch (_: Exception) {
            // A log that cannot be written must never stop the app that was trying to write it.
            null
        }
    }

    override fun write(event: LogEvent) {
        synchronized(lock) {
            try {
                file.appendText(event.render() + "\n")
                if (file.length() > maximumBytes) rotate()
            } catch (_: Exception) {
                // Same reasoning as above.
            }
        }
    }

    private fun rotate() {
        val previous = File(file.parentFile, file.name + ".1")
        previous.delete()
        file.renameTo(previous)
        file.createNewFile()
    }
}

/** Keeps `adb logcat` working for anyone who already knows how. */
class LogcatSink(private val tag: String = "DoNotType") : LogSink {
    override fun write(event: LogEvent) {
        val line = event.render(includeTime = false)
        when (event.level) {
            LogLevel.TRACE, LogLevel.DEBUG -> android.util.Log.d(tag, line)
            LogLevel.INFO -> android.util.Log.i(tag, line)
            LogLevel.WARN -> android.util.Log.w(tag, line)
            LogLevel.ERROR -> android.util.Log.e(tag, line)
            LogLevel.OFF -> Unit
        }
    }
}

/** Collects events in memory. For tests, and for anything that wants the log without a file. */
class MemoryLogSink : LogSink {
    private val lock = Any()
    private val storage = mutableListOf<LogEvent>()

    override fun write(event: LogEvent) {
        synchronized(lock) { storage.add(event) }
    }

    val events: List<LogEvent> get() = synchronized(lock) { storage.toList() }
}

/**
 * Keeps secrets out of a log that exists to be shared.
 *
 * Two mechanisms, because either alone leaks. Registered secrets catch the key this app is using
 * wherever it turns up, including inside a URL or a provider's own error message echoing it back.
 * Pattern matching catches a key belonging to something else that this process was never told
 * about.
 */
object Redaction {
    /** Prefixes that mean "the rest of this token is a credential", regardless of length. */
    private val SECRET_PREFIXES = listOf("sk-", "sk_", "AIza", "xai-", "gsk_", "dg_", "pk_", "ghp_")

    /** A run of opaque token characters this long is not a word in any language. */
    private const val OPAQUE_LENGTH = 32

    fun scrub(text: String, secrets: List<String>): String {
        var result = text
        // Longest first, so a key containing another registered value still masks fully.
        secrets.sortedByDescending { it.length }.filter { it.isNotEmpty() }.forEach { secret ->
            result = result.replace(secret, mask(secret))
        }
        return scrubPatterns(result)
    }

    fun mask(secret: String): String = "‹redacted ${secret.length}-char secret›"

    /**
     * Walks token runs and masks anything credential-shaped.
     *
     * Hand-rolled rather than a regular expression so the behaviour is obvious from reading it —
     * this runs on every log line and has to be boring.
     */
    fun scrubPatterns(text: String): String {
        val output = StringBuilder()
        val token = StringBuilder()

        fun flush() {
            output.append(if (looksSecret(token.toString())) "‹redacted›" else token)
            token.setLength(0)
        }

        text.forEach { character ->
            if (character.isLetterOrDigit() || character == '-' || character == '_' || character == '.') {
                token.append(character)
            } else {
                flush()
                output.append(character)
            }
        }
        flush()
        return output.toString()
    }

    fun looksSecret(token: String): Boolean {
        if (token.length < 12) return false
        if (SECRET_PREFIXES.any { token.startsWith(it) && token.length > it.length + 6 }) return true
        if (token.length < OPAQUE_LENGTH) return false
        // Opaque means no separators, with digits and letters mixed — enough to exclude a long
        // identifier from a stack trace and include a base64-ish key.
        val hasDigit = token.any { it.isDigit() }
        val hasLetter = token.any { it.isLetter() }
        val hasSeparator = token.any { it == '.' || it == '-' || it == '_' }
        return hasDigit && hasLetter && !hasSeparator
    }
}

/** Milliseconds as a log field. Rounded — nobody debugged anything with the fourth decimal. */
fun ms(millis: Long): String = millis.toString()
