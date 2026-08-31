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
    /// One of the named starting points for the dictation example.
    ///
    /// Reaches the model the long way round: a preset's text is copied into the user's example box
    /// and it is the *box* that is substituted into `dictationStyleBlock`. So it is still a clause
    /// — one line, framed by the same host — but the user reads and may edit it in between, which
    /// is the whole point of the control.
    case dictationPreset(DictationPreset)
    /// How the transcript is written down. Appended to the transcription contract, and only when
    /// the user has asked for a script — so the shipped default request is unchanged by its
    /// existence, and the measured numbers in `docs/PROMPT.md` still describe it.
    case typography
    /// One of the script clauses, substituted into `typography`. Never `.spoken`, which is the
    /// shipped contract's own rule rather than an instruction, and so has no file.
    case script(ChineseScript)
    /// The user's own formatting example, appended when they have supplied one. Its placeholder is
    /// filled with their text rather than with another part.
    case dictationStyleBlock
    /// The second-stage translation block. Separate from `rewrite` for the same reason `summary`
    /// is: their rules differ. A rewrite keeps the speaker's language and may reshape the prose; a
    /// translation changes the language and may not reshape anything.
    case translate

    /// Every part that has a file, in the order a settings list should show them.
    public static let allCases: [PromptPart] =
        [.system, .rewrite, .summary, .translate, .typography, .dictationStyleBlock]
        + Fidelity.allCases.map(PromptPart.fidelity)
        + RewriteStyle.allCases.filter(\.hasClauseFile).map(PromptPart.style)
        + DictationPreset.allCases.map(PromptPart.dictationPreset)
        + SummaryStyle.allCases.map(PromptPart.summaryStyle)
        + ChineseScript.allCases.filter { !$0.isDefault }.map(PromptPart.script)

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
        case .translate: "translate.md"
        case .dictationPreset(let preset): "dictation-style/\(preset.rawValue).md"
        case .typography: "typography.md"
        case .script(let script): "script/\(script.rawValue).md"
        case .dictationStyleBlock: "dictation-style.md"
        }
    }

    /// The one token substituted into this part, or nil for the clause parts, which are the
    /// things substituted *in*.
    public var placeholder: String? {
        switch self {
        case .system: "{{FIDELITY_RULE}}"
        case .rewrite: "{{STYLE_RULE}}"
        case .summary: "{{SUMMARY_RULE}}"
        case .translate: "{{TARGET_LANGUAGE}}"
        case .typography: "{{SCRIPT_RULE}}"
        case .dictationStyleBlock: "{{DICTATION_STYLE_RULE}}"
        case .fidelity, .style, .summaryStyle, .script, .dictationPreset: nil
        }
    }

    /// Whether this part is substituted into another part.
    ///
    /// The one transform in the whole loader: a clause is written as a wrapped paragraph and
    /// joined into a single line on load, so source wrapping never changes the instruction.
    ///
    /// Stated per case rather than derived from `placeholder == nil`, which is what it used to be.
    /// `sample` broke that shortcut: it is a block with a placeholder that no clause file fills,
    /// because what goes in there is the user's own text.
    public var isClause: Bool {
        switch self {
        case .system, .rewrite, .summary, .translate, .typography, .dictationStyleBlock: false
        case .fidelity, .style, .summaryStyle, .script, .dictationPreset: true
        }
    }

    /// The part a clause is substituted into.
    public var host: PromptPart? {
        switch self {
        case .system, .rewrite, .summary, .translate, .typography, .dictationStyleBlock: nil
        case .fidelity: .system
        case .style: .rewrite
        case .summaryStyle: .summary
        case .script: .typography
        case .dictationPreset: .dictationStyleBlock
        }
    }

    // MARK: - Presentation

    /// Heading a settings list groups this part under.
    public var group: String {
        switch self {
        case .system, .rewrite, .summary, .translate, .typography, .dictationStyleBlock: "Blocks"
        case .fidelity: "Fidelity"
        case .style: "Rewrite styles"
        case .summaryStyle: "Summary styles"
        case .script: "Chinese script"
        case .dictationPreset: "Example presets"
        }
    }

    public var label: String {
        switch self {
        case .system: "Transcription"
        case .rewrite: "Rewrite"
        case .summary: "Summary"
        case .translate: "Translate"
        case .typography: "Formatting"
        case .dictationStyleBlock: "Dictation style"
        case .fidelity(let fidelity): fidelity.rawValue
        case .style(let style): style.rawValue
        case .summaryStyle(let style): style.rawValue
        case .script(let script): script.rawValue
        case .dictationPreset(let preset): preset.rawValue
        }
    }

    /// One line on what this part does, for the editor that has room to say so.
    public var summaryLine: String {
        switch self {
        case .system: "Sent on every request. Must contain {{FIDELITY_RULE}}."
        case .rewrite: "Sent only when a rewrite style is chosen."
        case .summary: "Sent only when a summary style is chosen."
        case .translate:
            "Sent only when a target language is set. Must contain {{TARGET_LANGUAGE}}."
        case .typography: "Sent only when a Chinese script is chosen. Must contain {{SCRIPT_RULE}}."
        case .dictationStyleBlock:
            "Sent only when the example box has something in it. "
                + "Must contain {{DICTATION_STYLE_RULE}}."
        case .fidelity: "Substituted into the transcription block."
        case .style: "Substituted into the rewrite block."
        case .summaryStyle: "Substituted into the summary block."
        case .script: "Substituted into the formatting block."
        case .dictationPreset:
            "Filled into the example box when its button is pressed. Not sent on its own."
        }
    }

    /// `system`, `fidelity:light`, `style:formal` — what the CLI accepts and an error names.
    public var id: String {
        switch self {
        case .system: "system"
        case .rewrite: "rewrite"
        case .summary: "summary"
        case .translate: "translate"
        case .typography: "typography"
        case .dictationStyleBlock: "dictation-style"
        case .fidelity(let fidelity): "fidelity:\(fidelity.rawValue)"
        case .style(let style): "style:\(style.rawValue)"
        case .summaryStyle(let style): "summary-style:\(style.rawValue)"
        case .script(let script): "script:\(script.rawValue)"
        case .dictationPreset(let preset): "dictation-style:\(preset.rawValue)"
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
        case ("translate", nil): self = .translate
        case ("typography", nil): self = .typography
        case ("sample", nil), ("dictation-style", nil): self = .dictationStyleBlock
        case ("dictation-style", let name?):
            guard let value = DictationPreset(rawValue: name) else { return nil }
            self = .dictationPreset(value)
        case ("script", let name?):
            guard let value = ChineseScript(rawValue: name), !value.isDefault else { return nil }
            self = .script(value)
        case ("fidelity", let name?):
            guard let value = Fidelity(rawValue: name) else { return nil }
            self = .fidelity(value)
        case ("style", let name?):
            guard let value = RewriteStyle(rawValue: name), value.hasClauseFile else { return nil }
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
