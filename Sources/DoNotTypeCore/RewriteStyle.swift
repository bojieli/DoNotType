import Foundation

/// An optional rewrite applied to a finished transcript.
///
/// `verbatim` is not a style — it is the absence of one, and the default. The others exist because
/// people genuinely do want formal prose sometimes; what makes this different from Typeless is
/// that the raw transcript is always produced first, always stored, and always recoverable.
public enum RewriteStyle: String, CaseIterable, Sendable, Codable {
    case verbatim
    case formal
    case concise
    case casual
    /// The user's own description or example, from settings rather than from a file.
    ///
    /// Three shipped styles are three guesses at what somebody wants their email to sound like.
    /// This is the fourth answer — the one we did not think of — and it goes through the same
    /// `prompt/rewrite.md` host block as the presets, so the never-remove-a-fact rule applies to it
    /// exactly as it applies to `formal`.
    case custom

    public static let `default`: RewriteStyle = .verbatim

    public var isRewrite: Bool { self != .verbatim }

    /// Whether the clause comes from a file in `prompt/style/`. False for `custom`, whose clause is
    /// the user's own text, and for `verbatim`, which is the absence of a rewrite.
    public var hasClauseFile: Bool { isRewrite && self != .custom }

    public var label: String {
        switch self {
        case .verbatim: "Verbatim — exactly what you said"
        case .formal: "Formal — professional prose"
        case .concise: "Concise — same voice, fewer words"
        case .casual: "Casual — relaxed, as if typed"
        case .custom: "Custom — your own description or example"
        }
    }

    /// Key under `### style: <name>` in PROMPT.md.
    var promptSection: String { "style: \(rawValue)" }
}
