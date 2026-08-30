import Foundation

/// The language a dictation is written in when it is not the one that was spoken.
///
/// Free text, and deliberately so, for the same reason the Model field is: languages are not ours
/// to enumerate. "Traditional Chinese", "Brazilian Portuguese", "plain English for a five-year-old"
/// and "Swiss German" are all things a model can do and none of them is a row in an enum somebody
/// would have thought to add. The check here is about **shape**, never about existence — what
/// passes is still sent to the model, which remains the authority on whether it can write it.
///
/// The suggestions exist so the common case is one tap rather than one sentence of typing. They
/// are not a whitelist and nothing validates against them.
public enum TranslationTarget {
    /// Long enough for "Traditional Chinese, in the register of a business email"; short enough
    /// that nobody pastes a paragraph into it and wonders why every request got slower.
    public static let maxCharacters = 60

    /// Empty means off, which is the default and the only value that changes nothing.
    public static func sanitized(_ text: String) -> String {
        // One line, because this lands inside a sentence in the instruction. A newline pasted from
        // a language list would break the sentence around it rather than the language it names.
        let flattened = text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        let collapsed = flattened.split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        return collapsed.count > maxCharacters
            ? String(collapsed.prefix(maxCharacters)).trimmed : collapsed
    }

    /// The sentence under the field when what is in it could not be a language, or nil when it
    /// could. Phrased as what the field takes rather than as a rejection — nothing is lost while
    /// it is showing, exactly as with a model ID.
    ///
    /// Must stay word-identical across the four clients. See `docs/PARITY.md`.
    public static func validationMessage(_ text: String?) -> String? {
        let value = text ?? ""
        // Empty is off, not invalid.
        guard !value.trimmed.isEmpty else { return nil }
        if sanitized(value).count > maxCharacters || value.count > maxCharacters {
            return "A language name is at most \(maxCharacters) characters."
        }
        return nil
    }

    /// One tap for the languages people ask for most, in each language's own name where it has
    /// one. Not a whitelist: the field accepts anything, and this list is only a shortcut.
    public static let suggestions: [String] = [
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
    ]
}
