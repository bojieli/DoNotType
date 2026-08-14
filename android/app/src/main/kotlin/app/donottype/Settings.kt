package app.donottype

import app.donottype.core.Fidelity
import app.donottype.core.Log
import app.donottype.core.LogLevel
import app.donottype.core.LogRouter
import app.donottype.core.ProviderKind
import app.donottype.core.RetentionPolicy
import app.donottype.core.TranscriptMode
import android.content.Context
import android.content.SharedPreferences

/**
 * Preferences and the API key.
 *
 * Android has no per-app Keychain equivalent that an IME can reach without a foreground activity,
 * so the key lives in private `SharedPreferences` — readable only by this UID. That is weaker than
 * the macOS Keychain and worth being honest about in onboarding.
 */
object Settings {
    private const val FILE = "donottype"
    private const val KEY_API = "apiKey"
    private const val KEY_PROVIDER = "provider"
    private const val KEY_MODEL = "model"
    private const val KEY_KEYTERMS = "keytermBiasing"
    private const val KEY_FALLBACK = "fallbackProvider"
    private const val KEY_FALLBACK_AFTER = "fallbackAfterSeconds"
    private const val KEY_FIDELITY = "fidelity"
    private const val KEY_GROUNDING = "grounding"
    private const val KEY_BLOCKED = "blockedPackages"
    private const val KEY_RETENTION = "retention"
    private const val KEY_KEEP_AUDIO = "keepAudio"
    private const val KEY_LOG_LEVEL = "logLevel"
    private const val KEY_LOG_CONTENT = "logContent"
    private const val KEY_FILE_MODE = "fileMode"

    /**
     * Shipped non-empty. A blocklist that starts empty is one nobody ever fills in, and this app
     * transmits screen contents.
     */
    val DEFAULT_BLOCKED = setOf(
        "com.google.android.apps.authenticator2",
        "com.x8bit.bitwarden",
        "com.agilebits.onepassword",
        "com.lastpass.lpandroid",
        "com.android.settings",
    )

    private lateinit var prefs: SharedPreferences

    fun initialise(context: Context) {
        if (::prefs.isInitialized) return
        prefs = context.applicationContext.getSharedPreferences(FILE, Context.MODE_PRIVATE)
        // Started here rather than by each entry point, because there are three of them -- the
        // settings screen, the file screen and the keyboard service -- and the one that matters
        // most for debugging is the keyboard, which nobody remembers to wire up.
        startLogging(context)
    }

    private val ready: Boolean get() = ::prefs.isInitialized

    var provider: ProviderKind
        get() = if (ready) ProviderKind.from(prefs.getString(KEY_PROVIDER, null)) else ProviderKind.DEFAULT
        set(value) { if (ready) prefs.edit().putString(KEY_PROVIDER, value.id).apply() }

    /**
     * The key for the *selected* provider.
     *
     * Stored per provider rather than as one field. Switching backends to compare them is the
     * whole point of having more than one, and a single shared key would make every switch a
     * re-typing exercise — which in practice means nobody switches.
     *
     * The legacy single-key preference is read as Gemini's, so an existing install keeps working
     * without a migration step that could lose someone their key.
     */
    var apiKey: String?
        get() = keyFor(provider)
        set(value) { setKey(provider, value) }

    fun keyFor(kind: ProviderKind): String? {
        if (!ready) return null
        prefs.getString("$KEY_API-${kind.id}", null)?.takeIf { it.isNotEmpty() }?.let { return it }
        return if (kind == ProviderKind.GEMINI) prefs.getString(KEY_API, null) else null
    }

    fun setKey(kind: ProviderKind, value: String?) {
        if (ready) prefs.edit().putString("$KEY_API-${kind.id}", value).apply()
    }

    /**
     * The model for the selected provider, defaulting to that provider's own default rather than
     * to Gemini's — otherwise choosing Deepgram would send `gemini-3.6-flash` to `/v1/listen`.
     */
    var model: String
        get() {
            if (!ready) return ProviderKind.DEFAULT.defaultModel
            return prefs.getString("$KEY_MODEL-${provider.id}", null)
                ?.takeIf { it.isNotEmpty() }
                ?: legacyModelOrDefault()
        }
        set(value) { if (ready) prefs.edit().putString("$KEY_MODEL-${provider.id}", value).apply() }

    /** The model for a backend that is not the current selection — the fallback needs its own. */
    fun modelFor(kind: ProviderKind): String {
        if (!ready) return kind.defaultModel
        return prefs.getString("$KEY_MODEL-${kind.id}", null)?.takeIf { it.isNotEmpty() }
            ?: kind.defaultModel
    }

    private fun legacyModelOrDefault(): String {
        val legacy = prefs.getString(KEY_MODEL, null)
        return if (provider == ProviderKind.GEMINI && !legacy.isNullOrEmpty()) legacy
        else provider.defaultModel
    }

