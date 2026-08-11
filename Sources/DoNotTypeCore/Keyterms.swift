import Foundation

/// Derives a short list of spellings from the screen, for backends whose only grounding channel
/// is a word list.
///
/// ## Why this exists at all, given `ContextEncoder`'s first paragraph
///
/// `ContextEncoder` says, correctly, that it does no analysis: it clips, labels and orders text
/// that was literally on screen, and the README calls term extraction out by name as the thing
/// this project does not do. That rule was written about a *model* provider, where it costs
/// nothing to obey — a multimodal model can be handed ten thousand characters of raw screen and
/// asked to use them for spelling only.
///
/// A speech recognition endpoint has no such channel. Deepgram and xAI accept a list of terms and
/// nothing else. So for those backends the choice is not "raw context versus extracted terms", it
/// is "extracted terms versus no grounding at all", and pretending otherwise would just mean
/// shipping a provider that silently ignores the screen.
///
/// It is still the weaker mechanism, and it is **off by default** — see `Settings.keytermBiasing`
/// and `docs/EVALUATION.md` for what it measures. What follows is the containment.
///
/// ## The one rule that is not negotiable
///
/// **Nothing containing a digit is ever emitted.** Substitution — hearing "Gemini 1.5" and
/// writing the "3.5" that was on screen — is the failure this project exists to prevent, and a
/// keyterm list is a far blunter instrument than a prompt: there is no "reference only, do not
/// transcribe" clause to attach to it, because the API has nowhere to put one. A biasing list
/// containing `3.5` is a request for exactly the bug. Names are safe to bias because a name has
/// one correct spelling regardless of what was said; a number does not.
public enum Keyterms {
    /// Ordered best-first, so truncating to a provider's cap keeps the most relevant terms.
    ///
    /// Ordering is by proximity to the caret rather than by frequency. What someone is about to
    /// dictate into is a much better predictor of the words they are about to say than what
    /// happens to be repeated elsewhere in a long document.
    public static func derive(
        from context: ScreenContext, maxTerms: Int = 100, maxCharsPerTerm: Int = 50
    ) -> [String] {
        guard maxTerms > 0 else { return [] }

        // Nearest the caret first: selection, then the text bracketing it, then window identity,
        // then the rest of the window.
        let sources = [
            context.selectedText,
            context.textBeforeCaret,
            context.textAfterCaret,
            context.windowTitle,
            context.visibleText,
        ]

        var seen: Set<String> = []
        var terms: [String] = []
        for source in sources.compactMap({ $0 }) {
            for candidate in candidates(in: source) {
                guard candidate.count <= maxCharsPerTerm else { continue }
                // Case-insensitive dedupe: the endpoint does its own matching, so `Kaelith` and
                // `kaelith` would spend two of a scarce hundred slots on one word.
                guard seen.insert(candidate.lowercased()).inserted else { continue }
                terms.append(candidate)
                if terms.count == maxTerms { return terms }
            }
        }
        return terms
    }

    // MARK: - Private

    /// Words worth biasing, in the order they appear.
    static func candidates(in text: String) -> [String] {
        var results: [String] = []
        for token in tokenize(text) where isWorthBiasing(token) {
            results.append(token.text)
        }
        return results
    }

    struct Token {
        var text: String
        /// Whether this token opened a sentence, where a capital letter means nothing.
        var startsSentence: Bool
    }

    /// Splits on whitespace, then trims the punctuation that ordinary prose wraps words in.
    ///
    /// Trimming is one-sided-aware on purpose: `--force` and `.gitignore` lead with punctuation
    /// that is part of the token, so only characters that are *never* word-initial come off the
    /// front.
    static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var sentenceIsOpen = false

        for raw in text.split(whereSeparator: { $0.isWhitespace }) {
            let leading = CharacterSet(charactersIn: "\"'“”‘’([{<*_~`")
            let trailing = CharacterSet(charactersIn: "\"'“”‘’)]}>,;:!?*_~`")
            var word = String(raw)
            while let first = word.unicodeScalars.first, leading.contains(first) {
                word.removeFirst()
            }
            while let last = word.unicodeScalars.last, trailing.contains(last) {
                word.removeLast()
            }
            // A trailing full stop is ambiguous — sentence end, or part of `README.md`. Strip it
            // only when what remains has no interior dot to justify keeping it.
            if word.hasSuffix("."), !word.dropLast().contains(".") {
                word.removeLast()
            }

            let endsSentence = raw.hasSuffix(".") || raw.hasSuffix("!") || raw.hasSuffix("?")
            if !word.isEmpty {
                tokens.append(Token(text: word, startsSentence: !sentenceIsOpen))
                sentenceIsOpen = !endsSentence
            }
        }
        return tokens
    }

    /// Common words that survive the shape tests below and should not spend a keyterm slot.
    ///
    /// Deliberately tiny. This is not a stopword list standing in for a language model; it is the
    /// handful of all-caps and title-case words that appear in almost every window title and menu
    /// bar, where biasing toward them is pure noise.
    static let ignored: Set<String> = [
        "i", "a", "ok", "okay", "the", "and", "or", "but", "if", "to", "of", "in", "on", "at",
        "it", "is", "as", "an", "am", "pm", "url", "id", "ui", "os", "no", "yes", "new", "open",
        "save", "file", "edit", "view", "help", "window", "untitled", "http", "https", "www",
        "com", "org", "net", "true", "false", "null", "nil", "todo", "note", "warning", "error",
    ]

    static func isWorthBiasing(_ token: Token) -> Bool {
        let word = token.text
        // Two characters is below the length at which biasing means anything, and the endpoints
        // charge a scarce slot for it either way.
        guard word.count >= 3 else { return false }
        guard !ignored.contains(word.lowercased()) else { return false }

        // The rule from this type's doc comment. Anything carrying a digit — a version, a port, a
        // date, a quantity — is exactly what must come from the audio alone.
        guard !word.contains(where: \.isNumber) else { return false }

        // Needs at least one letter; pure punctuation is not a word.
        guard word.contains(where: \.isLetter) else { return false }

        let scalars = Array(word)
        let letters = scalars.filter(\.isLetter)

        // ACRONYM. Two or more letters, all upper case.
        if letters.count >= 2, letters.allSatisfy({ $0.isUppercase }) { return true }

        // camelCase / PascalCase — an interior capital is a spelling a recogniser will not guess.
        if scalars.dropFirst().contains(where: \.isUppercase) { return true }

        // Identifiers joined by punctuation: kebab-case, snake_case, dotted, or pathlike. Requires
        // letters on both sides so a hyphenated line break does not qualify.
        if isJoinedIdentifier(word) { return true }

        // A capital mid-sentence is a proper noun. At the start of a sentence it is just grammar,
        // and biasing toward every sentence-opening word would flood the list.
        if !token.startsSentence, scalars.first?.isUppercase == true { return true }

        return false
    }

    private static func isJoinedIdentifier(_ word: String) -> Bool {
        let joiners: Set<Character> = ["-", "_", ".", "/", ":"]
        var sawLetterBefore = false
        var index = word.startIndex
        while index < word.endIndex {
            let character = word[index]
            if joiners.contains(character) {
                let next = word.index(after: index)
                if sawLetterBefore, next < word.endIndex, word[next].isLetter { return true }
            } else if character.isLetter {
                sawLetterBefore = true
            }
            index = word.index(after: index)
        }
        return false
    }
}
