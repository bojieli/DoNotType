import AppKit
import ApplicationServices
import DoNotTypeCore
import Foundation

/// Reads the focused app's text out of the accessibility tree.
///
/// Everything here runs off the main thread with a hard deadline and a native per-message timeout.
/// A dictation tool that hangs because a target app is unresponsive is worse than one that grounds
/// on nothing.
struct AccessibilityReader: Sendable {
    private static let log = Log("ax")

    /// AX calls are synchronous IPC into another process. The task-level deadline below limits a
    /// walk, while this native timeout bounds the one call that may already be in progress when
    /// cancellation arrives. Apple applies a system-wide element's timeout to this whole process.
    private static let messagingTimeoutConfigured: Void = {
        let error = AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.1)
        if error != .success {
            log.warning("could not bound accessibility IPC", ["error": "\(error.rawValue)"])
        }
    }()

    /// Character budgets, matching the ones Typeless arrived at.
    struct Limits: Sendable {
        var visibleText = 10_000
        var caretWindow = 1_000
        var deadline: Duration = .milliseconds(500)
    }

    /// Enough of the focused field to recognise an edit to text the app just inserted. Locations
    /// are UTF-16 offsets because that is what the macOS accessibility API reports.
    struct FocusedTextSnapshot: Sendable, Equatable {
        let pid: pid_t
        /// Stable identity for the focused accessibility object. A process can have several text
        /// fields with similar contents; correction learning must not follow focus into another.
        let elementToken: UInt
        let value: String
        let selectionLocation: Int
        let selectionLength: Int
    }

    /// The exact focused editable element, without reading any of its text.
    struct FocusedElementIdentity: Sendable, Equatable {
        let pid: pid_t
        let elementToken: UInt
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Prompts for Accessibility access, which macOS only shows once per app signature.
    ///
    /// The key is spelled literally because `kAXTrustedCheckOptionPrompt` is imported as a mutable
    /// global and is therefore not usable from concurrency-checked code.
    static func requestTrust() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    /// Cheap enough to take at hotkey-down and again after insertion. Finish-and-send compares the
    /// two so a delayed Return cannot be delivered to a different field in the same application.
    static func focusedElementIdentity() -> FocusedElementIdentity? {
        guard isTrusted, let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let focused: AXUIElement = copy(appElement, kAXFocusedUIElementAttribute),
            let role: String = copy(focused, kAXRoleAttribute), isEditableRole(role),
            !isSecure(focused)
        else { return nil }
        return FocusedElementIdentity(pid: app.processIdentifier, elementToken: CFHash(focused))
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
            if !isSecure(focused) {
                context.selectedText = copy(focused, kAXSelectedTextAttribute)
            }
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
            // Only when the sleep genuinely won the race. A cancelled walk — the dictation was
            // abandoned, or it was too short to send — also lands here with a nil result, and
            // reporting that as a deadline sent anyone reading the log after a failed dictation
            // looking at accessibility, which was working the whole time.
            if first == nil, !Task.isCancelled {
                log.warning("accessibility walk hit its \(limits.deadline) deadline")
            }
            return first ?? captureIdentity()
        }
    }

    /// Reads only the focused editable value, for optional dictionary learning.
    ///
    /// This remains separate from screen grounding: it runs only after insertion, keeps no field
    /// text, and returns nothing unless the focused element exposes a collapsed caret.
    static func focusedTextSnapshot(deadline: Duration = .milliseconds(300)) async
        -> FocusedTextSnapshot?
    {
        await withTaskGroup(of: FocusedTextSnapshot?.self) { group in
            group.addTask { readFocusedTextSnapshot() }
            group.addTask {
                try? await Task.sleep(for: deadline)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private static func readFocusedTextSnapshot() -> FocusedTextSnapshot? {
        guard isTrusted, let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let focused: AXUIElement = copy(appElement, kAXFocusedUIElementAttribute),
            let role: String = copy(focused, kAXRoleAttribute), isEditableRole(role),
            !isSecure(focused),
            let value: String = copy(focused, kAXValueAttribute)
        else { return nil }

        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focused, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
            let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID()
        else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &range), range.location >= 0,
            range.length >= 0
        else { return nil }
        return FocusedTextSnapshot(
            pid: app.processIdentifier, elementToken: CFHash(focused), value: value,
            selectionLocation: range.location, selectionLength: range.length)
    }

    private static func readEverything(limits: Limits) -> ScreenContext {
        var context = captureIdentity()
        guard !Task.isCancelled, isTrusted,
            let app = NSWorkspace.shared.frontmostApplication
        else { return context }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        // Chromium and Electron apps withhold their tree until this is set. Toggling it is the
        // difference between grounding in VS Code and grounding on nothing there.
        if !Task.isCancelled {
            AXUIElementSetAttributeValue(
                appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }

        let window: AXUIElement? = copy(appElement, kAXFocusedWindowAttribute)
        let focused: AXUIElement? = copy(appElement, kAXFocusedUIElementAttribute)

        // Dictation itself still works in a password field, but the login screen is not grounding
        // material and the delayed finish-and-send identity above deliberately refuses the field.
        if let focused, isSecure(focused) { return context }
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

        while !Task.isCancelled, let element = stack.popLast(), characters < budget,
            visited < 4_000
        {
            visited += 1

            let hidden: Bool = copy(element, kAXHiddenAttribute) ?? false
            // Treat a secure control as an opaque subtree. Some custom password widgets expose
            // their rendered characters through descendants even when the parent is protected.
            if hidden || isSecure(element) { continue }
            for attribute in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
                guard let text: String = copy(element, attribute) else { continue }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                // Single characters are almost always chrome (separators, icon labels).
                guard trimmed.count > 1 else { continue }
                collected.append(trimmed)
                characters += trimmed.count
            }

            let children: [AXUIElement]? = copy(element, kAXVisibleChildrenAttribute)
                ?? copy(element, kAXChildrenAttribute)
            if let children {
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
        guard !isSecure(element) else { return (nil, nil) }
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
        guard AXValueGetValue(axValue as! AXValue, .cfRange, &range) else {
            return (TokenBudget.clipKeepingTail(value, maxChars: budget), nil)
        }

        // AX ranges are CFRange/UTF-16 offsets. Applying them to Swift Character indices shifts the
        // caret after emoji and other surrogate pairs, grounding on the wrong side of the cursor.
        let characters = value as NSString
        let caret = max(0, min(range.location, characters.length))
        let selectionEnd = max(caret, min(caret + max(0, range.length), characters.length))
        let before = characters.substring(to: caret)
        let after = characters.substring(from: selectionEnd)

        return (
            TokenBudget.clipKeepingTail(before, maxChars: budget),
            TokenBudget.clipKeepingHead(after, maxChars: budget)
        )
    }

    /// Finds the page URL by locating the web area in the window.
    private static func webURL(in window: AXUIElement) -> String? {
        var stack = [window]
        var visited = 0
        while !Task.isCancelled, let element = stack.popLast(), visited < 200 {
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

    /// Password fields are insertion targets, not context sources or correction-learning inputs.
    private static func isSecure(_ element: AXUIElement) -> Bool {
        let subrole: String? = copy(element, kAXSubroleAttribute)
        return subrole == (kAXSecureTextFieldSubrole as String)
    }

    // MARK: - Attribute plumbing

    private static func copy<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        _ = messagingTimeoutConfigured
        guard !Task.isCancelled else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value as? T
    }
}
