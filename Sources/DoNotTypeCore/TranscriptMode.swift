import Foundation

/// What the user gets back, once the transcript exists.
///
/// The ordering matters and is the project's whole position in one type. Transcription happens
/// first and produces the verbatim text; everything else is a *second* stage over text that has
/// already been stored. There is deliberately no mode that transcribes and summarises in one
/// request, because that request has no verbatim output to keep — and "what did I actually say"
/// stops being answerable the moment such a mode exists.
///
/// `verbatim` is not a degraded `rewrite`. It is the product; the other two are conveniences built
/// on top of it.
public enum TranscriptMode: Sendable, Equatable, Codable, Hashable {
    /// Word for word, at the requested fidelity. One request, no second model pass.
    case verbatim
    /// Verbatim, then rewritten in a style that must preserve every fact. See `RewriteStyle`.
    case rewrite(RewriteStyle)
    /// Verbatim, then summarised — the one stage allowed to discard content. See `SummaryStyle`.
    case summary(SummaryStyle)

    public static let `default`: TranscriptMode = .verbatim

    /// Every mode a picker should offer, with the styles expanded.
    public static var allChoices: [TranscriptMode] {
        [.verbatim]
            + RewriteStyle.allCases.filter(\.isRewrite).map(TranscriptMode.rewrite)
            + SummaryStyle.allCases.map(TranscriptMode.summary)
    }

    /// Whether a second, text-only model request is needed. False only for `verbatim`.
    ///
    /// This is also the question "can a speech recognition backend do this?" — a recogniser has no
    /// text input at all, so anything true here needs a language model somewhere in the chain.
    public var needsSecondPass: Bool {
        switch self {
        case .verbatim: false
        case .rewrite, .summary: true
        }
    }

    /// `verbatim`, `rewrite:formal`, `summary:actions` — what the CLI accepts and what a history
    /// row records.
    public var rawValue: String {
        switch self {
        case .verbatim: "verbatim"
        case .rewrite(let style): "rewrite:\(style.rawValue)"
        case .summary(let style): "summary:\(style.rawValue)"
        }
    }

    /// Parses the CLI spelling. `rewrite` and `summary` without a style take that stage's default,
    /// so `--mode summary` is a complete instruction rather than a validation error.
    public init?(rawValue: String) {
        let parts = rawValue.trimmed.lowercased().split(separator: ":", maxSplits: 1)
        guard let head = parts.first else { return nil }
        // An empty style is no style: `--mode rewrite:` is a colon someone typed and did not
        // finish, and it means the same as `--mode rewrite`. All three platforms agree on this
        // because they used to disagree — see the parity table in the tests.
        let tail = parts.count > 1 && !parts[1].isEmpty ? String(parts[1]) : nil

        switch head {
        case "verbatim", "raw", "transcribe", "none":
            self = .verbatim
        case "rewrite":
            guard let tail else {
                self = .rewrite(.casual)
                return
            }
            guard let style = RewriteStyle(rawValue: tail), style.isRewrite else { return nil }
            self = .rewrite(style)
        case "summary", "summarise", "summarize":
            guard let tail else {
                self = .summary(.default)
                return
            }
            guard let style = SummaryStyle(rawValue: tail) else { return nil }
            self = .summary(style)
        default:
            return nil
        }
    }

    public var label: String {
        switch self {
        case .verbatim: "Verbatim — word for word"
        case .rewrite(let style): "Rewrite — \(style.label)"
        case .summary(let style): "Summary — \(style.label)"
        }
    }

    /// What to show while the second request is in flight.
    ///
    /// The mode's own word rather than "Working…". Somebody who chose a summary is waiting for a
    /// summary, and a label that says so is the difference between a wait that makes sense and one
    /// that looks like the app has stalled after already getting the words — which is what it looks
    /// like, because the transcript exists by then and nothing on screen is moving.
    ///
    /// Here rather than in each interface because there are five of them, and a summary that is
    /// called one thing on a phone and another on a laptop is the kind of drift nobody notices
    /// until they are looking at both.
    public var progressLabel: String {
        switch self {
        case .verbatim: "Finishing…"
        case .rewrite(let style):
            switch style {
            case .verbatim: "Finishing…"
            case .formal: "Rewriting…"
            case .concise: "Tightening…"
            case .casual: "Loosening…"
            }
        case .summary(let style):
            switch style {
            case .brief: "Summarising…"
            case .bullets: "Summarising into bullets…"
            case .actions: "Picking out the actions…"
            }
        }
    }

    /// The `RewriteStyle` this mode applied, for the history row that already has that column.
    /// Nil for verbatim and for summaries, which are not a rewrite style and must not be recorded
    /// as one.
    public var rewriteStyle: RewriteStyle? {
        if case .rewrite(let style) = self { return style }
        return nil
    }

    /// Every accepted spelling, for a `--help` string that lists them rather than describing them.
    public static var acceptedSpellings: [String] {
        ["verbatim"]
            + RewriteStyle.allCases.filter(\.isRewrite).map { "rewrite:\($0.rawValue)" }
            + SummaryStyle.allCases.map { "summary:\($0.rawValue)" }
    }
}

/// The shape of a summary.
///
/// Summarising is the one thing this codebase does that is *supposed* to lose content, which is why
/// it is not a `RewriteStyle`. Rule 1 of the rewrite block — never remove a fact — is the rule this
/// project exists to enforce, and a summary style living alongside `formal` and `concise` would
/// mean one entry in that list quietly exempt from it. It gets its own prompt block, its own
/// instruction, and its own place in the type system so no caller can reach it by accident.
///
/// The verbatim transcript is stored either way. A summary you cannot expand back into the words
/// that produced it is the failure mode this app was built against, one level up.
public enum SummaryStyle: String, CaseIterable, Sendable, Codable, Hashable {
    /// A short paragraph. What you want for a voice memo.
    case brief
    /// Key points, one per line. What you want for a meeting.
    case bullets
    /// Decisions and next steps only, with the owner when one was named.
    case actions

    public static let `default`: SummaryStyle = .brief

    public var label: String {
        switch self {
        case .brief: "Brief — a short paragraph"
        case .bullets: "Bullets — the key points"
        case .actions: "Actions — decisions and next steps"
        }
    }

    /// Key under `### summary: <name>` in PROMPT.md.
    var promptSection: String { "summary: \(rawValue)" }
}
