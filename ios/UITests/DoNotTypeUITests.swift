import XCTest

/// Drives the shipped app in a simulator.
///
/// The unit tests cover the core; nothing covered the app. `xcodebuild build` succeeded for the
/// whole life of the project while producing a bundle with no `CFBundleIdentifier` and no
/// `CFBundleExecutable` -- an app that compiled, linked, passed CI and could not be installed on
/// anything. A test that launches it catches that class of failure on the first run.
/// `@MainActor` on the whole class because every `XCUIApplication` member is main-actor isolated,
/// and the CI toolchain compiles this at Swift 6 strictness where that is an error rather than a
/// warning. Setting `continueAfterFailure` in `launch()` rather than overriding `setUp()` keeps
/// the isolation of the override from having to match the nonisolated superclass declaration.
@MainActor
final class DoNotTypeUITests: XCTestCase {

    private func launch() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-ui-testing"]
        app.launch()
        return app
    }

    /// Settings is a long form and a `List` only builds the rows it is showing, so anything below
    /// the fold does not exist until it is scrolled to.
    ///
    /// It has to wait before each swipe, not just check. Checking first and swiping immediately
    /// scrolls straight past a row that simply had not been built yet, and because the list is
    /// lazy the row is then gone behind us and never comes back -- which is how this passed on a
    /// fast machine and failed on a CI runner looking for the very first section on screen.
    @discardableResult
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        if element.waitForExistence(timeout: 3) { return true }
        for _ in 0..<8 {
            app.swipeUp()
            if element.waitForExistence(timeout: 1) { return true }
        }
        return false
    }

    /// The one that would have caught the missing plist keys: installing and launching is the
    /// assertion.
    func testLaunchesToTheDictationScreen() {
        let app = launch()
        XCTAssertTrue(app.navigationBars["DoNotType"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["record"].exists, "the dictation button should be on screen")
        XCTAssertTrue(app.staticTexts["Tap to dictate, or hold to talk"].exists)
    }

    /// Asserts on the controls rather than on the section headers above them.
    ///
    /// Headers were the obvious thing to look for and the wrong one: how a `Section` header is
    /// exposed to the accessibility tree is the system's business and it varies by iOS version,
    /// so the same assertion passed on one simulator and could not find the first section on
    /// another. Identifiers the app sets itself do not move, and a header nobody can reach is
    /// less of a problem than a control nobody can reach anyway.
    func testSettingsExposesEveryControl() {
        let app = launch()
        app.buttons["open-settings"].tap()

        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        for control in ["api-key", "model", "fidelity", "retention", "keep-audio", "open-prompt"] {
            XCTAssertTrue(
                reveal(app.descendants(matching: .any)[control].firstMatch, in: app),
                "\(control) should be reachable in Settings")
        }
    }

    /// Typing a key and leaving the screen has to persist it. This is the setting without which
    /// the app cannot do anything at all, so "it looked like it saved" is not good enough.
    func testAPIKeySurvivesLeavingSettings() {
        let app = launch()
        app.buttons["open-settings"].tap()

        let field = app.secureTextFields["api-key"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("test-key-12345")

        app.navigationBars["Settings"].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["DoNotType"].waitForExistence(timeout: 5))

        app.buttons["open-settings"].tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "••••••••••••••",
                       "the key should still be there after leaving and coming back")
    }

    func testHistoryOpensAndIsEmptyOnAFreshInstall() {
        let app = launch()
        app.buttons["open-history"].tap()
        XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 5))
    }

    /// The prompt is the product. Being able to read it in the app is the claim the README makes,
    /// so it has to actually open and contain the contract.
    func testPromptEditorOpensWithTheShippedContract() {
        let app = launch()
        app.buttons["open-settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))

        let prompt = app.descendants(matching: .any)["open-prompt"].firstMatch
        XCTAssertTrue(reveal(prompt, in: app), "the prompt row should be reachable")
        prompt.tap()

        let editor = app.textViews["prompt-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        let text = (editor.value as? String) ?? ""
        XCTAssertTrue(
            text.contains("SPELLING"),
            "the editor should be showing the shipped PROMPT.md, not an empty box")
    }

    /// Changing fidelity has to stick: it is the setting that decides whether the app rewrites
    /// you, which is the whole argument the project makes.
    func testFidelitySelectionPersists() {
        let app = launch()
        app.buttons["open-settings"].tap()

        let picker = app.buttons["fidelity"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.tap()
        app.buttons["Raw — every um and false start"].tap()

        app.navigationBars["Settings"].buttons.firstMatch.tap()
        app.buttons["open-settings"].tap()
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertTrue(
            picker.label.contains("Raw"),
            "fidelity should still read Raw, was \(picker.label)")
    }
}
