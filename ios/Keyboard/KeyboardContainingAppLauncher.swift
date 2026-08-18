import UIKit

/// Opens the containing app from a custom keyboard.
///
/// Keyboard extensions do not support `NSExtensionContext.open`, but the system application
/// responder used by shipping voice keyboards handles the app's registered URL scheme. Keep the
/// selector dynamic so the extension never references the unavailable `UIApplication.shared`.
@MainActor
final class KeyboardContainingAppLauncher {
    private let responderProvider: () -> UIResponder?

    init(responderProvider: @escaping () -> UIResponder?) {
        self.responderProvider = responderProvider
    }

    @discardableResult
    func open(_ url: URL?) -> Bool {
        guard let url else { return false }

        let modernSelector = NSSelectorFromString("openURL:options:completionHandler:")
        let legacySelector = NSSelectorFromString("openURL:")
        var responder = responderProvider()

        while let current = responder {
            if current.responds(to: modernSelector) {
                _ = current.perform(modernSelector, with: url, with: nil)
                return true
            }
            if current.responds(to: legacySelector) {
                _ = current.perform(legacySelector, with: url)
                return true
            }
            responder = current.next
        }
        return false
    }
}
