import Foundation

/// Where a part's text comes from: the shipped `prompt/` directory, or the user's copy of one file
/// in it.
///
/// The override is per part rather than all-or-nothing, which is the point of the split. Someone
/// who tuned `fidelity/light.md` keeps getting shipped updates to `system.md`, and a part they
/// never touched cannot be stale. The old single-file override froze the whole contract at
/// whatever it looked like on the day it was edited — a prompt customised before the summary stage
/// existed had no summary block at all, and the stage failed outright rather than falling back.
public struct PromptSource: Sendable {
    public enum Error: Swift.Error, LocalizedError {
        case partMissing(PromptPart, URL)
        case partEmpty(PromptPart, URL)

        public var errorDescription: String? {
            switch self {
            case .partMissing(let part, let url):
                "The prompt is missing \(part.relativePath) — nothing to send for \(part.id). "
                    + "Looked in \(url.path)."
            case .partEmpty(let part, let url):
                "\(url.path) is empty. A part file is sent in full, so an empty one would send "
                    + "nothing for \(part.id)."
            }
        }
    }

    /// The shipped directory. Always complete; every part resolves here.
    public let bundled: URL
    /// The user's directory, if they have edited anything. Sparse — only edited parts exist.
    public let overrides: URL?

    public init(bundled: URL, overrides: URL? = nil) {
        self.bundled = bundled
        self.overrides = overrides
    }

    /// The file actually in force for a part.
    public func url(for part: PromptPart) -> URL {
        if let custom = overrideURL(for: part),
            FileManager.default.fileExists(atPath: custom.path)
        {
            return custom
        }
        return bundled.appendingPathComponent(part.relativePath)
    }

    /// Where a part's override would live, whether or not it exists.
    public func overrideURL(for part: PromptPart) -> URL? {
        overrides?.appendingPathComponent(part.relativePath)
    }

    public func isOverridden(_ part: PromptPart) -> Bool {
        guard let custom = overrideURL(for: part) else { return false }
        return FileManager.default.fileExists(atPath: custom.path)
    }

    public var overriddenParts: [PromptPart] {
        PromptPart.allCases.filter(isOverridden)
    }

    /// The part's text, exactly as it will be sent.
    ///
    /// Clause parts are joined into one line — see `PromptPart.isClause`. That is the only
    /// transform applied to any part, and it exists because a clause lands inside a numbered list
    /// item in another part.
    public func text(for part: PromptPart) throws -> String {
        let trimmed = try editableText(for: part)
        guard !trimmed.isEmpty else { throw Error.partEmpty(part, url(for: part)) }
        return part.isClause ? trimmed.replacingOccurrences(of: "\n", with: " ") : trimmed
    }

    /// The text as it sits on disk, unjoined — what an editor should show and save.
    ///
    /// Line endings are normalised to LF. Git checks these files out with CRLF on Windows under the
    /// default `autocrlf`, and the four platforms have to send the same bytes for the same contract
    /// or the measurements describe none of them. Cheap here, and it means a part edited on Windows
    /// and one edited on a Mac are the same part.
    public func editableText(for part: PromptPart) throws -> String {
        let url = url(for: part)
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            throw Error.partMissing(part, url)
        }
        return Self.normalisingLineEndings(raw)
    }

    static func normalisingLineEndings(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmed
    }

    /// Walks up from a starting path looking for `prompt/system.md`.
    ///
    /// Matches on a file inside the directory rather than the directory itself, so an unrelated
    /// `prompt/` folder in a parent tree cannot shadow the real one.
    public static func findPromptDirectory(
        startingAt start: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ) -> URL? {
        var directory = start.standardizedFileURL
        for _ in 0..<8 {
            let candidate = directory.appendingPathComponent("prompt")
            if FileManager.default.fileExists(
                atPath: candidate.appendingPathComponent(PromptPart.system.relativePath).path)
            {
                return candidate
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }
        return nil
    }
}

/// Assembles an instruction out of the parts in a `PromptSource`.
///
/// The contract lives in files at the repo root rather than in Swift string literals because it is
/// the actual product, it has to stay identical across platforms, and it is what contributors will
/// want to argue about. Keeping it in files makes changes reviewable as changes to the product
/// rather than as changes to code.
public struct PromptBuilder: Sendable {
    public let source: PromptSource

    public init(source: PromptSource) {
        self.source = source
    }

    /// The shipped directory with no overrides — for measuring the contract as it ships.
    public init(directory: URL) {
        self.init(source: PromptSource(bundled: directory))
    }

    public static func findPromptDirectory(
        startingAt start: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    ) -> URL? {
        PromptSource.findPromptDirectory(startingAt: start)
    }

    public func systemInstruction(fidelity: Fidelity = .default) throws -> String {
        try assemble(.system, filling: .fidelity(fidelity))
    }

    /// The transcription contract with the user's formatting blocks appended, when they have set
    /// any.
    ///
    /// Appended rather than woven into `system.md`, and absent unless asked for, so that a default
    /// install sends the same bytes it sent before this feature existed. That is not tidiness:
    /// every number in `docs/PROMPT.md` describes the default request, and a new clause on every
    /// request would silently invalidate all of them.
    ///
    /// The two blocks are separate parts because they are separately owned. `typography` is the
    /// project's text, editable and restorable like every other part; the sample is the user's own
    /// sentence, dropped into a block that frames it as an example and not as speech.
    public func systemInstruction(
        fidelity: Fidelity = .default,
        script: ChineseScript = .default,
        dictationStyle: DictationStyle = .default,
        customDictationStyle: String = ""
    ) throws -> String {
        var instruction = try systemInstruction(fidelity: fidelity)
        if !script.isDefault {
            instruction += "\n\n" + (try assemble(.typography, filling: .script(script)))
        }
        if let clause = try dictationStyleClause(dictationStyle, custom: customDictationStyle) {
            instruction += "\n\n"
                + (try assemble(
                    .dictationStyleBlock, replacing: ["{{DICTATION_STYLE_RULE}}": clause]))
        }
        return instruction
    }

