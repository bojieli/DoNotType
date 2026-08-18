package app.donottype

import android.content.Context
import android.content.SharedPreferences
import app.donottype.core.Fidelity
import app.donottype.core.Log
import app.donottype.core.LogLevel
import app.donottype.core.LogRouter
import app.donottype.core.ProviderKind
import app.donottype.core.PersonalDictionary
import app.donottype.core.RewriteStyle
import app.donottype.core.RetentionPolicy
import app.donottype.core.TranscriptMode
import org.json.JSONArray

/**
 * Preferences and the API key.
 *
 * Provider keys are encrypted with a non-exportable AES key in Android Keystore. The encrypted
 * envelopes live in this app's private preferences so the settings activity, file activity and
 * input method can all use them without requiring a foreground authentication prompt.
 */
object Settings {
    private const val FILE = "donottype"
    private const val KEY_API = "apiKey"
    private const val KEY_PROVIDER = "provider"
    private const val KEY_MODEL = "model"
    private const val KEY_LIVE_STYLE = "liveStyle"
    private const val KEY_REWRITE_STYLE = "rewriteStyle"
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
    private const val KEY_DICTIONARY = "personalDictionary"
    private const val KEY_LEARNED_DICTIONARY = "learnedPersonalDictionary"
    private const val KEY_LEARN_FROM_EDITS = "learnDictionaryFromEdits"

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

    // Written last by initialise(); the volatile write publishes apiKeys to entry points that read
    // settings without taking initialise()'s monitor (activity, file screen, and IME service).
    @Volatile private lateinit var prefs: SharedPreferences
    private lateinit var apiKeys: ApiKeyStore

    @Synchronized
    fun initialise(context: Context) {
        if (::prefs.isInitialized) return
        val localPreferences =
            context.applicationContext.getSharedPreferences(FILE, Context.MODE_PRIVATE)
        apiKeys = ApiKeyStore(localPreferences)
        // Publish the readiness sentinel last so a concurrent entry point cannot observe prefs
        // without the secure key store that all API-key access now requires.
        prefs = localPreferences
        // Started here rather than by each entry point, because there are three of them -- the
        // settings screen, the file screen and the keyboard service -- and the one that matters
        // most for debugging is the keyboard, which nobody remembers to wire up.
        startLogging(context)
    }

    private val ready: Boolean get() = ::prefs.isInitialized && ::apiKeys.isInitialized

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
        val providerPreference = "$KEY_API-${kind.id}"
        apiKeys.read(providerPreference)?.let { return it }
        if (kind != ProviderKind.GEMINI) return null

