package app.donottype

import app.donottype.core.Fidelity
import app.donottype.core.TranscriptMode
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
    private const val REWRITE_BEGIN = "<!-- BEGIN REWRITE -->"
    private const val REWRITE_END = "<!-- END REWRITE -->"
    private const val STYLE_PLACEHOLDER = "{{STYLE_RULE}}"
    private const val SUMMARY_BEGIN = "<!-- BEGIN SUMMARY -->"
    private const val SUMMARY_END = "<!-- END SUMMARY -->"
    private const val SUMMARY_PLACEHOLDER = "{{SUMMARY_RULE}}"

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

    /**
     * The instruction for whichever second stage a mode asks for, or null when it asks for none.
     *
     * One entry point, so a caller cannot route a summary through the rewrite block by picking the
     * wrong method — which is the mistake the two-block split in PROMPT.md exists to make
     * impossible. A rewrite may never drop a fact; a summary exists to.
     */
    fun secondStageInstruction(context: Context, mode: TranscriptMode): String? {
        val template = cached ?: activeTemplate(context).also { cached = it }
        return when (mode) {
            is TranscriptMode.Verbatim -> null
            is TranscriptMode.Rewrite ->
                block(template, REWRITE_BEGIN, REWRITE_END, "rewrite")
                    .replace(STYLE_PLACEHOLDER, namedClause(template, mode.style.promptSection))
            is TranscriptMode.Summary ->
                block(template, SUMMARY_BEGIN, SUMMARY_END, "summary")
                    .replace(SUMMARY_PLACEHOLDER, namedClause(template, mode.style.promptSection))
        }
    }

    /** Whether the prompt in force can run a mode's second stage at all. */
    fun supportsSecondStage(context: Context, mode: TranscriptMode): Boolean =
        runCatching { secondStageInstruction(context, mode) }.isSuccess

    private fun block(template: String, begin: String, end: String, name: String): String {
        val start = template.indexOf(begin)
        val finish = template.indexOf(end)
        require(start >= 0 && finish > start) {
            "This prompt has no $name block. A prompt edited before summaries existed will not " +
                "have one — restore the shipped prompt, or copy that block across from it."
        }
        return template.substring(start + begin.length, finish).trim()
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
    private fun clause(template: String, fidelity: Fidelity): String =
        namedClause(template, fidelity.id)

    /** The same, for any `### <name>` heading — `style: formal`, `summary: actions`. */
    private fun namedClause(template: String, name: String): String {
        val heading = "### $name"
        val start = template.indexOf(heading)
        require(start >= 0) { "PROMPT.md has no section $heading" }

        val open = template.indexOf("```", start)
        val close = template.indexOf("```", open + 3)
        require(open >= 0 && close > open) { "no fenced clause under $heading" }

        return template.substring(open + 3, close).trim().replace("\n", " ")
    }
}
