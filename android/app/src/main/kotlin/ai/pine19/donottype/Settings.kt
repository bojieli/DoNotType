package ai.pine19.donottype

import ai.pine19.donottype.core.Fidelity
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
    private const val KEY_MODEL = "model"
    private const val KEY_FIDELITY = "fidelity"
    private const val KEY_GROUNDING = "grounding"
    private const val KEY_BLOCKED = "blockedPackages"

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
    }

    private val ready: Boolean get() = ::prefs.isInitialized

    var apiKey: String?
        get() = if (ready) prefs.getString(KEY_API, null) else null
        set(value) { if (ready) prefs.edit().putString(KEY_API, value).apply() }

    var model: String
        get() = if (ready) prefs.getString(KEY_MODEL, null) ?: "gemini-3.6-flash" else "gemini-3.6-flash"
        set(value) { if (ready) prefs.edit().putString(KEY_MODEL, value).apply() }

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

    /** Evaluated before capture, never after — see CONTEXT_FORMAT.md. */
    fun isBlocked(packageName: String?): Boolean {
        if (packageName == null) return false
        if (packageName == "ai.pine19.donottype") return true
        return blockedPackages.any { it.equals(packageName, ignoreCase = true) }
    }
}
