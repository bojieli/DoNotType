package app.donottype.core

/**
 * The language a dictation is written in when it is not the one that was spoken.
 *
 * Free text, and deliberately so, for the same reason the Model field is: languages are not ours to
 * enumerate. "Traditional Chinese", "Brazilian Portuguese", "plain English for a five-year-old" and
 * "Swiss German" are all things a model can do and none of them is a row in an enum somebody would
 * have thought to add. The check here is about **shape**, never about existence — what passes is
 * still sent to the model, which remains the authority on whether it can write it.
 *
 * Hand-ported from `Sources/DoNotTypeCore/TranslationTarget.swift`; the C# port is
 * `windows/DoNotType.Core/TranslationTarget.cs`.
 */
object TranslationTarget {
    /**
     * Long enough for "Traditional Chinese, in the register of a business email"; short enough that
     * nobody pastes a paragraph into it and wonders why every request got slower.
     */
    const val MAX_CHARACTERS = 60

    /** Empty means off, which is the default and the only value that changes nothing. */
    fun sanitized(text: String?): String {
        if (text.isNullOrEmpty()) return ""
        // One line, because this lands inside a sentence in the instruction. A newline pasted from
        // a language list would break the sentence around it rather than the language it names.
        val collapsed = text
            .replace('\r', ' ')
            .replace('\n', ' ')
            .replace('\t', ' ')
            .split(' ')
            .filter { it.isNotEmpty() }
            .joinToString(" ")
        return if (collapsed.length > MAX_CHARACTERS) {
            collapsed.substring(0, MAX_CHARACTERS).trim()
        } else {
            collapsed
        }
    }

    /**
     * The sentence under the field when what is in it could not be a language, or null when it
     * could.
     *
     * Phrased as what the field takes rather than as a rejection — nothing is lost while it is
     * showing, exactly as with a model ID. Must stay word-identical across the four clients.
     */
    fun validationMessage(text: String?): String? {
        val value = text ?: ""
        // Empty is off, not invalid.
        if (value.trim().isEmpty()) return null
        if (sanitized(value).length > MAX_CHARACTERS || value.length > MAX_CHARACTERS) {
            return "A language name is at most $MAX_CHARACTERS characters."
        }
        return null
    }

    /**
     * One tap for the languages people ask for most, in each language's own name where it has one.
     * Not a whitelist: the field accepts anything, and this list is only a shortcut.
     */
    val SUGGESTIONS: List<String> = listOf(
        "English",
        "简体中文",
        "繁體中文",
        "日本語",
        "한국어",
        "Español",
        "Français",
        "Deutsch",
        "Português",
        "Русский",
        "Italiano",
        "हिन्दी",
        "العربية",
    )
}

/**
 * What the `styled` field of a transcription request is being asked for.
 *
 * One request returns the verbatim transcript and a second version of it side by side, which is
 * what makes a rewrite cost no extra round trip while leaving "what did I actually say" answerable.
 * There are two things worth asking for in that field, and they are not the same job — a rewrite
 * keeps the speaker's language and may reshape the prose; a translation changes the language and
 * may reshape nothing — so the request says which, rather than the call site passing a clause and
 * hoping the sentence around it happens to fit.
 *
 * A sealed class rather than two nullable parameters, because only one of them may ever be set: two
 * nullables would make "both at once" a state somebody has to remember not to construct.
 */
sealed class StyledRequest {
    /** The transcript rewritten in a style, carrying the clause text from `prompt/style/`. */
    data class Style(val clause: String) : StyledRequest()

    /** The transcript written again in another language, named by the user. */
    data class Translation(val language: String) : StyledRequest()
}
