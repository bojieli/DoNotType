import Foundation

/// The user's own copy of `PROMPT.md`, if they have edited one.
///
/// This is open-source software whose entire behaviour is a prompt, so making that prompt readable
/// but not editable would be an odd place to draw the line. The bundled version is the default and
/// can always be restored; an edited copy lives beside the history where the user can find it.
///
/// One caveat is worth surfacing in any UI that exposes this: the numbers in `PROMPT.md`'s
/// changelog were measured against the bundled text. An edited prompt invalidates them, which is
/// why `dnt-eval --prompt` exists — so a custom prompt can be measured rather than assumed.
public struct PromptStore: Sendable {
    public enum ValidationError: LocalizedError, Equatable {
        case missingSystemMarkers
        case missingFidelityPlaceholder
        case missingFidelitySection(String)
        case empty

        public var errorDescription: String? {
            switch self {
            case .missingSystemMarkers:
                "The prompt needs a <!-- BEGIN SYSTEM --> … <!-- END SYSTEM --> block."
            case .missingFidelityPlaceholder:
                "The system block needs a {{FIDELITY_RULE}} placeholder."
            case .missingFidelitySection(let name):
                "There is no \"### \(name)\" section with a fenced clause under it."
            case .empty:
                "The prompt is empty."
            }
        }
    }

    private let directory: URL
    private let fileName = "PROMPT.md"

    public init(directory: URL) {
        self.directory = directory
    }

    public var customURL: URL { directory.appendingPathComponent(fileName) }

    public var hasCustomPrompt: Bool {
        FileManager.default.fileExists(atPath: customURL.path)
    }

    /// The text in force: the user's copy when present, otherwise the bundled default.
    public func activeTemplate(default defaultURL: URL) throws -> String {
        if hasCustomPrompt, let text = try? String(contentsOf: customURL, encoding: .utf8),
            !text.trimmed.isEmpty
        {
            return text
        }
        return try String(contentsOf: defaultURL, encoding: .utf8)
    }

    public func builder(default defaultURL: URL) throws -> PromptBuilder {
        PromptBuilder(template: try activeTemplate(default: defaultURL))
    }

    /// Validates before writing. A prompt that cannot build is a silently broken app, and the
    /// failure would surface as a mid-dictation error rather than at the moment of editing.
    public func save(_ template: String) throws {
        try Self.validate(template)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        try template.write(to: customURL, atomically: true, encoding: .utf8)
    }

    public func restoreDefault() throws {
        guard hasCustomPrompt else { return }
        try FileManager.default.removeItem(at: customURL)
    }

    /// Checks that every substitution the app performs will succeed.
    public static func validate(_ template: String) throws {
        guard !template.trimmed.isEmpty else { throw ValidationError.empty }

        let builder = PromptBuilder(template: template)
        guard template.contains(PromptBuilder.beginMarker),
            template.contains(PromptBuilder.endMarker)
        else { throw ValidationError.missingSystemMarkers }

        guard template.contains(PromptBuilder.fidelityPlaceholder) else {
            throw ValidationError.missingFidelityPlaceholder
        }

        // Every fidelity has to resolve, or switching to it later would break mid-use.
        for fidelity in Fidelity.allCases {
            guard (try? builder.systemInstruction(fidelity: fidelity)) != nil else {
                throw ValidationError.missingFidelitySection(fidelity.rawValue)
            }
        }
    }
}
