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

    /// Characters that belong *inside* a term. Everything else ends one.
    ///
    /// Quotes, brackets and `=` are deliberately absent, which is a fix rather than an omission.
    /// Splitting on whitespace alone produced `koffi.load('libContextHelper.dylib` and
    /// `--author="Li` — terms containing an unmatched bracket, biasing toward a string that
    /// appears nowhere. Treating those characters as boundaries yields `koffi.load`,
    /// `libContextHelper.dylib` and `--author` instead, which are the terms actually wanted.
    private static let wordPunctuation: Set<Character> = ["-", "_", ".", "/", "'", "#", "@", "+"]

    /// Splits into candidate terms, breaking on whitespace, punctuation **and script boundaries**.
    ///
    /// The script boundary is the important one, and its absence made this whole feature useless
    /// for a bilingual user. Chinese is written without spaces, so a whitespace split turned
    /// `搞成一个retrieval pipeline，然后用Kubernetes部署` into two tokens — one of which was
    /// `搞成一个retrieval` — and every genuinely hard word in it (`Kubernetes`, `retrieval`,
    /// `quillmark-sync`) was either glued to Han characters and rejected, or emitted as a
    /// mixed-script blob that would bias toward nonsense.
    ///
    /// In code-switched technical speech the hard words are almost always the Latin ones. Treating
    /// every CJK character as a boundary extracts exactly those and discards the rest.
    static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var sentenceIsOpen = false
        var current = ""

        func flush(endsSentence: Bool = false) {
            defer { if endsSentence { sentenceIsOpen = false } }
            let word = trim(current)
            current = ""
            guard !word.isEmpty else { return }
            tokens.append(Token(text: word, startsSentence: !sentenceIsOpen))
            sentenceIsOpen = true
        }

        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            if character.isCJKScript {
                // A Han or kana character ends the Latin run beside it and is never itself a
                // candidate: judging a Chinese term needs word segmentation, which this type
                // deliberately does not do. See the note on `derive`.
                flush()
            } else if character == "." {
                // A full stop is the one ambiguous character here: interior to `README.md` and
                // `koffi.load`, terminal in "…per million tokens." Only a look-ahead can tell
                // them apart, and getting it wrong is not cosmetic — treating every dot as
                // word-internal loses sentence boundaries entirely, which put `Compare` and `See`
                // into the list as though they were proper nouns.
                let next = index + 1 < characters.count ? characters[index + 1] : " "
                if next.isLetter || next.isNumber {
                    current.append(character)
                } else {
                    flush(endsSentence: true)
                }
            } else if character.isLetter || character.isNumber
                || wordPunctuation.contains(character)
            {
                current.append(character)
            } else {
                flush(endsSentence: "!?。！？".contains(character))
            }
        }
        flush()
        return tokens
    }

    /// Removes punctuation that survived the split but is not part of the word.
    ///
    /// One-sided on purpose: `--force` and `.gitignore` lead with punctuation that *is* part of
    /// the token, so only characters that are never word-initial come off the front.
    private static func trim(_ raw: String) -> String {
        var word = raw
        while let last = word.last, "-_./'#@+".contains(last) {
            // A trailing dot is ambiguous — sentence end, or part of `README.md`. Keep it only
            // when an interior dot justifies it.
            if last == ".", word.dropLast().contains(".") { break }
            word.removeLast()
        }
        while let first = word.first, "'#@+_".contains(first) {
            word.removeFirst()
        }
        return word
    }

    /// Common words that survive the shape tests below and should not spend a keyterm slot.
    ///
    /// Deliberately tiny. This is not a stopword list standing in for a language model; it is the
    /// handful of title-case words that appear in almost every window title and menu bar, where
    /// biasing toward them is pure noise.
    ///
    /// Acronyms are deliberately absent. `HTTP`, `URL`, `OS` and their kind look like chrome but
    /// are exactly the tokens a recogniser mishears, and a user dictating about an HTTP handler
    /// wants that spelling. The cost of a wasted slot is far below the cost of a wrong word.
    static let ignored: Set<String> = [
        "the", "and", "but", "for", "with", "from", "this", "that", "new", "open", "save",
        "file", "edit", "view", "help", "window", "untitled", "document", "menu", "search",
    ]

    static func isWorthBiasing(_ token: Token) -> Bool {
        let word = token.text
        // Two characters is below the length at which biasing means anything, and the endpoints
        // charge a scarce slot for it either way.
        guard word.count >= 3 else { return false }
        guard !ignored.contains(word.lowercased()) else { return false }
        // Contractions. `I'll` and `we're` were reaching the list as "capital mid-sentence, so a
        // proper noun" and spending slots on grammar. `O'Brien` and `d'Angelo` must survive, so
        // the test is on the suffix: short and lower case means a contraction, not a name.
        guard !isContraction(word) else { return false }

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

        // A command-line flag. `--no-edit` already qualified as a joined identifier while
        // `--author` did not, which is an arbitrary distinction to someone who dictates both.
        let flagBody = word.drop(while: { $0 == "-" })
        if word.hasPrefix("-"), flagBody.count >= 2,
            flagBody.allSatisfy({ $0.isLetter || $0 == "-" })
        {
            return true
        }

        // A capital mid-sentence is a proper noun. At the start of a sentence it is just grammar,
        // and biasing toward every sentence-opening word would flood the list.
        if !token.startsSentence, scalars.first?.isUppercase == true { return true }

        return false
    }

    static func isContraction(_ word: String) -> Bool {
        guard let apostrophe = word.firstIndex(where: { $0 == "'" || $0 == "\u{2019}" }) else {
            return false
        }
        let suffix = word[word.index(after: apostrophe)...]
        return !suffix.isEmpty && suffix.count <= 3
            && suffix.allSatisfy { $0.isLowercase && $0.isLetter }
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

extension Character {
    /// CJK ideographs and the kana blocks — scripts written without spaces.
    ///
    /// Used as a word boundary rather than as a candidate: a Chinese term cannot be identified
    /// without segmentation, and biasing toward a whole unsegmented clause is worse than sending
    /// nothing. See `Keyterms.tokenize`.
    var isCJKScript: Bool {
        unicodeScalars.contains { scalar in
            (0x3040...0x30FF).contains(scalar.value)        // hiragana, katakana
                || (0x3400...0x4DBF).contains(scalar.value)  // CJK extension A
                || (0x4E00...0x9FFF).contains(scalar.value)  // CJK unified ideographs
                || (0xF900...0xFAFF).contains(scalar.value)  // compatibility ideographs
                || (0xFF00...0xFF65).contains(scalar.value)  // full-width forms
        }
    }
}
