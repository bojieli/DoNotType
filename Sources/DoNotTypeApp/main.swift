import AppKit

// LSUIElement in Info.plist keeps this out of the Dock; the status item is the whole UI.
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
