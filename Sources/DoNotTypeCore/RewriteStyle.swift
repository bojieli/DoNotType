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

    public static let `default`: RewriteStyle = .verbatim

    public var isRewrite: Bool { self != .verbatim }

    public var label: String {
        switch self {
        case .verbatim: "Verbatim — exactly what you said"
        case .formal: "Formal — professional prose"
        case .concise: "Concise — same voice, fewer words"
        case .casual: "Casual — relaxed, as if typed"
        }
    }

    /// Key under `### style: <name>` in PROMPT.md.
    var promptSection: String { "style: \(rawValue)" }
}
