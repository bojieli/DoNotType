import Foundation

/// A small, explicit spelling reference supplied by the user.
///
/// Entries come either directly from the user or from a spelling correction the user has opted in
/// to teach. Nothing is inferred from screen text, past transcripts, insertions, deletions or
/// ordinary rewriting. The list is bounded to the smallest provider ceiling and entries are kept
/// in user order: when a speech endpoint accepts only keyterms, the user's deliberate choices take
/// precedence over any optional terms derived from the screen.
public enum PersonalDictionary {
    public static let maxTerms = 100
    public static let maxCharactersPerTerm = 50

    public enum ValidationError: Swift.Error, LocalizedError, Equatable {
        case empty
        case containsLineBreak
        case tooLong(limit: Int)
        case duplicate(String)
        case full(limit: Int)
        case invalidUTF8
        case multipleCSVColumns(line: Int)
        case malformedCSV(line: Int)

        public var errorDescription: String? {
            switch self {
            case .empty:
                "Enter a word or phrase."
            case .containsLineBreak:
                "A dictionary entry must fit on one line."
            case .tooLong(let limit):
                "Dictionary entries can be at most \(limit) characters."
            case .duplicate(let term):
                "“\(term)” is already in the dictionary."
            case .full(let limit):
                "The dictionary can contain at most \(limit) entries."
            case .invalidUTF8:
                "The file is not UTF-8 text."
            case .multipleCSVColumns(let line):
                "Line \(line) has more than one CSV column. Use one entry per row."
            case .malformedCSV(let line):
                "Line \(line) has an unterminated or malformed quoted value."
            }
        }
    }

    /// Validates one entry and gives every client the same stored spelling.
    public static func normalize(_ raw: String) throws -> String {
        guard !raw.contains(where: \Character.isNewline) else {
            throw ValidationError.containsLineBreak
        }
        let term = raw.split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
        guard !term.isEmpty else { throw ValidationError.empty }
        guard term.count <= maxCharactersPerTerm else {
            throw ValidationError.tooLong(limit: maxCharactersPerTerm)
        }
        return term
    }

    /// Cleans a persisted list defensively. Invalid and duplicate values are omitted rather than
    /// making an old preferences file prevent the app from launching.
    public static func sanitized(_ raw: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for value in raw {
            guard let term = try? normalize(value) else { continue }
            guard seen.insert(term.lowercased()).inserted else { continue }
            result.append(term)
            if result.count == maxTerms { break }
        }
        return result
    }

    public static func adding(_ raw: String, to terms: [String]) throws -> [String] {
        let current = sanitized(terms)
        guard current.count < maxTerms else { throw ValidationError.full(limit: maxTerms) }
        let term = try normalize(raw)
        guard !current.contains(where: { $0.caseInsensitiveCompare(term) == .orderedSame }) else {
            throw ValidationError.duplicate(term)
        }
        return current + [term]
    }

    public static func replacing(_ original: String, with raw: String, in terms: [String]) throws
        -> [String]
    {
        var current = sanitized(terms)
        guard let index = current.firstIndex(of: original) else { return current }
        let term = try normalize(raw)
        guard !current.enumerated().contains(where: {
            $0.offset != index && $0.element.caseInsensitiveCompare(term) == .orderedSame
        }) else {
            throw ValidationError.duplicate(term)
        }
        current[index] = term
        return current
    }

    /// Reads Typeless-compatible bulk input: UTF-8, one CSV column, one entry per row.
    /// Plain newline-separated text is the same format without quoting and works as well.
    public static func entries(fromCSV data: Data) throws -> [String] {
        guard var text = String(data: data, encoding: .utf8) else {
            throw ValidationError.invalidUTF8
        }
        if text.first == "\u{FEFF}" { text.removeFirst() }
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var result: [String] = []
        var seen: Set<String> = []
        for (offset, line) in text.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
        {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let value = try field(fromCSVLine: String(line), lineNumber: offset + 1)
            let term = try normalize(value)
            guard seen.insert(term.lowercased()).inserted else { continue }
            result.append(term)
            guard result.count <= maxTerms else {
                throw ValidationError.full(limit: maxTerms)
            }
        }
        return result
    }

