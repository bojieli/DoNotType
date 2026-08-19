import Foundation

/// The user's own copies of prompt parts, if they have edited any.
///
/// This is open-source software whose entire behaviour is a prompt, so making that prompt readable
/// but not editable would be an odd place to draw the line. Every part can be edited on its own and
/// restored on its own; the shipped text is always one button away.
///
/// One caveat is worth surfacing in any UI that exposes this: the numbers in `docs/PROMPT.md`'s
/// changelog were measured against the shipped parts. An edited part invalidates them, which is
/// why `dnt-eval --prompt` exists — so a custom prompt can be measured rather than assumed.
public struct PromptStore: Sendable {
    public enum ValidationError: LocalizedError, Equatable {
        case empty(PromptPart)
        case missingPlaceholder(PromptPart, String)

        public var errorDescription: String? {
            switch self {
            case .empty(let part):
                "\(part.id) is empty. A part file is sent in full, so an empty one sends nothing."
            case .missingPlaceholder(let part, let placeholder):
                "\(part.id) needs a \(placeholder) placeholder — without it the clause chosen in "
                    + "settings would never reach the model."
            }
        }
    }

    /// What a migration from the single-file format did, for the message that reports it.
    public struct Migration: Sendable, Equatable {
        /// Parts whose text differed from the shipped version and became overrides.
        public var migrated: [PromptPart]
        /// Where the old file was moved.
        public var archivedAt: URL
    }

    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// Overrides live in `prompt/` under the history directory, mirroring the shipped layout so
    /// "which file is in force" is answered by existence alone.
    public var promptDirectory: URL { directory.appendingPathComponent("prompt") }

    /// Where the pre-split single file lived.
    public var legacyURL: URL { directory.appendingPathComponent("PROMPT.md") }

    public func url(for part: PromptPart) -> URL {
        promptDirectory.appendingPathComponent(part.relativePath)
    }

    public func isCustom(_ part: PromptPart) -> Bool {
        FileManager.default.fileExists(atPath: url(for: part).path)
    }

    public var customParts: [PromptPart] { PromptPart.allCases.filter(isCustom) }

    public var hasCustomPrompt: Bool { !customParts.isEmpty }

    public func source(bundled: URL) -> PromptSource {
        PromptSource(bundled: bundled, overrides: promptDirectory)
    }

    public func builder(bundled: URL) -> PromptBuilder {
        PromptBuilder(source: source(bundled: bundled))
    }

    /// Validated before writing. A part that cannot build is a silently broken app, and the failure
    /// would surface as a mid-dictation error rather than at the moment of editing.
    public func save(_ text: String, for part: PromptPart) throws {
        try Self.validate(text, for: part)
        let destination = url(for: part)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.trimmed.appending("\n").write(to: destination, atomically: true, encoding: .utf8)
    }

    public func restore(_ part: PromptPart) throws {
        guard isCustom(part) else { return }
        try FileManager.default.removeItem(at: url(for: part))
    }

    public func restoreAll() throws {
        for part in customParts { try restore(part) }
    }

    /// Checks that a part will build. Much less than the old whole-file validation had to check:
    /// a part the user has not edited cannot be missing, because the shipped one is still there.
    public static func validate(_ text: String, for part: PromptPart) throws {
        guard !text.trimmed.isEmpty else { throw ValidationError.empty(part) }
        if let placeholder = part.placeholder, !text.contains(placeholder) {
            throw ValidationError.missingPlaceholder(part, placeholder)
        }
    }

    /// Splits a pre-split `PROMPT.md` override into part files, once.
    ///
    /// Only parts that actually differ from the shipped text become overrides. A user who edited
    /// one fidelity clause and left everything else alone should end up with one override, not
    /// twelve — twelve would pin the whole contract at the version they happened to copy, which is
    /// the failure mode the split exists to remove.
    ///
    /// Returns nil when there is nothing to migrate. Never throws for a malformed old file: an
    /// unparseable prompt means the user gets the shipped one, which is the same thing that would
    /// have happened before.
    @discardableResult
    public func migrateLegacyPrompt(bundled: URL) throws -> Migration? {
        guard FileManager.default.fileExists(atPath: legacyURL.path),
            let legacy = LegacyPromptFile(contentsOf: legacyURL), legacy.isLegacyFormat
        else { return nil }

        let shipped = PromptSource(bundled: bundled)
        let found = legacy.parts()
        var migrated: [PromptPart] = []
        for part in PromptPart.allCases {
            guard let body = found[part] else { continue }
            let normalised = body.trimmed
            guard (try? PromptStore.validate(normalised, for: part)) != nil else { continue }
            guard let original = try? shipped.editableText(for: part), original != normalised else {
                continue
            }
            try save(normalised, for: part)
            migrated.append(part)
        }

        let archive = legacyURL.appendingPathExtension("migrated")
        try? FileManager.default.removeItem(at: archive)
        try FileManager.default.moveItem(at: legacyURL, to: archive)
        return Migration(migrated: migrated, archivedAt: archive)
    }
}
