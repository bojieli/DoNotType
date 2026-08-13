package app.donottype.core

/**
 * Derives a short list of spellings from the screen, for backends whose only grounding channel is
 * a word list. Port of the macOS `Keyterms`; the two must agree or the platforms measure
 * different things.
 *
 * ## Why this exists, given that the encoder deliberately does no analysis
 *
 * [ContextEncoder] clips, labels and orders text that was literally on screen, and the README
 * names term extraction as the thing this project does not do. That rule was written about a
 * *model* provider, where obeying it is free — a multimodal model can be handed ten thousand
 * characters and told to use them for spelling only.
 *
 * A recogniser has no such channel. Deepgram accepts a list of terms and nothing else, so for
 * those backends the choice is not "raw context versus extracted terms" but "extracted terms
 * versus no grounding at all". It is still the weaker mechanism and it is off by default.
 *
 * ## The rule that is not negotiable
 *
 * **Nothing containing a digit is ever emitted.** Substitution — hearing "Gemini 1.5" and writing
 * the "3.5" that was on screen — is the failure this project exists to prevent, and a keyterm list
 * is blunter than a prompt: there is no "reference only, do not transcribe" clause to attach,
 * because the API has nowhere to put one. Names are safe to bias because a name has one correct
 * spelling regardless of what was said; a number does not.
 */
object Keyterms {

    /**
     * Ordered best-first, so truncating to a provider's cap keeps the most relevant terms.
     *
     * Ordering is by proximity to the caret rather than by frequency: what someone is about to
     * dictate into predicts what they are about to say far better than what is repeated elsewhere.
     */
    fun derive(context: ScreenContext, maxTerms: Int = 100, maxCharsPerTerm: Int = 50): List<String> {
        if (maxTerms <= 0) return emptyList()

        val sources = listOfNotNull(
            context.selectedText,
            context.textBeforeCaret,
            context.textAfterCaret,
            context.windowTitle,
            context.visibleText,
        )

        val seen = mutableSetOf<String>()
        val terms = mutableListOf<String>()
        for (source in sources) {
            for (candidate in candidates(source)) {
                if (candidate.length > maxCharsPerTerm) continue
                // The endpoint does its own matching, so two casings of one word would spend two
                // of a scarce hundred slots.
                if (!seen.add(candidate.lowercase())) continue
                terms.add(candidate)
                if (terms.size == maxTerms) return terms
            }
        }
        return terms
    }

    /** Words worth biasing, in the order they appear. */
    fun candidates(text: String): List<String> =
        tokenize(text).filter(::isWorthBiasing).map { it.text }

    data class Token(val text: String, val startsSentence: Boolean)

    /**
     * Characters that belong *inside* a term. Everything else ends one.
     *
     * Quotes, brackets and `=` are deliberately absent, which is a fix rather than an omission:
     * splitting on whitespace alone produced `koffi.load('libContextHelper.dylib` and
     * `--author="Li`, terms carrying an unmatched bracket that bias toward a string appearing
     * nowhere.
     */
    private const val WORD_PUNCTUATION = "-_./'#@+"

    /**
     * Splits into candidate terms, breaking on whitespace, punctuation **and script boundaries**.
     *
     * The script boundary is the important one, and its absence made this feature useless for a
     * bilingual user. Chinese is written without spaces, so a whitespace split turned
     * `搞成一个retrieval pipeline，然后用Kubernetes部署` into tokens like `搞成一个retrieval`, and
     * every genuinely hard word was either glued to Han characters and rejected or emitted as a
     * mixed-script blob. In code-switched technical speech the hard words are the Latin ones.
     */
    fun tokenize(text: String): List<Token> {
        val tokens = mutableListOf<Token>()
        var sentenceIsOpen = false
        val current = StringBuilder()

        fun flush(endsSentence: Boolean = false) {
            val word = trim(current.toString())
            current.setLength(0)
            if (word.isNotEmpty()) {
                tokens.add(Token(word, !sentenceIsOpen))
                sentenceIsOpen = true
            }
            if (endsSentence) sentenceIsOpen = false
        }

        for ((index, character) in text.withIndex()) {
            when {
                // A Han or kana character ends the Latin run beside it and is never itself a
                // candidate: judging a Chinese term needs segmentation, which this does not do.
                character.isCJKScript() -> flush()

                // A full stop is interior to `README.md` and terminal after `tokens.`; only a
                // look-ahead separates them, and treating every dot as word-internal loses
                // sentence boundaries entirely.
                character == '.' -> {
                    val next = text.getOrNull(index + 1) ?: ' '
                    if (next.isLetterOrDigit()) current.append(character) else flush(true)
                }

                character.isLetterOrDigit() || WORD_PUNCTUATION.contains(character) ->
                    current.append(character)

                else -> flush("!?。！？".contains(character))
            }
        }
        flush()
        return tokens
    }

