import Foundation

/// Everything captured from the screen for one dictation.
///
/// Field names mirror the channels Typeless uses, because those budgets are field-tested — see
/// `docs/CONTEXT_FORMAT.md`. Every field is optional: a capture that yields nothing is valid and
/// simply produces no context part.
public struct ScreenContext: Sendable, Codable, Equatable {
    /// Foreground application name, e.g. "Xcode".
    public var appName: String?
    /// Focused window title.
    public var windowTitle: String?
    /// Page URL when the focused app is a browser.
    public var browserURL: String?
    /// Accessibility role of the focused element, e.g. "AXTextArea".
    public var role: String?
    public var isEditable: Bool?

    /// Visible text of the focused window. Capped and tail-truncated.
    public var visibleText: String?
    /// Text immediately before the caret. Capped and tail-truncated.
    public var textBeforeCaret: String?
    /// Text immediately after the caret. Capped and head-truncated.
    public var textAfterCaret: String?
    public var selectedText: String?

    /// PNG of the focused window, attached only when the accessibility tree came back thin.
    public var screenshotPNG: Data?

    public init(
        appName: String? = nil,
        windowTitle: String? = nil,
        browserURL: String? = nil,
        role: String? = nil,
        isEditable: Bool? = nil,
        visibleText: String? = nil,
        textBeforeCaret: String? = nil,
        textAfterCaret: String? = nil,
        selectedText: String? = nil,
        screenshotPNG: Data? = nil
    ) {
        self.appName = appName
        self.windowTitle = windowTitle
        self.browserURL = browserURL
        self.role = role
        self.isEditable = isEditable
        self.visibleText = visibleText
        self.textBeforeCaret = textBeforeCaret
        self.textAfterCaret = textAfterCaret
        self.selectedText = selectedText
        self.screenshotPNG = screenshotPNG
    }

    /// Nothing worth sending — no identity, no text, no image.
    public var isEmpty: Bool {
        screenshotPNG == nil
            && [appName, windowTitle, browserURL, visibleText,
                textBeforeCaret, textAfterCaret, selectedText]
            .allSatisfy { ($0 ?? "").trimmed.isEmpty }
    }

    /// True when the accessibility tree yielded too little to rely on, so the screenshot path
    /// should fire. Deliberately a measured threshold rather than a per-app toggle.
    public func isAccessibilityThin(threshold: Int = 300) -> Bool {
        let visible = (visibleText ?? "").trimmed.count
        let caret = (textBeforeCaret ?? "").trimmed.count + (textAfterCaret ?? "").trimmed.count
        return visible + caret < threshold
    }
}

extension String {
    public var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
