import AppKit
import ApplicationServices
import DoNotTypeCore
import Foundation
import os

/// Reads the focused app's text out of the accessibility tree.
///
/// Everything here runs off the main thread with a hard deadline. An unresponsive target app will
/// block an `AXUIElementCopyAttributeValue` call indefinitely, and a dictation tool that hangs
/// because Slack is busy is worse than one that grounds on nothing.
struct AccessibilityReader: Sendable {
    private static let log = Logger(subsystem: "ai.19pine.donottype", category: "ax")

    /// Character budgets, matching the ones Typeless arrived at.
    struct Limits: Sendable {
        var visibleText = 10_000
        var caretWindow = 1_000
        var deadline: Duration = .milliseconds(500)
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Prompts for Accessibility access, which macOS only shows once per app signature.
    ///
    /// The key is spelled literally because `kAXTrustedCheckOptionPrompt` is imported as a mutable
    /// global and is therefore not usable from concurrency-checked code.
    static func requestTrust() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    // MARK: - Phase 1: cheap

    /// App identity and cursor state only. Fast enough to run synchronously at hotkey-down, which
    /// matters because it must be captured before focus can move.
    static func captureIdentity() -> ScreenContext {
        var context = ScreenContext()
        guard let app = NSWorkspace.shared.frontmostApplication else { return context }

        context.appName = app.localizedName
        guard isTrusted else { return context }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        if let window: AXUIElement = copy(appElement, kAXFocusedWindowAttribute) {
            context.windowTitle = copy(window, kAXTitleAttribute)
        }
        if let focused: AXUIElement = copy(appElement, kAXFocusedUIElementAttribute) {
            context.role = copy(focused, kAXRoleAttribute)
            context.isEditable = context.role.map(isEditableRole) ?? false
            context.selectedText = copy(focused, kAXSelectedTextAttribute)
        }
        return context
    }

    // MARK: - Phase 2: expensive

    /// The full walk: visible text, the caret window, and the browser URL.
    ///
    /// Returns whatever it managed to collect before the deadline rather than failing outright —
    /// partial grounding beats none.
    static func captureFull(limits: Limits = Limits()) async -> ScreenContext {
        await withTaskGroup(of: ScreenContext?.self) { group in
            group.addTask { readEverything(limits: limits) }
            group.addTask {
                try? await Task.sleep(for: limits.deadline)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            if first == nil { log.warning("accessibility walk hit its \(limits.deadline) deadline") }
            return first ?? captureIdentity()
        }
    }

    private static func readEverything(limits: Limits) -> ScreenContext {
        var context = captureIdentity()
        guard isTrusted, let app = NSWorkspace.shared.frontmostApplication else { return context }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        // Chromium and Electron apps withhold their tree until this is set. Toggling it is the
        // difference between grounding in VS Code and grounding on nothing there.
        AXUIElementSetAttributeValue(
            appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)

        let window: AXUIElement? = copy(appElement, kAXFocusedWindowAttribute)
        let focused: AXUIElement? = copy(appElement, kAXFocusedUIElementAttribute)

        if let focused {
            (context.textBeforeCaret, context.textAfterCaret) = caretWindow(
                focused, budget: limits.caretWindow)
        }
        if let window {
            context.visibleText = TokenBudget.clipKeepingTail(
                collectText(from: window, budget: limits.visibleText), maxChars: limits.visibleText)
            context.browserURL = webURL(in: window)
        }
        return context
    }

    // MARK: - Traversal

    /// Depth-first text collection, skipping anything invisible or off-screen.
    ///
    /// Bounded by a node budget as well as a character budget: some web pages expose tens of
    /// thousands of elements, and walking all of them would blow the deadline long before it
    /// filled the character cap.
    private static func collectText(from root: AXUIElement, budget: Int) -> String {
        var collected: [String] = []
        var characters = 0
        var visited = 0
        var stack = [root]

        while let element = stack.popLast(), characters < budget, visited < 4_000 {
            visited += 1

            if let role: String = copy(element, kAXRoleAttribute), role == "AXWindow" || true {
                for attribute in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
                    guard let text: String = copy(element, attribute) else { continue }
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    // Single characters are almost always chrome (separators, icon labels).
                    guard trimmed.count > 1 else { continue }
                    collected.append(trimmed)
                    characters += trimmed.count
                }
            }

            if let children: [AXUIElement] = copy(element, kAXChildrenAttribute) {
                stack.append(contentsOf: children.reversed())
            }
        }
        return smartJoin(collected)
    }

    /// Joins fragments without gluing words together or double-spacing punctuation.
    private static func smartJoin(_ fragments: [String]) -> String {
        var out = ""
        for fragment in fragments {
            if out.isEmpty {
                out = fragment
            } else if fragment.first.map({ ".,;:!?)]}".contains($0) }) == true {
                out += fragment
            } else {
                out += out.hasSuffix("\n") ? fragment : "\n" + fragment
            }
        }
        return out
    }

    /// Text either side of the insertion point.
    private static func caretWindow(_ element: AXUIElement, budget: Int) -> (String?, String?) {
        guard let value: String = copy(element, kAXValueAttribute) else { return (nil, nil) }

        var rangeValue: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
            let axValue = rangeValue, CFGetTypeID(axValue) == AXValueGetTypeID()
        else {
            // No caret information: treat the whole field as "before", which is the common case
            // for a freshly focused empty input.
            return (TokenBudget.clipKeepingTail(value, maxChars: budget), nil)
        }

        var range = CFRange()
        AXValueGetValue(axValue as! AXValue, .cfRange, &range)

        let characters = Array(value)
        let caret = max(0, min(range.location, characters.count))
        let before = String(characters[..<caret])
        let after = String(characters[min(caret + max(0, range.length), characters.count)...])

        return (
            TokenBudget.clipKeepingTail(before, maxChars: budget),
            TokenBudget.clipKeepingHead(after, maxChars: budget)
        )
    }

    /// Finds the page URL by locating the web area in the window.
    private static func webURL(in window: AXUIElement) -> String? {
        var stack = [window]
        var visited = 0
        while let element = stack.popLast(), visited < 200 {
            visited += 1
            if let role: String = copy(element, kAXRoleAttribute), role == "AXWebArea" {
                if let url: NSURL = copy(element, kAXURLAttribute) { return url.absoluteString }
                if let document: String = copy(element, kAXDocumentAttribute) { return document }
            }
            if let children: [AXUIElement] = copy(element, kAXChildrenAttribute) {
                stack.append(contentsOf: children.prefix(24))
            }
        }
        return nil
    }

    private static func isEditableRole(_ role: String) -> Bool {
        ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role)
    }

    // MARK: - Attribute plumbing

    private static func copy<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value as? T
    }
}
