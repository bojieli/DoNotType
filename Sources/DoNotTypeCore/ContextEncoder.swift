import Foundation

/// Turns a `ScreenContext` into request parts, verbatim.
///
/// This type deliberately does no analysis. It does not extract terms, rank candidates, or
/// summarise; it clips to a budget, labels, and orders. Everything it emits is text that was
/// literally on the user's screen. See `CONTEXT_FORMAT.md` for the rationale.
public struct ContextEncoder: Sendable {
    public struct Limits: Sendable, Equatable {
        public var visibleTextChars: Int
        public var beforeCaretChars: Int
        public var afterCaretChars: Int
        /// Below this much accessibility text, the screenshot path is used instead.
        public var thinTextThreshold: Int

        public init(
            visibleTextChars: Int = 10_000,
            beforeCaretChars: Int = 1_000,
            afterCaretChars: Int = 1_000,
            thinTextThreshold: Int = 300
        ) {
            self.visibleTextChars = visibleTextChars
            self.beforeCaretChars = beforeCaretChars
            self.afterCaretChars = afterCaretChars
            self.thinTextThreshold = thinTextThreshold
        }

        public static let `default` = Limits()
    }

    static let header = "===== SCREEN CONTEXT — REFERENCE ONLY, DO NOT TRANSCRIBE ====="

    /// Restates the content rule immediately before the audio, where the system instruction is
    /// thousands of tokens away.
    ///
    /// Deliberately abstract. An earlier version illustrated the rule with the same version
    /// numbers as the test case — "if you hear one point five and the text says 2.5, write 1.5" —
    /// and made things *worse*: substitution went from 11/19 to 15/18. Naming the wrong answer in
    /// the instruction appears to prime it. Examples here must never contain a concrete value that
    /// could be echoed.
    static let footer = """
        ===== END SCREEN CONTEXT =====
        None of the text above was spoken. It is a spelling reference only.
        Numbers, version numbers, dates and names in your output must come from the audio alone,
        even when the text above shows a different value for the same thing.
        The audio that follows is the ONLY thing to transcribe.
        """

    public var limits: Limits

    public init(limits: Limits = .default) {
        self.limits = limits
    }

    /// Context parts only, in order. Empty when there is nothing worth sending.
    ///
    /// The caller appends the audio part; keeping that separate means this function is pure and
    /// trivially testable against a fixture.
    public func encode(_ context: ScreenContext) -> [InputPart] {
        guard !context.isEmpty else { return [] }

        var parts: [InputPart] = []
        var opening = [Self.header]
        opening.append(contentsOf: identityLines(context))
        parts.append(.text(opening.joined(separator: "\n")))

        // The image and the visible text are alternatives, not companions: the screenshot exists
        // for surfaces where the accessibility tree returns nothing useful.
        if let png = context.screenshotPNG {
            parts.append(.image(data: png, mimeType: "image/png"))
        }

        var sections: [String] = []
        if !context.screenshotPNG.isNil || !isThinVisibleText(context) {
            appendSection(
                &sections, title: "VISIBLE TEXT (accessibility)",
                body: TokenBudget.clipKeepingTail(
                    context.visibleText ?? "", maxChars: limits.visibleTextChars))
        }
        appendSection(
            &sections, title: "TEXT BEFORE CARET",
            body: TokenBudget.clipKeepingTail(
                context.textBeforeCaret ?? "", maxChars: limits.beforeCaretChars))
        appendSection(
            &sections, title: "TEXT AFTER CARET",
            body: TokenBudget.clipKeepingHead(
                context.textAfterCaret ?? "", maxChars: limits.afterCaretChars))
        appendSection(&sections, title: "SELECTED TEXT", body: context.selectedText ?? "")

        sections.append(Self.footer)
        parts.append(.text(sections.joined(separator: "\n\n")))
        return parts
    }

    /// Approximate token cost of the context, for budgeting and for the eval report.
    public func estimatedTokens(_ context: ScreenContext) -> Int {
        encode(context).reduce(into: 0) { total, part in
            switch part {
            case .text(let value): total += TokenBudget.estimate(value)
            // A 1024px-long-edge window screenshot tiles to roughly this many tokens.
            case .image: total += 1_300
            case .audio, .remoteAudio: break
            }
        }
    }

    // MARK: - Private

    private func isThinVisibleText(_ context: ScreenContext) -> Bool {
        (context.visibleText ?? "").trimmed.count < limits.thinTextThreshold
    }

    private func identityLines(_ context: ScreenContext) -> [String] {
        var lines: [String] = []
        let app = (context.appName ?? "").trimmed
        let title = (context.windowTitle ?? "").trimmed
        switch (app.isEmpty, title.isEmpty) {
        case (false, false): lines.append("App: \(app) — \(title)")
        case (false, true): lines.append("App: \(app)")
        case (true, false): lines.append("Window: \(title)")
        case (true, true): break
        }
        if let url = context.browserURL?.trimmed, !url.isEmpty {
            lines.append("URL: \(url)")
        }
        if let role = context.role?.trimmed, !role.isEmpty {
            let editable = context.isEditable == true ? " · editable" : ""
            lines.append("Field: \(role)\(editable)")
        }
        return lines
    }

    /// Sections with no body are omitted entirely — an empty labelled header costs tokens and is
    /// a small invitation to fill it in.
    private func appendSection(_ sections: inout [String], title: String, body: String) {
        let trimmed = body.trimmed
        guard !trimmed.isEmpty else { return }
        sections.append("--- \(title) ---\n\(trimmed)")
    }
}

extension Optional {
    fileprivate var isNil: Bool { self == nil }
}
