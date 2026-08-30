package app.donottype.core

/**
 * Whether what somebody typed into a Model field could be a model ID at all.
 *
 * The field is free text because model IDs are not ours to enumerate: providers add models faster
 * than releases ship, and a picker would be a list that is wrong by the end of the month. The price
 * of that is a box which accepts anything — including a sentence typed into a window that merely
 * happened to have it focused. Nothing notices until the end of the next dictation, where it
 * surfaces as a 404 that reads exactly like a bad key.
 *
 * So this checks shape and never existence. No client can know which model IDs a given account can
 * reach, and guessing would be worse than useless the week a provider ships something new; every
 * client can know that a model ID has no spaces in it and no CJK. Whatever passes is sent to the
 * provider, which stays the authority on whether the model is real.
 *
 * Mirrored word for word from `Sources/DoNotTypeCore/ModelIdentifier.swift`, alongside
 * `windows/DoNotType.Core/ModelIdentifier.cs`, with the tests duplicated in each language for the
 * reason given in `FailureAdviceTest` — the same mistake should read the same way on all four
 * clients.
 */
object ModelIdentifier {

    /**
     * Comfortably past the longest thing anyone routes through here — an OpenRouter path with a
     * variant suffix runs to about sixty — and short enough that a pasted paragraph is caught as
     * one rather than stored as a model ID.
     */
    const val MAX_LENGTH = 200

    /**
     * The punctuation real model IDs are built from: `google/gemini-3.6-flash`,
     * `voxtral-mini-latest`, `qwen2.5:7b-instruct-q4_K_M`, `ft:gpt-4o:acme:tone:1`.
     */
    private const val ALLOWED_PUNCTUATION = "._-:/+@"

    fun isValid(value: String?): Boolean = validationMessage(value) == null

    /**
     * The sentence to put under the field, or null when there is nothing wrong with what is in it.
     *
     * Empty is not an error. Every client reads an empty field as "this backend's default", so
     * clearing the box is how a user asks for that, not a mistake to report.
     */
    fun validationMessage(value: String?): String? {
        val trimmed = value.orEmpty().trim()
        if (trimmed.isEmpty()) return null
        if (trimmed.length > MAX_LENGTH) {
            return "A model ID is at most $MAX_LENGTH characters. This looks like something " +
                "other than a model ID ended up in the field."
        }

        // One pass, then the message is chosen by what was found. A dictated English sentence and
        // a line of CJK are both wrong here, but they are wrong in ways that want different
        // sentences, and whichever comes first in the text is the one worth naming.
        val offender = trimmed.firstOrNull { !isAllowed(it) } ?: return null
        if (offender.isWhitespace()) {
            return "A model ID has no spaces in it. Check for a stray space, or for a sentence " +
                "that landed in this field by accident."
        }

        return "\"$offender\" is not a character model IDs are made of. They use letters, " +
            "digits, and . _ - : / + @ — for example gemini-3.6-flash."
    }

    /**
     * ASCII letters and digits only. `Char.isLetter` alone would accept 模 and é, which is the
     * exact case this exists to catch.
     */
    private fun isAllowed(character: Char): Boolean {
        if (character in 'a'..'z' || character in 'A'..'Z' || character in '0'..'9') return true
        return ALLOWED_PUNCTUATION.contains(character)
    }
}
