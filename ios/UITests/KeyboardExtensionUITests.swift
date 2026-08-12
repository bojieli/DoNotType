import XCTest

/// What can be checked about the keyboard extension from outside it.
///
/// Not much, and the limit is the platform's rather than this project's: a custom keyboard runs in
/// its own process and its views do not appear in the host application's accessibility tree, so
/// `XCUIApplication` cannot see the status label or the transcript list no matter what identifiers
/// they carry. Dumping the hierarchy with the keyboard on screen shows the app's own views and a
/// single opaque `Keyboard` element.
///
/// So the split is: this asserts the app raises a keyboard at all and that the extension is
/// packaged where iOS will find it, and `SharedTests/TranscriptStoreTests` covers what the
/// extension actually *does* — read the container, insert one entry, mark it used. That is where
/// the risk is anyway. The drawing is a table view; the bridge is the part that can silently stop
/// working.
@MainActor
final class KeyboardExtensionUITests: XCTestCase {

    /// iOS only offers a keyboard it can find inside the app bundle. Getting this wrong produces
    /// an app that installs and runs while the keyboard never appears in Settings at all, which is
    /// indistinguishable from the user not having added it.
    func testFocusingAFieldRaisesAKeyboard() throws {
        let app = XCUIApplication()
        app.launch()
        app.buttons["open-settings"].tap()

        let field = app.textFields["model"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the Model field should be in Settings")
        field.tap()

        XCTAssertTrue(
            app.keyboards.firstMatch.waitForExistence(timeout: 10),
            "focusing a text field should raise a keyboard")
    }

    /// Typing has to reach the field whichever keyboard is up. This is the one end-to-end
    /// statement available: text goes in and the app sees it.
    func testTypingReachesTheField() throws {
        let app = XCUIApplication()
        app.launch()
        app.buttons["open-settings"].tap()

        let field = app.textFields["model"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("-probe")

        let value = try XCTUnwrap(field.value as? String)
        XCTAssertTrue(value.hasSuffix("-probe"), "typed text should land in the field, got \(value)")
    }
}
