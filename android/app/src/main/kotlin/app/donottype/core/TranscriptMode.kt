package app.donottype.core

/**
 * An optional rewrite applied to a finished transcript.
 *
 * `VERBATIM` is not a style — it is the absence of one, and the default. The others exist because
 * people do sometimes want formal prose; what makes this different from the tool this project
 * replaces is that the raw transcript is always produced first, always stored, and always
 * recoverable.
 */
enum class RewriteStyle(val id: String, val label: String) {
    VERBATIM("verbatim", "Verbatim — exactly what you said"),
    FORMAL("formal", "Formal — professional prose"),
    CONCISE("concise", "Concise — same voice, fewer words"),
    BULLETS("bullets", "Bullets — one idea per line"),
    ;

    val isRewrite: Boolean get() = this != VERBATIM

    /** Key under `### style: <name>` in PROMPT.md. */
    val promptSection: String get() = "style: $id"

    companion object {
        fun from(id: String?): RewriteStyle? = entries.firstOrNull { it.id == id }
    }
}

/**
 * The shape of a summary.
 *
 * Summarising is the one thing this codebase does that is *supposed* to lose content, which is why
 * it is not a [RewriteStyle]. Rule 1 of the rewrite block — never remove a fact — is the rule this
 * project exists to enforce, and a summary style living alongside `formal` and `concise` would mean
 * one entry in that list quietly exempt from it. It gets its own prompt block, its own instruction
 * and its own place in the type system so no caller can reach it by accident.
 */
enum class SummaryStyle(val id: String, val label: String) {
    BRIEF("brief", "Brief — a short paragraph"),
    BULLETS("bullets", "Bullets — the key points"),
    ACTIONS("actions", "Actions — decisions and next steps"),
    ;

    /** Key under `### summary: <name>` in PROMPT.md. */
    val promptSection: String get() = "summary: $id"

    companion object {
        val DEFAULT = BRIEF
        fun from(id: String?): SummaryStyle? = entries.firstOrNull { it.id == id }
    }
}

/**
 * What the user gets back, once the transcript exists.
 *
 * The ordering matters and is the project's whole position in one type. Transcription happens first
 * and produces the verbatim text; everything else is a *second* stage over text that has already
 * been stored. There is deliberately no mode that transcribes and summarises in one request,
 * because such a request has no verbatim output to keep — and "what did I actually say" stops being
 * answerable the moment one exists.
 */
sealed class TranscriptMode {
    object Verbatim : TranscriptMode()
    data class Rewrite(val style: RewriteStyle) : TranscriptMode()
    data class Summary(val style: SummaryStyle) : TranscriptMode()

    /** `verbatim`, `rewrite:formal`, `summary:actions` — what a history row records. */
    val id: String
        get() = when (this) {
            is Verbatim -> "verbatim"
            is Rewrite -> "rewrite:${style.id}"
            is Summary -> "summary:${style.id}"
        }

    val label: String
        get() = when (this) {
            is Verbatim -> "Verbatim — word for word"
            is Rewrite -> "Rewrite — ${style.label}"
            is Summary -> "Summary — ${style.label}"
        }

    /**
     * Whether a second, text-only request is needed. False only for verbatim.
     *
     * This is also the question "can a speech recognition backend do this?" — a recogniser has no
     * text input at all, so anything true here needs a language model somewhere in the chain.
     */
    val needsSecondPass: Boolean get() = this !is Verbatim

    /**
     * The rewrite style this mode applied, for the history column that already exists. Null for
     * verbatim and for summaries, which are not a rewrite style and must not be recorded as one.
     */
    val rewriteStyle: RewriteStyle? get() = (this as? Rewrite)?.style

    companion object {
        val DEFAULT: TranscriptMode = Verbatim

        /** Every mode a picker should offer, with the styles expanded. */
        val ALL: List<TranscriptMode> = buildList {
            add(Verbatim)
            RewriteStyle.entries.filter { it.isRewrite }.forEach { add(Rewrite(it)) }
            SummaryStyle.entries.forEach { add(Summary(it)) }
        }

        /**
         * Parses the stored or typed spelling. A bare `rewrite` or `summary` takes that stage's
         * default, so it is a complete instruction rather than an error.
         */
        fun from(id: String?): TranscriptMode? {
            val parts = id?.trim()?.lowercase()?.split(":", limit = 2) ?: return null
            val head = parts.firstOrNull() ?: return null
            val tail = parts.getOrNull(1)
            return when (head) {
                "verbatim", "raw", "transcribe", "none" -> Verbatim
                "rewrite" -> {
                    if (tail == null) return Rewrite(RewriteStyle.FORMAL)
                    RewriteStyle.from(tail)?.takeIf { it.isRewrite }?.let { Rewrite(it) }
                }
                "summary", "summarise", "summarize" -> {
                    if (tail == null) return Summary(SummaryStyle.DEFAULT)
                    SummaryStyle.from(tail)?.let { Summary(it) }
                }
                else -> null
            }
        }
    }
}
