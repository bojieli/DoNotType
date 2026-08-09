import Foundation

/// Classifies what screen context changed about a transcript.
///
/// The method: transcribe the same recording twice, once with context and once without, then diff.
/// Every difference is by construction something grounding caused, which turns an invisible
/// failure mode into a countable one.
///
/// The distinction that matters is *spelling* versus *content*. Grounding is supposed to fix how a
/// word is written; it is never supposed to change which word was said. The second kind is the
/// dangerous one because the output still looks correct — "Gemini 3.5 Flash" becoming
/// "Gemini 3 Flash" reads as a properly transcribed technical term.
public enum TranscriptDiff {
    public enum Classification: String, Sendable {
        /// Same words, different capitalisation or punctuation.
        case cosmetic
        /// Different spelling of the same sounds. Grounding working as intended.
        case spellingFixed = "spelling-fixed"
        /// Different words or different numbers. The bug.
        case contentChanged = "content-changed"
        /// Present only with context.
        case inserted
        /// Present only without context.
        case deleted

        public var isBug: Bool {
            switch self {
            case .cosmetic, .spellingFixed: false
            case .contentChanged, .inserted, .deleted: true
            }
        }
    }

    public struct Span: Sendable, Equatable {
        /// Tokens from the no-context transcript.
        public var withoutContext: [String]
        /// Tokens from the with-context transcript.
        public var withContext: [String]
        public var classification: Classification

        public var description: String {
            let before = withoutContext.isEmpty ? "∅" : withoutContext.joined(separator: " ")
            let after = withContext.isEmpty ? "∅" : withContext.joined(separator: " ")
            return "\(before) → \(after)"
        }

        public static func == (a: Span, b: Span) -> Bool {
            a.withoutContext == b.withoutContext && a.withContext == b.withContext
                && a.classification == b.classification
        }
    }

    public struct Report: Sendable {
        public var spans: [Span]

        public func count(_ classification: Classification) -> Int {
            spans.count(where: { $0.classification == classification })
        }
        /// Zero is the shipping bar.
        public var bugCount: Int { spans.count(where: \.classification.isBug) }
        public var isClean: Bool { bugCount == 0 }
    }

    /// - Parameters:
    ///   - withoutContext: transcript produced with no screen context — the baseline.
    ///   - withContext: transcript produced with the context blocks attached.
    public static func compare(withoutContext: String, withContext: String) -> Report {
        let left = tokenize(withoutContext)
        let right = tokenize(withContext)
        let spans = alignedDifferences(left, right).map { pair in
            Span(
                withoutContext: pair.left,
                withContext: pair.right,
                classification: classify(left: pair.left, right: pair.right)
            )
        }
        return Report(spans: spans)
    }

    // MARK: - Classification

    static func classify(left: [String], right: [String]) -> Classification {
        if left.isEmpty { return .inserted }
        if right.isEmpty { return .deleted }

        let leftJoined = left.joined(separator: " ")
        let rightJoined = right.joined(separator: " ")

        // Numbers are never a spelling question. This is what catches 3.5 → 3.
        guard digitRuns(leftJoined) == digitRuns(rightJoined) else { return .contentChanged }

        // Compared token-wise, so that re-splitting a word boundary ("swift UI" → "SwiftUI") is
        // reported as the spelling fix it is rather than dismissed as punctuation.
        if left.map(normalize) == right.map(normalize) { return .cosmetic }
        if phoneticKey(leftJoined) == phoneticKey(rightJoined) { return .spellingFixed }
        return .contentChanged
    }

    /// All digit sequences in order, so "3.5" and "3" are distinguishable.
    static func digitRuns(_ text: String) -> [String] {
        var runs: [String] = []
        var current = ""
        for character in text {
            if character.isNumber {
                current.append(character)
            } else if !current.isEmpty {
                runs.append(current)
                current = ""
            }
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    static func normalize(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Collapses spelling variants that sound alike: koffi/coffee, swift UI/SwiftUI.
    ///
    /// Vowels are folded to a single class rather than dropped outright, which is stricter than
    /// classic Soundex. Deliberate: a false "spelling-fixed" hides a real substitution, so the
    /// classifier should err toward reporting a content change. It is still a heuristic — the
    /// per-case `expectTranscript` assertion is the actual gate, and this explains failures.
    static func phoneticKey(_ text: String) -> String {
        var value = text.lowercased().filter(\.isLetter)
        guard !value.isEmpty else { return "" }

        for (from, to) in [
            ("sch", "sk"), ("ph", "f"), ("ck", "k"), ("kn", "n"),
            ("wr", "r"), ("gn", "n"), ("gh", ""), ("wh", "w"),
        ] {
            value = value.replacingOccurrences(of: from, with: to)
        }

        var mapped = ""
        let characters = Array(value)
        for (index, character) in characters.enumerated() {
            switch character {
            case "c":
                let next = index + 1 < characters.count ? characters[index + 1] : " "
                mapped.append("eiy".contains(next) ? "s" : "k")
            case "q": mapped.append("k")
            case "x": mapped.append("ks")
            case "z": mapped.append("s")
            case "v": mapped.append("f")
            case "a", "e", "i", "o", "u", "y": mapped.append("a")
            case "h", "w": break  // effectively silent between sounds
            default: mapped.append(character)
            }
        }

        var collapsed = ""
        for character in mapped where collapsed.last != character {
            collapsed.append(character)
        }
        return collapsed
    }

    // MARK: - Alignment

    static func tokenize(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { !normalize($0).isEmpty }
    }

    /// Longest-common-subsequence alignment, returning only the differing runs.
    ///
    /// Matching on the normalized form means capitalisation and punctuation never create spurious
    /// spans, and a merge like "swift UI" → "SwiftUI" surfaces as one span rather than two.
    static func alignedDifferences(
        _ left: [String], _ right: [String]
    ) -> [(left: [String], right: [String])] {
        let leftKeys = left.map(normalize)
        let rightKeys = right.map(normalize)

        var lengths = Array(
            repeating: Array(repeating: 0, count: rightKeys.count + 1), count: leftKeys.count + 1)
        for i in stride(from: leftKeys.count - 1, through: 0, by: -1) {
            for j in stride(from: rightKeys.count - 1, through: 0, by: -1) {
                lengths[i][j] =
                    leftKeys[i] == rightKeys[j]
                    ? lengths[i + 1][j + 1] + 1
                    : max(lengths[i + 1][j], lengths[i][j + 1])
            }
        }

        var spans: [(left: [String], right: [String])] = []
        var pendingLeft: [String] = []
        var pendingRight: [String] = []
        var i = 0, j = 0

        func flush() {
            if !pendingLeft.isEmpty || !pendingRight.isEmpty {
                spans.append((pendingLeft, pendingRight))
                pendingLeft = []
                pendingRight = []
            }
        }

        while i < leftKeys.count, j < rightKeys.count {
            if leftKeys[i] == rightKeys[j] {
                flush()
                i += 1
                j += 1
            } else if lengths[i + 1][j] >= lengths[i][j + 1] {
                pendingLeft.append(left[i])
                i += 1
            } else {
                pendingRight.append(right[j])
                j += 1
            }
        }
        pendingLeft.append(contentsOf: left[i...])
        pendingRight.append(contentsOf: right[j...])
        flush()
        return spans
    }
}
