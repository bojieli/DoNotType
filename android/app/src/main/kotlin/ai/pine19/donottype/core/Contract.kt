package ai.pine19.donottype.core

/**
 * How much cleanup the transcript may receive.
 *
 * Even [TIDY] may only change typography, never words. Kept identical to the Swift enum and to the
 * clauses in PROMPT.md — the whole point of a versioned contract is that the platforms agree.
 */
enum class Fidelity(val id: String) {
    RAW("raw"),
    LIGHT("light"),
    TIDY("tidy");

    companion object {
        val DEFAULT = LIGHT
        fun from(id: String?): Fidelity = entries.firstOrNull { it.id == id } ?: DEFAULT
    }
}

/**
 * Everything captured from the screen for one dictation.
 *
 * On Android this is filled by an AccessibilityService rather than AXUIElement, but the fields and
 * the budgets are deliberately the same as macOS so a context block is byte-comparable across
 * platforms during debugging.
 */
data class ScreenContext(
    val appName: String? = null,
    val windowTitle: String? = null,
    val browserUrl: String? = null,
    val role: String? = null,
    val isEditable: Boolean? = null,
    val visibleText: String? = null,
    val textBeforeCaret: String? = null,
    val textAfterCaret: String? = null,
    val selectedText: String? = null,
    val screenshotPng: ByteArray? = null,
) {
    val isEmpty: Boolean
        get() = screenshotPng == null &&
            listOf(
                appName, windowTitle, browserUrl, visibleText,
                textBeforeCaret, textAfterCaret, selectedText,
            ).all { it.isNullOrBlank() }

    /** Too little text to rely on, so the screenshot path should fire. */
    fun isAccessibilityThin(threshold: Int = 300): Boolean =
        (visibleText?.trim()?.length ?: 0) +
            (textBeforeCaret?.trim()?.length ?: 0) +
            (textAfterCaret?.trim()?.length ?: 0) < threshold

    // Generated equals/hashCode would compare the ByteArray by reference; not worth the noise
    // since nothing here relies on structural equality of the screenshot.
    override fun equals(other: Any?): Boolean = this === other
    override fun hashCode(): Int = System.identityHashCode(this)
}

/**
 * Token estimation and truncation, ported from the Swift core so both platforms cut buffers at the
 * same place.
 *
 * The direction is the point: screen text is clipped keeping the **tail**, because the end of a
 * buffer is the part nearest the caret.
 */
object TokenBudget {
    fun estimate(text: String): Int {
        if (text.isEmpty()) return 0
        val length = text.length
        val han = text.count { it.code in 0x4E00..0x9FFF }
        if (han.toDouble() / length > 0.3) {
            return Math.ceil(length / 1.3).toInt()
        }
        val words = text.split(Regex("\\s+")).count { it.isNotEmpty() }
        return Math.ceil(maxOf(words * 1.3, length / 4.0)).toInt()
    }

    fun clipKeepingTail(text: String, maxChars: Int): String = when {
        maxChars <= 0 -> ""
        text.length <= maxChars -> text
        else -> text.substring(text.length - maxChars)
    }

    fun clipKeepingHead(text: String, maxChars: Int): String = when {
        maxChars <= 0 -> ""
        text.length <= maxChars -> text
        else -> text.substring(0, maxChars)
    }
}

/** One entry in the request's input list. */
sealed interface InputPart {
    data class Text(val text: String) : InputPart
    data class Image(val data: ByteArray, val mimeType: String) : InputPart
    data class Audio(val data: ByteArray, val mimeType: String) : InputPart
}

/**
 * Turns a [ScreenContext] into request parts, verbatim.
 *
 * Does no analysis: no term extraction, no ranking, no summarising. See CONTEXT_FORMAT.md.
 */
class ContextEncoder(
    private val visibleTextChars: Int = 10_000,
    private val beforeCaretChars: Int = 1_000,
    private val afterCaretChars: Int = 1_000,
    private val thinTextThreshold: Int = 300,
) {
    companion object {
        const val HEADER = "===== SCREEN CONTEXT — REFERENCE ONLY, DO NOT TRANSCRIBE ====="
        /**
         * Restates the content rule immediately before the audio, where the system instruction is
         * thousands of tokens away.
         *
         * Deliberately abstract. An earlier version illustrated the rule with the same version
         * numbers as the test case and made substitution *worse* (11/19 -> 15/18): naming the
         * wrong answer in the instruction appears to prime it. Examples here must never contain a
         * concrete value that could be echoed.
         *
         * Must stay byte-identical to the other ports -- see `eval/conformance/`.
         */
        val FOOTER = """
            ===== END SCREEN CONTEXT =====
            None of the text above was spoken. It is a spelling reference only.
            Numbers, version numbers, dates and names in your output must come from the audio alone,
            even when the text above shows a different value for the same thing.
            The audio that follows is the ONLY thing to transcribe.
        """.trimIndent()
    }

    fun encode(context: ScreenContext): List<InputPart> {
        if (context.isEmpty) return emptyList()

        val parts = mutableListOf<InputPart>()
        parts += InputPart.Text((listOf(HEADER) + identityLines(context)).joinToString("\n"))

        context.screenshotPng?.let { parts += InputPart.Image(it, "image/png") }

        val sections = mutableListOf<String>()
        val thin = (context.visibleText?.trim()?.length ?: 0) < thinTextThreshold
        if (context.screenshotPng != null || !thin) {
            section(sections, "VISIBLE TEXT (accessibility)",
                TokenBudget.clipKeepingTail(context.visibleText.orEmpty(), visibleTextChars))
        }
        section(sections, "TEXT BEFORE CARET",
            TokenBudget.clipKeepingTail(context.textBeforeCaret.orEmpty(), beforeCaretChars))
        section(sections, "TEXT AFTER CARET",
            TokenBudget.clipKeepingHead(context.textAfterCaret.orEmpty(), afterCaretChars))
        section(sections, "SELECTED TEXT", context.selectedText.orEmpty())

        sections += FOOTER
        parts += InputPart.Text(sections.joinToString("\n\n"))
        return parts
    }

    fun estimatedTokens(context: ScreenContext): Int = encode(context).sumOf { part ->
        when (part) {
            is InputPart.Text -> TokenBudget.estimate(part.text)
            is InputPart.Image -> 1_300
            is InputPart.Audio -> 0
        }
    }

    private fun identityLines(context: ScreenContext): List<String> = buildList {
        val app = context.appName?.trim().orEmpty()
        val title = context.windowTitle?.trim().orEmpty()
        when {
            app.isNotEmpty() && title.isNotEmpty() -> add("App: $app — $title")
            app.isNotEmpty() -> add("App: $app")
            title.isNotEmpty() -> add("Window: $title")
        }
        context.browserUrl?.trim()?.takeIf { it.isNotEmpty() }?.let { add("URL: $it") }
        context.role?.trim()?.takeIf { it.isNotEmpty() }?.let {
            add("Field: $it" + if (context.isEditable == true) " · editable" else "")
        }
    }

    /** Empty sections are omitted: a bare header costs tokens and invites the model to fill it. */
    private fun section(into: MutableList<String>, title: String, body: String) {
        val trimmed = body.trim()
        if (trimmed.isNotEmpty()) into += "--- $title ---\n$trimmed"
    }
}
