package app.donottype.core

/**
 * Whether the rewrite stage can run at all, and what to say when it cannot.
 *
 * Every client asked this question separately and got a different answer. macOS never asked and
 * offered the binding regardless; Windows warned but left the control enabled; this client and iOS
 * asked `!provider.isSpeechRecognition || secondStageBackend != null`, which is a question about
 * the *kind* of backend and not about whether one is usable — so a fresh install with no key at all
 * offered a rewrite that could not run. The default provider moving from a recogniser to a model
 * turned that from latent to visible.
 *
 * One rule, hand-ported from the Swift with the strings word-identical. The reason text is the
 * whole point: a control greyed out without saying why is barely better than one that is missing,
 * and a missing one is how this feature came to look absent entirely.
 */
sealed class RewriteAvailability {
    /** The stage can run. */
    data object Available : RewriteAvailability()

    /** No key for the selected backend, so nothing can run — not a rewrite, not a transcript. */
    data object NoKey : RewriteAvailability()

    /**
     * The selected backend turns audio into text and cannot turn text into text, and no other
     * configured backend can either.
     */
    data class BackendCannotRewrite(val kind: ProviderKind) : RewriteAvailability()

    val isAvailable: Boolean get() = this is Available

    /**
     * One sentence saying why not, and what to do about it. Null when the stage can run.
     *
     * Must stay word-identical across the four clients — see docs/PARITY.md. Someone comparing a
     * phone to a laptop is comparing the same product.
     */
    val reason: String?
        get() = when (this) {
            is Available -> null
            is NoKey -> "Add an API key first — without one nothing can run, rewriting included."
            is BackendCannotRewrite ->
                "${kind.plainName} only transcribes audio and cannot rewrite text. Add a key for " +
                    "a backend that can, and rewriting will use it."
        }

    companion object {
        /**
         * Resolves against whatever the client uses to store keys.
         *
         * @param provider the selected backend.
         * @param hasKey whether a usable key exists for a backend. Passed in rather than read here
         *   so the Keychain, DPAPI and SharedPreferences all answer the same question.
         */
        fun resolve(provider: ProviderKind, hasKey: (ProviderKind) -> Boolean): RewriteAvailability {
            // Asked first, and about the selected backend: with no key the dictation itself fails,
            // so a message about rewriting would answer the second question while the first is
            // still wrong.
            if (!hasKey(provider)) return NoKey

            if (provider.supportsTextGeneration) return Available

            // A recogniser with no text endpoint borrows a second stage from another configured
            // backend, which is the behaviour file transcription already had.
            val borrowed = ProviderKind.entries.any { it.supportsTextGeneration && hasKey(it) }
            return if (borrowed) Available else BackendCannotRewrite(provider)
        }
    }
}
