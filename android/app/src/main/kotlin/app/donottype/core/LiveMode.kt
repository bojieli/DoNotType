package app.donottype.core

/**
 * What the keyboard will do with the next dictation.
 *
 * Three values because the second stage has three answers, which the type system has said for a
 * while and the interface did not. The mode chip was a two-state toggle over dictate/rewrite while a
 * target language in Settings quietly overrode both — so the chip had to display a third state it
 * could not offer, and going from one to another meant leaving the field, opening the app, and
 * coming back. These are the same three cases [TranscriptMode] has, named for what the user is
 * choosing rather than for what the pipeline does with it.
 *
 * Only the phones have one. A desktop chooses its mode by *which key it is holding*, so a
 * persistent chip there would be a second answer to a question the keyboard already answers. See
 * `docs/PARITY.md`.
 */
enum class LiveMode(val id: String, val label: String) {
    /** Verbatim. The default, and the product. */
    DICTATE("dictate", "Dictate"),

    /** Verbatim first, then rewritten in the configured style. */
    REWRITE("rewrite", "Rewrite"),

    /** Verbatim first, then written again in the configured language. */
    TRANSLATE("translate", "Translate");

    /**
     * The stage this mode asks for, given the style and language the user has configured.
     *
     * One resolver rather than the same three-branch conditional in four call sites, and it is the
     * place the empty cases are decided: a translation with no language and a rewrite with no style
     * are both just a dictation, because the alternative is a second request that asks a model to do
     * something unspecified to a transcript.
     */
    /**
     * Whether this mode can run right now, and what to say when it cannot.
     *
     * The picker asks before it offers: a mode that is greyed out with a reason beats one that is
     * offered and then silently does something else, which is what the target-language override
     * used to do to the rewrite chip.
     */
    fun availability(
        provider: ProviderKind,
        language: String,
        hasKey: (ProviderKind) -> Boolean,
    ): RewriteAvailability = when (this) {
        // One stage, so there is nothing here that can be missing beyond the key the dictation
        // itself needs, which every client reports where it is actually noticed.
        DICTATE -> RewriteAvailability.Available
        REWRITE -> RewriteAvailability.resolve(provider, SecondStageJob.REWRITING, hasKey)
        TRANSLATE ->
            if (TranslationTarget.sanitized(language).isEmpty()) {
                RewriteAvailability.NoTargetLanguage
            } else {
                RewriteAvailability.resolve(provider, SecondStageJob.TRANSLATING, hasKey)
            }
    }

    fun stage(style: RewriteStyle, language: String): TranscriptMode = when (this) {
        DICTATE -> TranscriptMode.Verbatim
        REWRITE -> if (style.isRewrite) TranscriptMode.Rewrite(style) else TranscriptMode.Verbatim
        TRANSLATE -> {
            val target = TranslationTarget.sanitized(language)
            if (target.isEmpty()) TranscriptMode.Verbatim else TranscriptMode.Translate(target)
        }
    }

    companion object {
        val DEFAULT = DICTATE

        fun from(id: String?): LiveMode =
            entries.firstOrNull { it.id == id?.trim()?.lowercase() } ?: DEFAULT
    }
}
