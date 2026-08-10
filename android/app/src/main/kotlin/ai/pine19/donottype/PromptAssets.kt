package ai.pine19.donottype

import ai.pine19.donottype.core.Fidelity
import android.content.Context

/**
 * Reads PROMPT.md out of the APK assets.
 *
 * The same file the macOS app bundles and the eval harness runs against — it is copied into
 * `assets/` by the Gradle build rather than duplicated, so the three platforms cannot drift.
 */
object PromptAssets {
    private const val ASSET = "PROMPT.md"
    private const val BEGIN = "<!-- BEGIN SYSTEM -->"
    private const val END = "<!-- END SYSTEM -->"
    private const val PLACEHOLDER = "{{FIDELITY_RULE}}"
    private const val CUSTOM_FILE = "PROMPT.md"

    private var cached: String? = null

    /** The user's edited prompt, if they have saved one. */
    private fun customFile(context: Context) = java.io.File(context.filesDir, CUSTOM_FILE)

    fun hasCustomPrompt(context: Context): Boolean = customFile(context).exists()

    /** The text in force: the edited copy when present, otherwise the bundled default. */
    fun activeTemplate(context: Context): String {
        val custom = customFile(context)
        if (custom.exists()) {
            val text = runCatching { custom.readText() }.getOrNull()
            if (!text.isNullOrBlank()) return text
        }
        return bundledTemplate(context)
    }

    fun bundledTemplate(context: Context): String =
        context.assets.open(ASSET).bufferedReader().use { it.readText() }

    /**
     * Validated before writing. A prompt that cannot build would fail mid-dictation rather than
     * at the moment of editing, and every fidelity must resolve or switching to one later breaks.
     */
    fun saveCustomPrompt(context: Context, template: String) {
        require(template.isNotBlank()) { "The prompt is empty." }
        require(template.contains(BEGIN) && template.contains(END)) {
            "The prompt needs a $BEGIN … $END block."
        }
        require(template.contains(PLACEHOLDER)) {
            "The system block needs a $PLACEHOLDER placeholder."
        }
        Fidelity.entries.forEach { build(template, it) }

        customFile(context).writeText(template)
        cached = null
    }

    fun restoreDefault(context: Context) {
        customFile(context).delete()
        cached = null
    }

    fun systemInstruction(context: Context, fidelity: Fidelity): String {
        val template = cached ?: activeTemplate(context).also { cached = it }
        return build(template, fidelity)
    }

    private fun build(template: String, fidelity: Fidelity): String {

        val begin = template.indexOf(BEGIN)
        val end = template.indexOf(END)
        require(begin >= 0 && end > begin) { "PROMPT.md is missing its system markers" }

        val body = template.substring(begin + BEGIN.length, end).trim()
        require(body.contains(PLACEHOLDER)) { "PROMPT.md has no $PLACEHOLDER" }
        return body.replace(PLACEHOLDER, clause(template, fidelity))
    }

    /** Pulls the fenced clause out of the `### <fidelity>` section. */
    private fun clause(template: String, fidelity: Fidelity): String {
        val heading = "### ${fidelity.id}"
        val start = template.indexOf(heading)
        require(start >= 0) { "PROMPT.md has no section $heading" }

        val open = template.indexOf("```", start)
        val close = template.indexOf("```", open + 3)
        require(open >= 0 && close > open) { "no fenced clause under $heading" }

        return template.substring(open + 3, close).trim().replace("\n", " ")
    }
}
