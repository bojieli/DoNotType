import Foundation

/// Reads the single-file `PROMPT.md` format that `prompt/` replaced.
///
/// Kept for one job only: splitting a user's edited copy into part files the first time they run a
/// version that expects the directory. Nothing in the app sends a prompt through this type, and it
/// should be deleted a release after the split ships.
///
/// The marker search here is anchored to whole lines, which the shipped loader never was. That is
/// the bug the split was made to end — a file that documented its own markers had them matched
/// inside the documentation, because the search took the first substring anywhere in the text.
/// Anyone whose custom prompt was a copy of the shipped one has that sentence in it, so migrating
/// with the original rule would carry the bug into their new part files.
public struct LegacyPromptFile: Sendable {
    public let template: String

    public init(template: String) {
        self.template = template
    }

    public init?(contentsOf url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8), !text.trimmed.isEmpty
        else { return nil }
        self.template = text
    }

    /// Whether this looks like the old format at all.
    public var isLegacyFormat: Bool { block("SYSTEM") != nil }

    /// Every part this file can supply, in the new layout's terms.
    ///
    /// Parts the file does not contain are simply absent — an old prompt written before the
    /// summary stage existed has no summary block, and the caller falls back to the shipped one
    /// rather than failing, which is the whole reason per-part overrides exist.
    public func parts() -> [PromptPart: String] {
        var found: [PromptPart: String] = [:]
        if let body = block("SYSTEM") { found[.system] = body }
        if let body = block("REWRITE") { found[.rewrite] = body }
        if let body = block("SUMMARY") { found[.summary] = body }
        for fidelity in Fidelity.allCases {
            if let body = clause(under: fidelity.rawValue) { found[.fidelity(fidelity)] = body }
        }
        // Only the file-backed styles: `custom`'s clause is the user's own text in settings, so
        // there is no shipped file for a legacy override to have replaced.
        for style in RewriteStyle.allCases where style.hasClauseFile {
            if let body = clause(under: "style: \(style.rawValue)") { found[.style(style)] = body }
        }
        for style in SummaryStyle.allCases {
            if let body = clause(under: "summary: \(style.rawValue)") {
                found[.summaryStyle(style)] = body
            }
        }
        return found
    }

    // MARK: - Private

    private var lines: [String] { template.components(separatedBy: "\n") }

    /// Body between markers that each sit alone on their own line.
    private func block(_ name: String) -> String? {
        let lines = lines
        var begin: Int?
        var end: Int?
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmed
            if trimmed == "<!-- BEGIN \(name) -->" {
                begin = index
            } else if trimmed == "<!-- END \(name) -->", begin != nil, end == nil {
                end = index
            }
        }
        guard let begin, let end, end > begin else { return nil }
        let body = lines[(begin + 1)..<end].joined(separator: "\n").trimmed
        return body.isEmpty ? nil : body
    }

    /// The first fenced block under a `### <name>` heading line.
    private func clause(under name: String) -> String? {
        let lines = lines
        let heading = "### \(name)"
        guard
            let start = lines.firstIndex(where: { line in
                let trimmed = line.trimmed
                guard trimmed.hasPrefix(heading) else { return false }
                // Tolerates the shipped file's `### light  *(default)*` without matching a
                // longer heading that merely starts the same way.
                let rest = String(trimmed.dropFirst(heading.count)).trimmed
                return rest.isEmpty || !(rest.first?.isLetter ?? false)
            })
        else { return nil }

        let fences = (start..<lines.count).filter { lines[$0].trimmed == "```" }
        guard fences.count >= 2 else { return nil }
        let body = lines[(fences[0] + 1)..<fences[1]].joined(separator: "\n").trimmed
        return body.isEmpty ? nil : body
    }
}