    /**
     * Removes punctuation that survived the split but is not part of the word. One-sided on
     * purpose: `--force` and `.gitignore` lead with punctuation that is part of the token.
     */
    private fun trim(raw: String): String {
        var word = raw
        while (word.isNotEmpty() && WORD_PUNCTUATION.contains(word.last())) {
            // Keep a trailing dot only when an interior dot justifies it.
            if (word.last() == '.' && word.dropLast(1).contains('.')) break
            word = word.dropLast(1)
        }
        while (word.isNotEmpty() && "'#@+_".contains(word.first())) word = word.substring(1)
        return word
    }

    /**
     * Common words that survive the shape tests and should not spend a keyterm slot.
     *
     * Deliberately tiny, and acronyms are deliberately absent: `HTTP`, `URL` and their kind look
     * like chrome but are exactly the tokens a recogniser mishears.
     */
    val IGNORED = setOf(
        "the", "and", "but", "for", "with", "from", "this", "that", "new", "open", "save",
        "file", "edit", "view", "help", "window", "untitled", "document", "menu", "search",
    )

    fun isWorthBiasing(token: Token): Boolean {
        val word = token.text
        if (word.length < 3) return false
        if (IGNORED.contains(word.lowercase())) return false
        // Contractions reached the list as "capital mid-sentence, therefore a proper noun".
        // `O'Brien` must survive, so the test is on the suffix: short and lower case.
        if (isContraction(word)) return false
        // The rule from this object's documentation.
        if (word.any(Char::isDigit)) return false
        if (word.none(Char::isLetter)) return false

        val letters = word.filter(Char::isLetter)
        // ACRONYM
        if (letters.length >= 2 && letters.all(Char::isUpperCase)) return true
        // camelCase / PascalCase — an interior capital is a spelling a recogniser will not guess.
        if (word.drop(1).any(Char::isUpperCase)) return true
        // kebab-case, snake_case, dotted or pathlike identifiers.
        if (isJoinedIdentifier(word)) return true
        // A command-line flag. `--no-edit` qualified as a joined identifier while `--author` did
        // not, an arbitrary distinction to someone who dictates both.
        val flagBody = word.dropWhile { it == '-' }
        if (word.startsWith("-") && flagBody.length >= 2 &&
            flagBody.all { it.isLetter() || it == '-' }
        ) {
            return true
        }
        // A capital mid-sentence is a proper noun; at the start of one it is only grammar.
        if (!token.startsSentence && word.first().isUpperCase()) return true

        return false
    }

    fun isContraction(word: String): Boolean {
        val index = word.indexOfFirst { it == '\'' || it == '\u2019' }
        if (index < 0) return false
        val suffix = word.substring(index + 1)
        return suffix.isNotEmpty() && suffix.length <= 3 &&
            suffix.all { it.isLowerCase() && it.isLetter() }
    }

    private fun isJoinedIdentifier(word: String): Boolean {
        val joiners = setOf('-', '_', '.', '/', ':')
        var sawLetterBefore = false
        for ((index, character) in word.withIndex()) {
            if (joiners.contains(character)) {
                val next = word.getOrNull(index + 1)
                if (sawLetterBefore && next != null && next.isLetter()) return true
            } else if (character.isLetter()) {
                sawLetterBefore = true
            }
        }
        return false
    }
}

/**
 * CJK ideographs and the kana blocks — scripts written without spaces.
 *
 * Used as a word boundary rather than as a candidate: a Chinese term cannot be identified without
 * segmentation, and biasing toward a whole unsegmented clause is worse than sending nothing.
 */
fun Char.isCJKScript(): Boolean = code.let { c ->
    c in 0x3040..0x30FF || c in 0x3400..0x4DBF || c in 0x4E00..0x9FFF ||
        c in 0xF900..0xFAFF || c in 0xFF00..0xFF65
}