        // The original Android app had one Gemini-only key. Move it into the per-provider store
        // only after the encrypted write succeeds so an upgrade cannot lose a working key.
        val legacy = apiKeys.read(KEY_API) ?: return null
        if (setKey(kind, legacy)) runCatching { apiKeys.write(KEY_API, null) }
        return legacy
    }

    fun setKey(kind: ProviderKind, value: String?): Boolean {
        if (!ready) return false
        return runCatching {
            apiKeys.write("$KEY_API-${kind.id}", value)
            // Once the provider-specific slot is deliberately written, the legacy Gemini-only
            // slot must not reappear when that value is cleared by an imported profile.
            if (kind == ProviderKind.GEMINI) apiKeys.write(KEY_API, null)
            LogRouter.redact(value)
        }.fold(
            onSuccess = { true },
            onFailure = { error ->
                Log("settings").error(
                    mapOf("detail" to (error.message ?: error.javaClass.simpleName)),
                ) { "could not store an API key securely" }
                false
            },
        )
    }

    /**
     * The model for the selected provider, defaulting to that provider's own default rather than
     * to Gemini's — otherwise choosing Deepgram would send `gemini-3.5-flash` to `/v1/listen`.
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

    /** What the next keyboard dictation produces. The keyboard exposes only Dictate or Rewrite. */
    var liveStyle: RewriteStyle
        get() = if (ready) {
            RewriteStyle.from(prefs.getString(KEY_LIVE_STYLE, null)) ?: RewriteStyle.VERBATIM
        } else {
            RewriteStyle.VERBATIM
        }
        set(value) { if (ready) prefs.edit().putString(KEY_LIVE_STYLE, value.id).apply() }

    /** The configured style behind Rewrite, kept when the keyboard switches back to Dictate. */
    var preferredRewriteStyle: RewriteStyle
        get() {
            if (!ready) return RewriteStyle.FORMAL
            val stored = RewriteStyle.from(prefs.getString(KEY_REWRITE_STYLE, null))
            if (stored?.isRewrite == true) return stored
            return liveStyle.takeIf { it.isRewrite } ?: RewriteStyle.FORMAL
        }
        set(value) {
            if (!ready || !value.isRewrite) return
            prefs.edit().putString(KEY_REWRITE_STYLE, value.id).apply()
            if (liveStyle.isRewrite) liveStyle = value
        }

    var rewriteModeEnabled: Boolean
        get() = liveStyle.isRewrite
        set(value) {
            liveStyle = if (value) preferredRewriteStyle else RewriteStyle.VERBATIM
        }

    var keytermBiasing: Boolean
        get() = ready && prefs.getBoolean(KEY_KEYTERMS, false)
        set(value) { if (ready) prefs.edit().putBoolean(KEY_KEYTERMS, value).apply() }

    var dictionaryTerms: List<String>
        @Synchronized get() = PersonalDictionary.sanitize(readStringList(KEY_DICTIONARY))
        @Synchronized set(value) {
            if (ready) writeStringList(KEY_DICTIONARY, PersonalDictionary.sanitize(value))
        }

    var learnedDictionaryTerms: List<String>
        @Synchronized get() {
            val manual = dictionaryTerms.mapTo(mutableSetOf()) { it.lowercase() }
            return PersonalDictionary.sanitize(readStringList(KEY_LEARNED_DICTIONARY))
                .filter { it.lowercase() !in manual }
                .take(PersonalDictionary.MAX_TERMS - manual.size)
        }
        @Synchronized set(value) {
            if (ready) writeStringList(KEY_LEARNED_DICTIONARY, PersonalDictionary.sanitize(value))
        }

    var learnDictionaryFromEdits: Boolean
        get() = ready && prefs.getBoolean(KEY_LEARN_FROM_EDITS, false)
        set(value) { if (ready) prefs.edit().putBoolean(KEY_LEARN_FROM_EDITS, value).apply() }

    @Synchronized fun personalDictionaryTerms(): List<String> =
        PersonalDictionary.sanitize(dictionaryTerms + learnedDictionaryTerms)

    /** Stores only newly learned spellings and returns them for the keyboard's undo affordance. */
    @Synchronized fun learnDictionaryTerms(candidates: Iterable<String>): List<String> {
        val combined = personalDictionaryTerms().toMutableList()
        val learned = learnedDictionaryTerms.toMutableList()
        val seen = combined.mapTo(mutableSetOf()) { it.lowercase() }
        val added = mutableListOf<String>()
        for (raw in candidates) {
            val term = runCatching { PersonalDictionary.normalize(raw) }.getOrNull() ?: continue
            if (combined.size >= PersonalDictionary.MAX_TERMS || !seen.add(term.lowercase())) continue
            combined.add(term)
            learned.add(term)
            added.add(term)
        }
        if (added.isNotEmpty()) learnedDictionaryTerms = learned
        return added
    }

    @Synchronized fun forgetLearnedDictionaryTerms(terms: Iterable<String>) {
        val removed = terms.mapTo(mutableSetOf()) { it.lowercase() }
        learnedDictionaryTerms = learnedDictionaryTerms.filter { it.lowercase() !in removed }
    }

    @Synchronized fun replaceDictionaryTerm(original: String, replacement: String, learned: Boolean) {
        val normalized = PersonalDictionary.normalize(replacement)
        if (personalDictionaryTerms().any {
                !it.equals(original, ignoreCase = true) && it.equals(normalized, ignoreCase = true)
            }
        ) throw PersonalDictionary.ValidationException("“$normalized” is already in the dictionary.")
        val terms = (if (learned) learnedDictionaryTerms else dictionaryTerms).toMutableList()
        val index = terms.indexOf(original)
        if (index >= 0) terms[index] = normalized
        if (learned) learnedDictionaryTerms = terms else dictionaryTerms = terms
    }

    @Synchronized fun removeDictionaryTerm(term: String, learned: Boolean) {
        if (learned) learnedDictionaryTerms = learnedDictionaryTerms.filterNot { it == term }
        else dictionaryTerms = dictionaryTerms.filterNot { it == term }
    }

    private fun readStringList(key: String): List<String> {
        if (!ready) return emptyList()
        return runCatching {
            val json = JSONArray(prefs.getString(key, "[]") ?: "[]")
            List(json.length()) { json.getString(it) }
        }.getOrDefault(emptyList())
    }

    private fun writeStringList(key: String, values: Iterable<String>) {
        prefs.edit().putString(key, JSONArray(values.toList()).toString()).apply()
    }

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
