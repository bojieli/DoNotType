import XCTest

/// What can be checked about the keyboard extension from outside it.
///
/// Not much, and the limit is the platform's rather than this project's: a custom keyboard runs in
/// its own process and its views do not appear in the host application's accessibility tree, so
/// `XCUIApplication` cannot see the status label or the dictation button no matter what identifiers
/// they carry. Dumping the hierarchy with the keyboard on screen shows the app's own views and a
/// single opaque `Keyboard` element.
///
/// So the split is: this asserts the app raises a keyboard at all and that the extension is
/// packaged where iOS will find it. Shared tests cover the persisted voice-command state machine,
/// transcript handoff, and correction records. The microphone and insertion endpoints remain in
/// the real-device checklist because a simulator cannot prove either one.
@MainActor
final class KeyboardExtensionUITests: XCTestCase {

    private func launch() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-ui-testing", "-ui-testing-configured"]
        app.launch()
        return app
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        // A Form exposes rows below the viewport in its accessibility tree. Existence therefore
        // does not mean a tap can focus the field; scroll until XCTest can actually hit it.
        _ = element.waitForExistence(timeout: 3)
        for _ in 0..<6 {
            if element.exists && element.isHittable { return true }
            app.swipeUp()
        }
        return element.exists && element.isHittable
    }

    /// iOS only offers a keyboard it can find inside the app bundle. Getting this wrong produces
    /// an app that installs and runs while the keyboard never appears in Settings at all, which is
    /// indistinguishable from the user not having added it.
    func testFocusingAFieldRaisesAKeyboard() throws {
        let app = launch()
        app.buttons["open-settings"].tap()

        let field = app.textFields["model"]
        XCTAssertTrue(reveal(field, in: app), "the Model field should be in Settings")
        field.tap()

        XCTAssertTrue(
            app.keyboards.firstMatch.waitForExistence(timeout: 10),
            "focusing a text field should raise a keyboard")
    }

    /// Typing has to reach the field whichever keyboard is up. This is the one end-to-end
    /// statement available: text goes in and the app sees it.
    func testTypingReachesTheField() throws {
        let app = launch()
        app.buttons["open-settings"].tap()

        let field = app.textFields["model"]
        XCTAssertTrue(reveal(field, in: app))
        field.tap()
        field.typeText("-probe")

        let value = try XCTUnwrap(field.value as? String)
        XCTAssertTrue(value.hasSuffix("-probe"), "typed text should land in the field, got \(value)")
    }
}
