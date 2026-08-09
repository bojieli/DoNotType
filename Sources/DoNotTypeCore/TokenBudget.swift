import Foundation

/// Token estimation and truncation.
///
/// The estimator is a port of the one in Typeless's bundle, kept faithful rather than improved:
/// it is calibrated against the same kind of accessibility text we feed it, and a
/// deliberately cheap heuristic is the right tool for deciding where to cut a buffer.
///
/// The important behaviour is the *direction* of truncation. Screen text is cut keeping the
/// **tail**, because the end of a buffer is the part nearest the caret and therefore the part
/// most likely to contain the words being spoken right now.
public enum TokenBudget {
    /// Approximate token count.
    ///
    /// CJK-dense text tokenises far denser than prose, so it gets its own branch: above 30% Han
    /// characters, roughly 1.3 characters per token; otherwise the larger of ~1.3 tokens per word
    /// and ~4 characters per token.
    public static func estimate(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        let length = text.count
        let hanCount = text.unicodeScalars.count(where: { (0x4E00...0x9FFF).contains($0.value) })

        if Double(hanCount) / Double(length) > 0.3 {
            return Int((Double(length) / 1.3).rounded(.up))
        }
        let words = text.split(whereSeparator: \.isWhitespace).count
        let byWords = Double(words) * 1.3
        let byChars = Double(length) / 4.0
        return Int(max(byWords, byChars).rounded(.up))
    }

    /// Largest suffix of `text` whose estimate fits `maxTokens`.
    ///
    /// Binary search over the cut point. `estimate` is monotonically non-increasing as the cut
    /// moves right, which is what makes the search valid.
    public static func truncateKeepingTail(_ text: String, maxTokens: Int) -> String {
        guard maxTokens > 0 else { return "" }
        guard estimate(text) > maxTokens else { return text }

        let chars = Array(text)
        var low = 0                 // cut here -> too many tokens
        var high = chars.count      // cut here -> empty, always fits

        while low < high {
            let mid = (low + high) / 2
            if estimate(String(chars[mid...])) <= maxTokens {
                high = mid
            } else {
                low = mid + 1
            }
        }
        return String(chars[low...])
    }

    /// Last `maxChars` characters. Used for visible text and the pre-caret window.
    public static func clipKeepingTail(_ text: String, maxChars: Int) -> String {
        guard maxChars > 0 else { return "" }
        guard text.count > maxChars else { return text }
        return String(text.suffix(maxChars))
    }

    /// First `maxChars` characters. Used for the post-caret window, where the caret is at the head.
    public static func clipKeepingHead(_ text: String, maxChars: Int) -> String {
        guard maxChars > 0 else { return "" }
        guard text.count > maxChars else { return text }
        return String(text.prefix(maxChars))
    }
}