    /// Merges an import atomically. Existing entries keep their order and duplicates are ignored.
    public static func importing(_ imported: [String], into terms: [String]) throws -> [String] {
        var result = sanitized(terms)
        var seen = Set(result.map { $0.lowercased() })
        for raw in imported {
            let term = try normalize(raw)
            guard seen.insert(term.lowercased()).inserted else { continue }
            guard result.count < maxTerms else { throw ValidationError.full(limit: maxTerms) }
            result.append(term)
        }
        return result
    }

    /// Finds spelling corrections in text the user edited after insertion.
    ///
    /// Only spans the existing transcript classifier considers a spelling fix are returned.
    /// Insertions, deletions, number changes and substitutions between different words are ignored:
    /// those are ordinary editing, not evidence that a spelling belongs in the dictionary.
    public static func learnedCandidates(from original: String, corrected: String) -> [String] {
        guard original != corrected else { return [] }
        let left = TranscriptDiff.tokenize(original)
        let right = TranscriptDiff.tokenize(corrected)
        var candidates: [String] = []

        for difference in TranscriptDiff.alignedDifferences(left, right) {
            let classification = TranscriptDiff.classify(
                left: difference.left, right: difference.right)
            if classification == .spellingFixed,
                let term = usableLearnedTerm(difference.right.joined(separator: " "))
            {
                candidates.append(term)
            } else if classification == .contentChanged {
                // A spelling fix beside an ordinary edit is one LCS span — for example
                // `swift UI tomorrow` → `SwiftUI on Friday`. Search the small subspans so the
                // spelling can still be learned without treating the rewording as vocabulary.
                candidates.append(contentsOf: spellingSubspans(in: difference))
            }
        }

        // Alignment intentionally ignores case and punctuation, which is right for regression
        // scoring and would otherwise miss `swiftui` → `SwiftUI`. Recover one-to-one cosmetic
        // corrections separately without treating a sentence's normal punctuation as vocabulary.
        if left.count == right.count {
            for (before, after) in zip(left, right)
            where TranscriptDiff.normalize(before) == TranscriptDiff.normalize(after)
                && before != after
            {
                guard before.caseInsensitiveCompare(after) == .orderedSame,
                    let term = usableLearnedTerm(after)
                else { continue }
                candidates.append(term)
            }
        }
        return sanitized(candidates)
    }

    /// Builds a strongly delimited spelling-only request part for a model provider.
    ///
    /// JSON encoding means quotes and punctuation in an entry cannot break the list's structure.
    /// The framing repeats the audio-authority rule because this list is a prior, not evidence that
    /// an entry was spoken. Keeping this outside the system instruction also leaves the versioned,
    /// user-editable base prompt exactly as inspected in the prompt editor.
    public static func referenceBlock(terms raw: [String]) -> String? {
        let terms = sanitized(raw)
        guard !terms.isEmpty,
            let data = try? JSONSerialization.data(withJSONObject: terms),
            let json = String(data: data, encoding: .utf8)
        else { return nil }

        return """
            PERSONAL DICTIONARY — SPELLING REFERENCE ONLY, DO NOT TRANSCRIBE
            The user supplied the JSON strings below as possible spellings. Use an entry only when
            the same word or phrase is audible. The list is not evidence that an entry was spoken,
            and it never overrides clear audio. Digits, versions and quantities come from audio
            alone even when an entry contains a number.
            \(json)
            END PERSONAL DICTIONARY. The audio is still the ONLY thing to transcribe.
            """
    }