    /**
     * Whether a recognition backend may be given a word list derived from the screen.
     *
     * Off by default, unlike [groundingEnabled], and the two are not one feature wearing different
     * hats: grounding hands a model the screen text under an explicit "reference only" instruction,
     * while a keyterm list is a bare vocabulary prior with no way to say that. See [Keyterms] for
     * what it refuses to send.
     */
    /**
     * Backend started alongside the primary when it has not answered in time. Null disables it.
     *
     * Off by default. Hedging costs a second request and can hand back a less accurate transcript,
     * so it is something to turn on after being bitten by the primary's latency tail.
     */
    var fallbackProvider: ProviderKind?
        get() {
            if (!ready) return null
            val raw = prefs.getString(KEY_FALLBACK, null).orEmpty()
            if (raw.isEmpty()) return null
            // A fallback identical to the primary would double the cost to no purpose.
            return ProviderKind.entries.firstOrNull { it.id == raw }?.takeIf { it != provider }
        }
        set(value) { if (ready) prefs.edit().putString(KEY_FALLBACK, value?.id ?: "").apply() }

    /**
     * How long the primary gets alone before the fallback starts alongside it — the
     * accuracy-against-latency dial. Clamped so a hand-edited preference cannot race from zero.
     */
    var fallbackAfterSeconds: Int
        get() = if (ready) prefs.getInt(KEY_FALLBACK_AFTER, 8).coerceIn(1, 120) else 8
        set(value) { if (ready) prefs.edit().putInt(KEY_FALLBACK_AFTER, value.coerceIn(1, 120)).apply() }

    var keytermBiasing: Boolean
        get() = ready && prefs.getBoolean(KEY_KEYTERMS, false)
        set(value) { if (ready) prefs.edit().putBoolean(KEY_KEYTERMS, value).apply() }

    var fidelity: Fidelity
        get() = if (ready) Fidelity.from(prefs.getString(KEY_FIDELITY, null)) else Fidelity.DEFAULT
        set(value) { if (ready) prefs.edit().putString(KEY_FIDELITY, value.id).apply() }

    var groundingEnabled: Boolean
        get() = !ready || prefs.getBoolean(KEY_GROUNDING, true)
        set(value) { if (ready) prefs.edit().putBoolean(KEY_GROUNDING, value).apply() }

    var blockedPackages: Set<String>
        get() = if (ready) prefs.getStringSet(KEY_BLOCKED, DEFAULT_BLOCKED) ?: DEFAULT_BLOCKED
                else DEFAULT_BLOCKED
        set(value) { if (ready) prefs.edit().putStringSet(KEY_BLOCKED, value).apply() }

    var retention: RetentionPolicy
        get() = if (ready) RetentionPolicy.from(prefs.getString(KEY_RETENTION, null))
                else RetentionPolicy.FOREVER
        set(value) { if (ready) prefs.edit().putString(KEY_RETENTION, value.id).apply() }

    /**
     * Keep audio for successful dictations too. Off by default; failed entries always keep theirs
     * until they succeed, so Retry stays possible either way.
     */
    var keepAudio: Boolean
        get() = ready && prefs.getBoolean(KEY_KEEP_AUDIO, false)
        set(value) { if (ready) prefs.edit().putBoolean(KEY_KEEP_AUDIO, value).apply() }

    /**
     * How much the app and the keyboard write to the log file.
     *
     * A setting rather than only an environment variable, because there is no environment to set on
     * a phone: the person who needs the detail has a device in their hand and no shell.
     */
    var logLevel: LogLevel
        get() = if (ready) LogLevel.from(prefs.getString(KEY_LOG_LEVEL, null)) ?: LogLevel.DEFAULT
                else LogLevel.DEFAULT
        set(value) {
            if (ready) prefs.edit().putString(KEY_LOG_LEVEL, value.id).apply()
            LogRouter.setLevel(value)
        }

    /**
     * Whether transcripts and screen text may go into the log.
     *
     * Off, and it stays off unless someone deliberately turns it on. A log file is the artifact
     * most likely to be shared out of this app, and on Android the screen it reads belongs to
     * whatever app the user was in.
     */
    var logContent: Boolean
        get() = ready && prefs.getBoolean(KEY_LOG_CONTENT, false)
        set(value) {
            if (ready) prefs.edit().putBoolean(KEY_LOG_CONTENT, value).apply()
            LogRouter.setIncludesContent(value)
        }

    /** Last mode chosen on the file screen, so it opens where it was left. */
    var fileMode: TranscriptMode
        get() = if (ready) TranscriptMode.from(prefs.getString(KEY_FILE_MODE, null))
                ?: TranscriptMode.DEFAULT
                else TranscriptMode.DEFAULT
        set(value) { if (ready) prefs.edit().putString(KEY_FILE_MODE, value.id).apply() }

    /**
     * Starts logging for this process, and registers every configured key for masking.
     *
     * Registered up front rather than at the point of use: a key reaches a log by routes nobody
     * planned — a provider echoing it back inside an error body, for one — and the only reliable
     * defence is knowing the exact bytes before the first request.
     */
    fun startLogging(context: Context) {
        LogRouter.start(
            directory = java.io.File(context.applicationContext.filesDir, "logs"),
            level = logLevel,
            includesContent = logContent,
        )
        ProviderKind.entries.forEach { LogRouter.redact(keyFor(it)) }

        Log("app").info(
            mapOf(
                "level" to logLevel.id,
                "provider" to provider.id,
                "model" to model,
                "log" to (LogRouter.file()?.name ?: "none"),
            ),
        ) { "started" }
    }

    /** Evaluated before capture, never after — see CONTEXT_FORMAT.md. */
    fun isBlocked(packageName: String?): Boolean {
        if (packageName == null) return false
        if (packageName == "app.donottype") return true
        return blockedPackages.any { it.equals(packageName, ignoreCase = true) }
    }
}
