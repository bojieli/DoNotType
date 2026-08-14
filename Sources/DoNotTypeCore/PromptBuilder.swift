import Foundation

/// Assembles the system instruction from `PROMPT.md`.
///
/// The contract lives in a markdown file at the repo root rather than a Swift string literal
/// because it is the actual product, it has to stay identical across platforms, and it is what
/// contributors will want to argue about. Keeping it in a file makes changes reviewable as
/// changes to the product rather than as changes to code.
public struct PromptBuilder: Sendable {
    public enum Error: Swift.Error, LocalizedError {
        case markersMissing(String)

        public var errorDescription: String? {
            switch self {
            case .markersMissing(let detail): "PROMPT.md is malformed: \(detail)"
            }
        }
    }

    public static let beginMarker = "<!-- BEGIN SYSTEM -->"
    public static let endMarker = "<!-- END SYSTEM -->"
    public static let fidelityPlaceholder = "{{FIDELITY_RULE}}"
    static let rewriteBeginMarker = "<!-- BEGIN REWRITE -->"
    static let rewriteEndMarker = "<!-- END REWRITE -->"
    static let stylePlaceholder = "{{STYLE_RULE}}"
    static let summaryBeginMarker = "<!-- BEGIN SUMMARY -->"
    static let summaryEndMarker = "<!-- END SUMMARY -->"
    static let summaryPlaceholder = "{{SUMMARY_RULE}}"

    public let template: String

    /// - Parameter template: full text of `PROMPT.md`.
    public init(template: String) {
        self.template = template
    }

    public init(contentsOf url: URL) throws {
        self.template = try String(contentsOf: url, encoding: .utf8)
    }

    /// Locates `PROMPT.md` by walking up from a starting path.
    ///
    /// Lets `dnt-eval` run from anywhere in the tree without a `--prompt` flag.
    public static func findPromptFile(startingAt start: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)) -> URL? {
        var directory = start.standardizedFileURL
        for _ in 0..<8 {
            let candidate = directory.appendingPathComponent("PROMPT.md")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }
        return nil
    }

    public func systemInstruction(fidelity: Fidelity = .default) throws -> String {
        guard
            let begin = template.range(of: Self.beginMarker),
            let end = template.range(of: Self.endMarker),
            begin.upperBound < end.lowerBound
        else {
            throw Error.markersMissing("expected \(Self.beginMarker) … \(Self.endMarker)")
        }
        let body = String(template[begin.upperBound..<end.lowerBound]).trimmed
        guard body.contains(Self.fidelityPlaceholder) else {
            throw Error.markersMissing("system block has no \(Self.fidelityPlaceholder)")
        }
        return body.replacingOccurrences(
            of: Self.fidelityPlaceholder, with: try fidelityClause(fidelity))
    }

    /// System instruction for the second-stage rewrite.
    public func rewriteInstruction(style: RewriteStyle) throws -> String {
        guard style.isRewrite else { return "" }
        guard
            let begin = template.range(of: Self.rewriteBeginMarker),
            let end = template.range(of: Self.rewriteEndMarker),
            begin.upperBound < end.lowerBound
        else {
            throw Error.markersMissing("expected \(Self.rewriteBeginMarker) … \(Self.rewriteEndMarker)")
        }
        let body = String(template[begin.upperBound..<end.lowerBound]).trimmed
        return body.replacingOccurrences(
            of: Self.stylePlaceholder, with: try clause(named: style.promptSection))
    }

    /// The style rule alone, for appending to a transcription prompt in single-pass mode.
    public func styleClause(_ style: RewriteStyle) throws -> String {
        style.isRewrite ? try clause(named: style.promptSection) : ""
    }

    /// System instruction for the summary stage.
    ///
    /// A separate block from `rewriteInstruction` rather than another style inside it, because the
    /// two have opposite contracts: a rewrite may never drop a fact, and a summary exists to. See
    /// "The summary stage" in `PROMPT.md`.
    public func summaryInstruction(style: SummaryStyle) throws -> String {
        guard
            let begin = template.range(of: Self.summaryBeginMarker),
            let end = template.range(of: Self.summaryEndMarker),
            begin.upperBound < end.lowerBound
        else {
            throw Error.markersMissing(
                "expected \(Self.summaryBeginMarker) … \(Self.summaryEndMarker). A prompt edited "
                    + "before summaries existed will not have one — restore the shipped prompt, or "
                    + "copy that block across from it.")
        }
        let body = String(template[begin.upperBound..<end.lowerBound]).trimmed
        return body.replacingOccurrences(
            of: Self.summaryPlaceholder, with: try clause(named: style.promptSection))
    }

    /// The instruction for whichever second stage a mode asks for, or nil when it asks for none.
    ///
    /// One entry point, so a caller cannot route a summary through the rewrite block by picking the
    /// wrong builder method — which is the mistake the two-block split exists to make impossible.
    public func secondStageInstruction(for mode: TranscriptMode) throws -> String? {
        switch mode {
        case .verbatim: nil
        case .rewrite(let style): try rewriteInstruction(style: style)
        case .summary(let style): try summaryInstruction(style: style)
        }
    }

    /// Pulls the clause out of the fenced block under `### <fidelity>`.
    func fidelityClause(_ fidelity: Fidelity) throws -> String {
        try clause(named: fidelity.rawValue)
    }

    private func clause(named name: String) throws -> String {
        let heading = "### \(name)"
        guard let headingRange = template.range(of: heading) else {
            throw Error.markersMissing("no section \(heading)")
        }
        let rest = template[headingRange.upperBound...]
        guard
            let open = rest.range(of: "```"),
            let close = rest[open.upperBound...].range(of: "```")
        else {
            throw Error.markersMissing("no fenced clause under \(heading)")
        }
        return String(rest[open.upperBound..<close.lowerBound])
            .trimmed
            .replacingOccurrences(of: "\n", with: " ")
    }
}
