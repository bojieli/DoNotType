import Foundation

/// One file in `prompt/`.
///
/// The contract used to be a single markdown file with the live text fenced off by
/// `<!-- BEGIN SYSTEM -->` markers, which meant a loader had to tell payload from prose by
/// convention — and it got that wrong for as long as the markers existed, because the file
/// documented its own markers and a first-match search found the documentation. A part is a whole
/// file now. Everything in it is sent, so there is nothing to skip and nothing to mis-match.
public enum PromptPart: Sendable, Hashable, Codable {
    /// The transcription contract itself. The only part sent on every request.
    case system
    /// The second-stage rewrite block.
    case rewrite
    /// The second-stage summary block. Separate from `rewrite` because their first rules
    /// contradict: a rewrite may never drop a fact, and a summary exists to.
    case summary
    /// One of the three fidelity clauses, substituted into `system`.
    case fidelity(Fidelity)
    /// One of the rewrite styles, substituted into `rewrite`. Never `.verbatim`, which is the
    /// absence of a rewrite rather than a style and so has no file.
    case style(RewriteStyle)
    /// One of the summary styles, substituted into `summary`.
    case summaryStyle(SummaryStyle)

    /// Every part that has a file, in the order a settings list should show them.
    public static let allCases: [PromptPart] =
        [.system, .rewrite, .summary]
        + Fidelity.allCases.map(PromptPart.fidelity)
        + RewriteStyle.allCases.filter(\.isRewrite).map(PromptPart.style)
        + SummaryStyle.allCases.map(PromptPart.summaryStyle)

    /// Path under `prompt/`, and under the override directory — the same layout in both, so
    /// "which file is in force" is answered by existence alone.
    public var relativePath: String {
        switch self {
        case .system: "system.md"
        case .rewrite: "rewrite.md"
        case .summary: "summary.md"
        case .fidelity(let fidelity): "fidelity/\(fidelity.rawValue).md"
        case .style(let style): "style/\(style.rawValue).md"
        case .summaryStyle(let style): "summary-style/\(style.rawValue).md"
        }
    }

    /// The one token substituted into this part, or nil for the clause parts, which are the
    /// things substituted *in*.
    public var placeholder: String? {
        switch self {
        case .system: "{{FIDELITY_RULE}}"
        case .rewrite: "{{STYLE_RULE}}"
        case .summary: "{{SUMMARY_RULE}}"
        case .fidelity, .style, .summaryStyle: nil
        }
    }

    /// Whether this part is substituted into a numbered list item in another part.
    ///
    /// The one transform in the whole loader: a clause is written as a wrapped paragraph and
    /// joined into a single line on load, because it lands inside `5. {{FIDELITY_RULE}}` and a
    /// hard newline there would break the list it lands in.
    public var isClause: Bool { placeholder == nil }

    /// The part a clause is substituted into.
    public var host: PromptPart? {
        switch self {
        case .system, .rewrite, .summary: nil
        case .fidelity: .system
        case .style: .rewrite
        case .summaryStyle: .summary
        }
    }

    // MARK: - Presentation

    /// Heading a settings list groups this part under.
    public var group: String {
        switch self {
        case .system, .rewrite, .summary: "Blocks"
        case .fidelity: "Fidelity"
        case .style: "Rewrite styles"
        case .summaryStyle: "Summary styles"
        }
    }

    public var label: String {
        switch self {
        case .system: "Transcription"
        case .rewrite: "Rewrite"
        case .summary: "Summary"
        case .fidelity(let fidelity): fidelity.rawValue
        case .style(let style): style.rawValue
        case .summaryStyle(let style): style.rawValue
        }
    }

    /// One line on what this part does, for the editor that has room to say so.
    public var summaryLine: String {
        switch self {
        case .system: "Sent on every request. Must contain {{FIDELITY_RULE}}."
        case .rewrite: "Sent only when a rewrite style is chosen."
        case .summary: "Sent only when a summary style is chosen."
        case .fidelity: "Substituted into the transcription block."
        case .style: "Substituted into the rewrite block."
        case .summaryStyle: "Substituted into the summary block."
        }
    }

    /// `system`, `fidelity:light`, `style:formal` — what the CLI accepts and an error names.
    public var id: String {
        switch self {
        case .system: "system"
        case .rewrite: "rewrite"
        case .summary: "summary"
        case .fidelity(let fidelity): "fidelity:\(fidelity.rawValue)"
        case .style(let style): "style:\(style.rawValue)"
        case .summaryStyle(let style): "summary-style:\(style.rawValue)"
        }
    }

    public init?(id: String) {
        let parts = id.trimmed.lowercased().split(separator: ":", maxSplits: 1)
        guard let head = parts.first else { return nil }
        let tail = parts.count > 1 ? String(parts[1]) : nil

        switch (head, tail) {
        case ("system", nil), ("transcribe", nil): self = .system
        case ("rewrite", nil): self = .rewrite
        case ("summary", nil): self = .summary
        case ("fidelity", let name?):
            guard let value = Fidelity(rawValue: name) else { return nil }
            self = .fidelity(value)
        case ("style", let name?):
            guard let value = RewriteStyle(rawValue: name), value.isRewrite else { return nil }
            self = .style(value)
        case ("summary-style", let name?), ("summary", let name?):
            guard let value = SummaryStyle(rawValue: name) else { return nil }
            self = .summaryStyle(value)
        default: return nil
        }
    }

    /// Every accepted spelling, for a `--help` string that lists them rather than describing them.
    public static var acceptedSpellings: [String] { allCases.map(\.id) }
}
