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

    private var cached: String? = null

    fun systemInstruction(context: Context, fidelity: Fidelity): String {
        val template = cached ?: context.assets.open(ASSET)
            .bufferedReader()
            .use { it.readText() }
            .also { cached = it }

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
