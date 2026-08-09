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

    static let beginMarker = "<!-- BEGIN SYSTEM -->"
    static let endMarker = "<!-- END SYSTEM -->"
    static let fidelityPlaceholder = "{{FIDELITY_RULE}}"

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

    /// Pulls the clause out of the fenced block under `### <fidelity>`.
    func fidelityClause(_ fidelity: Fidelity) throws -> String {
        let heading = "### \(fidelity.rawValue)"
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
