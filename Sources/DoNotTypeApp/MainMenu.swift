import AppKit

/// The menu bar this app never shows.
///
/// Cut, Copy, Paste, Select All and Undo are not built into a text field on macOS — they are menu
/// items, and `NSApplication` only dispatches ⌘V by walking `mainMenu` for a matching key
/// equivalent. An app that builds its windows in code and never sets a main menu therefore gets a
/// text field you can type into and cannot paste into, which is precisely the wrong half to lose
/// for an API key: the value is 50-odd random characters that arrive on the clipboard from the
/// provider's dashboard and are never typed by hand.
///
/// Nothing here becomes visible. `LSUIElement` apps do not own the menu bar, so activating this
/// one leaves whatever app was in front showing its own menus; the items below exist only so the
/// key equivalents have somewhere to land.
enum MainMenu {
    static func make(appName: String = "DoNotType") -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu(titled: appName, items: [appItems(appName: appName)]))
        main.addItem(submenu(titled: "Edit", items: [editItems()]))
        main.addItem(submenu(titled: "Window", items: [windowItems()]))
        return main
    }

    private static func appItems(appName: String) -> [NSMenuItem] {
        // The status item already offers Quit; this is the same command under the shortcut people
        // reach for once a window of ours is the key window.
        [item("Quit \(appName)", #selector(NSApplication.terminate(_:)), "q")]
    }

    private static func editItems() -> [NSMenuItem] {
        // `undo:` and `redo:` are dispatched through the responder chain but declared on no public
        // AppKit class, so they cannot be written as `#selector(...)`.
        [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ]
    }

    private static func windowItems() -> [NSMenuItem] {
        // Same defect, different key: without a main menu, ⌘W does nothing either, and Settings is
        // a window people open, paste into and want gone.
        [item("Close", #selector(NSWindow.performClose(_:)), "w")]
    }

    // MARK: - Plumbing

    private static func submenu(titled title: String, items: [[NSMenuItem]]) -> NSMenuItem {
        let container = NSMenuItem()
        let menu = NSMenu(title: title)
        items.flatMap { $0 }.forEach(menu.addItem)
        container.submenu = menu
        return container
    }

    /// Deliberately no `target`: a nil target sends the action down the responder chain, so the
    /// field editor of whichever field has focus is what actually handles it. Setting a target
    /// here would route every ⌘V to the same object no matter what the user was editing.
    private static func item(
        _ title: String, _ action: Selector, _ key: String,
        _ modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }
}