    /// Terms safe for a bare speech-recognition keyterm channel.
    ///
    /// A keyterm API has nowhere to attach the reference-only request part above. Number-bearing
    /// entries are therefore withheld under the same hard rule as automatically derived terms:
    /// versions and quantities must come from audio alone.
    public static func keyterms(
        from raw: [String], maxTerms: Int, maxCharactersPerTerm: Int
    ) -> [String] {
        guard maxTerms > 0 else { return [] }
        return sanitized(raw).filter {
            !$0.contains(where: \Character.isNumber) && $0.count <= maxCharactersPerTerm
        }.prefix(maxTerms).map { $0 }
    }

    /// User entries first, optional screen-derived terms second, with case-insensitive deduping.
    public static func mergingKeyterms(
        dictionary: [String], derived: [String], maxTerms: Int, maxCharactersPerTerm: Int
    ) -> [String] {
        var result = keyterms(
            from: dictionary, maxTerms: maxTerms, maxCharactersPerTerm: maxCharactersPerTerm)
        guard result.count < maxTerms else { return result }
        var seen = Set(result.map { $0.lowercased() })
        for term in derived where term.count <= maxCharactersPerTerm {
            guard seen.insert(term.lowercased()).inserted else { continue }
            result.append(term)
            if result.count == maxTerms { break }
        }
        return result
    }

    // MARK: - CSV

    private static func field(fromCSVLine line: String, lineNumber: Int) throws -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.first == "\"" else {
            guard !line.contains(",") else {
                throw ValidationError.multipleCSVColumns(line: lineNumber)
            }
            return line
        }

        var value = ""
        var index = trimmed.index(after: trimmed.startIndex)
        var closed = false
        while index < trimmed.endIndex {
            let character = trimmed[index]
            if character == "\"" {
                let next = trimmed.index(after: index)
                if next < trimmed.endIndex, trimmed[next] == "\"" {
                    value.append("\"")
                    index = trimmed.index(after: next)
                    continue
                }
                closed = true
                index = next
                break
            }
            value.append(character)
            index = trimmed.index(after: index)
        }
        guard closed else { throw ValidationError.malformedCSV(line: lineNumber) }

        let remainder = trimmed[index...].trimmingCharacters(in: .whitespaces)
        guard remainder.isEmpty else {
            if remainder.first == "," {
                throw ValidationError.multipleCSVColumns(line: lineNumber)
            }
            throw ValidationError.malformedCSV(line: lineNumber)
        }
        return value
    }

    private static func usableLearnedTerm(_ raw: String) -> String? {
        let surrounding = CharacterSet(charactersIn: "\"“”‘’(),;:!?[]{}")
        let candidate = raw.trimmingCharacters(in: surrounding.union(.whitespacesAndNewlines))
        guard let term = try? normalize(candidate), term.count >= 3,
            term.contains(where: \Character.isLetter),
            !term.contains(where: \Character.isNumber)
        else { return nil }
        return term
    }

    private static func spellingSubspans(
        in difference: (left: [String], right: [String])
    ) -> [String] {
        var matches: [(coverage: Int, term: String)] = []
        for leftStart in difference.left.indices {
            for rightStart in difference.right.indices {
                for leftCount in 1...min(3, difference.left.count - leftStart) {
                    for rightCount in 1...min(3, difference.right.count - rightStart) {
                        let left = Array(
                            difference.left[leftStart..<(leftStart + leftCount)])
                        let right = Array(
                            difference.right[rightStart..<(rightStart + rightCount)])
                        guard TranscriptDiff.classify(left: left, right: right) == .spellingFixed,
                            let term = usableLearnedTerm(right.joined(separator: " "))
                        else { continue }
                        matches.append((leftCount + rightCount, term))
                    }
                }
            }
        }
        // Prefer the match explaining the most tokens. Multiple independent fixes normally land
        // in separate LCS spans; one content span contributes only its strongest candidate.
        return matches.max(by: { $0.coverage < $1.coverage }).map { [$0.term] } ?? []
    }
}