    /// The clause a dictation style contributes, or nil when it contributes nothing.
    ///
    /// One function for both halves of the control, because the host block — and with it the
    /// "never change a word" rule and the "this is not speech" framing — has to wrap the user's own
    /// text exactly as it wraps a preset. A custom style that bypassed the block would be user text
    /// sitting unframed in a system instruction.
    public func dictationStyleClause(
        _ style: DictationStyle, custom: String
    ) throws -> String? {
        switch style {
        case .spoken:
            return nil
        case .custom:
            let text = Typography.sanitizedSample(custom)
            return text.isEmpty ? nil : text
        default:
            return try source.text(for: .dictationStyle(style))
        }
    }

    /// System instruction for the second-stage rewrite.
    ///
    /// - Parameter custom: the user's own style text, used only by `RewriteStyle.custom`. Ignored
    ///   for the presets, whose clause comes from `prompt/style/`.
    public func rewriteInstruction(style: RewriteStyle, custom: String = "") throws -> String {
        guard style.isRewrite else { return "" }
        let clause = try styleClause(style, custom: custom)
        guard !clause.isEmpty else { return "" }
        return try assemble(.rewrite, replacing: ["{{STYLE_RULE}}": clause])
    }

    /// The style rule alone, for appending to a transcription prompt in single-pass mode.
    ///
    /// A custom style whose text is empty returns empty, and every caller treats that as "no
    /// rewrite" — which is the right answer: a rewrite instruction with a blank style clause is a
    /// request to rewrite in no particular way, and the model would do something.
    public func styleClause(_ style: RewriteStyle, custom: String = "") throws -> String {
        switch style {
        case .verbatim: return ""
        case .custom: return Typography.sanitizedSample(custom)
        default: return try source.text(for: .style(style))
        }
    }

    /// System instruction for the second-stage translation.
    ///
    /// Its own part rather than a rewrite style, on the same reasoning that keeps `summary`
    /// separate: the blocks' rules differ. A rewrite keeps the speaker's language and may reshape
    /// the prose; a translation changes the language and may reshape nothing.
    public func translateInstruction(language: String) throws -> String {
        let target = TranslationTarget.sanitized(language)
        guard !target.isEmpty else { return "" }
        return try assemble(.translate, replacing: ["{{TARGET_LANGUAGE}}": target])
    }

    /// System instruction for the summary stage.
    ///
    /// A separate part from `rewriteInstruction` rather than another style inside it, because the
    /// two have opposite contracts: a rewrite may never drop a fact, and a summary exists to. See
    /// "The summary stage" in `docs/PROMPT.md`.
    public func summaryInstruction(style: SummaryStyle) throws -> String {
        try assemble(.summary, filling: .summaryStyle(style))
    }

    /// The instruction for whichever second stage a mode asks for, or nil when it asks for none.
    ///
    /// One entry point, so a caller cannot route a summary through the rewrite part by picking the
    /// wrong builder method — which is the mistake the two-part split exists to make impossible.
    /// - Parameter customStyle: the user's own rewrite style text, for `RewriteStyle.custom`.
    public func secondStageInstruction(
        for mode: TranscriptMode, customStyle: String = ""
    ) throws -> String? {
        let instruction: String = switch mode {
        case .verbatim: ""
        case .rewrite(let style): try rewriteInstruction(style: style, custom: customStyle)
        case .summary(let style): try summaryInstruction(style: style)
        case .translate(let language): try translateInstruction(language: language)
        }
        // Empty is nil here rather than at four call sites. A custom style with nothing in it, and
        // a translation with no language, both assemble to nothing — and a second stage sent with
        // an empty system instruction is a model asked to do something unspecified to a transcript,
        // which it would.
        return instruction.isEmpty ? nil : instruction
    }

    /// Reads a part without substituting anything into it.
    public func text(for part: PromptPart) throws -> String {
        try source.text(for: part)
    }

    /// Checks that every part resolves and every placeholder is fillable, so a broken prompt is
    /// found at startup rather than mid-dictation.
    public func validate() throws {
        for part in PromptPart.allCases {
            _ = try source.text(for: part)
        }
        _ = try systemInstruction()
    }

    // MARK: - Private

    /// The host is read first, deliberately. A missing `system.md` has to be reported as a missing
    /// `system.md` rather than as a missing fidelity clause, which is what a reordering of these
    /// two lines produces and what the suite asserts against.
    private func assemble(_ host: PromptPart, filling clause: PromptPart) throws -> String {
        let body = try source.text(for: host)
        guard let placeholder = host.placeholder else { return body }
        return body.replacingOccurrences(of: placeholder, with: try source.text(for: clause))
    }

    /// The same substitution, for a placeholder whose value is not another part.
    ///
    /// Only the formatting example uses it. A part file cannot hold that text, because the text is
    /// the user's.
    private func assemble(_ host: PromptPart, replacing values: [String: String]) throws -> String {
        var body = try source.text(for: host)
        for (placeholder, value) in values {
            body = body.replacingOccurrences(of: placeholder, with: value)
        }
        return body
    }
}
