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

    private func launch(arguments: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-ui-testing", "-ui-testing-configured"] + arguments
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
        if element.waitForExistence(timeout: 3), isInsideViewport(element, in: app) { return true }
        for _ in 0..<8 {
            app.swipeUp()
            if element.waitForExistence(timeout: 1), isInsideViewport(element, in: app) {
                return true
            }
        }
        return false
    }

    /// `exists` is not enough for a lazy Form: SwiftUI exposes rows just outside the viewport.
    /// Tapping one of those can log a synthesized event without activating its NavigationLink.
    /// Reading `isHittable` is itself an XCTest failure when a lazy row has no activation point,
    /// so use its frame and keep the top/bottom bars out of the actionable viewport.
    private func isInsideViewport(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        let frame = element.frame
        guard !frame.isNull, !frame.isInfinite, frame.width > 0, frame.height > 0 else {
            return false
        }
        return app.frame.insetBy(dx: 1, dy: 80).intersects(frame)
    }

    /// The one that would have caught the missing plist keys: installing and launching is the
    /// assertion.
    func testLaunchesToTheDictationScreen() {
        let app = launch()
        XCTAssertTrue(app.navigationBars["DoNotType"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["record"].exists, "the dictation button should be on screen")
        XCTAssertTrue(app.staticTexts["Tap to dictate, or hold to talk"].exists)
    }

    /// A rejected silent recording must end with an explanation, not the ordinary idle prompt.
    /// The button remains live because this is a harmless no-op rather than an error state.
    func testNoSpeechOutcomeIsVisibleAndImmediatelyRetryable() {
        let app = launch(arguments: ["-ui-testing-no-speech-notice"])
        let notice = app.staticTexts["No speech detected — recording wasn’t sent"]

        XCTAssertTrue(notice.waitForExistence(timeout: 10))
        let record = app.buttons["record"]
        XCTAssertTrue(record.exists)
        XCTAssertTrue(record.isEnabled, "no speech should not disable the next dictation")
    }

    func testAStalledTranscriptionCanBeCancelled() {
        let app = launch(arguments: ["-ui-testing-transcribing-state"])
        let cancel = app.buttons["cancel-transcription"]

        XCTAssertTrue(cancel.waitForExistence(timeout: 10))
        cancel.tap()

        XCTAssertTrue(app.staticTexts["Cancelled"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["record"].isEnabled)
    }

    /// iOS 26.4 and later can withhold the keyboard host's bundle ID. The cold-launch surface must
    /// not promise an automatic return that cannot happen; it must explain both manual routes and
    /// make clear that leaving DoNotType does not stop capture.
    func testColdKeyboardLaunchExplainsManualReturnWithoutStoppingDictation() {
        let app = launch(arguments: ["-ui-testing-keyboard-return-state"])
        let instructions = app.descendants(matching: .any)["keyboard-return-instructions"]

        XCTAssertTrue(instructions.waitForExistence(timeout: 10))
        XCTAssertTrue(instructions.label.contains("Swipe across the bottom edge"))
        XCTAssertTrue(instructions.label.contains("open it manually"))
        XCTAssertTrue(instructions.label.contains("dictation continues"))
        XCTAssertTrue(app.buttons["cancel-keyboard-dictation"].exists)
    }

    /// Stopping a recording pays for it. Discarding is the other half, and it was reachable on
    /// this screen only by letting the words arrive and then deleting them.
    func testARecordingCanBeDiscardedWithoutBeingSent() {
        let app = launch(arguments: ["-ui-testing-recording-state"])
        let discard = app.buttons["discard-recording"]

        XCTAssertTrue(discard.waitForExistence(timeout: 10))
        discard.tap()

        XCTAssertTrue(app.staticTexts["Recording discarded"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["record"].isEnabled)
    }

    /// A recording must not outlive the only surface that tells the user the microphone is on.
    func testLeavingTheForegroundStopsRecordingAndExplainsWhy() {
        let app = launch(arguments: ["-ui-testing-recording-state"])
        XCTAssertTrue(app.staticTexts["Listening… tap to stop"].waitForExistence(timeout: 10))

        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10))
        app.activate()

        XCTAssertTrue(
            app.staticTexts["Recording stopped when DoNotType left the foreground"]
                .waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["record"].isEnabled)
    }

    /// Live dictation chooses only the operation — all three of them. What each one produces
    /// lives in Settings, where it cannot be mistaken for a fidelity level; a missing key is
    /// explained there too.
    func testTheThreeModesAreSeparateFromWhatEachOneProduces() {
        let app = launch(arguments: ["-ui-testing-no-api-key"])
        XCTAssertTrue(app.buttons["record"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["mode-dictate"].exists)
        XCTAssertTrue(app.buttons["mode-rewrite"].exists)
        XCTAssertTrue(app.buttons["mode-translate"].exists)
        XCTAssertFalse(app.segmentedControls["style-picker"].exists)

        app.buttons["open-settings"].tap()
        let picker = app.descendants(matching: .any)["rewrite-style"].firstMatch
        XCTAssertTrue(reveal(picker, in: app), "rewrite style should be configured in Settings")
        XCTAssertFalse(picker.isEnabled, "with no key configured, nothing can rewrite")

        let reason = app.descendants(matching: .any)["rewrite-unavailable"].firstMatch
        XCTAssertTrue(reveal(reason, in: app), "a disabled control has to say why it is disabled")
        XCTAssertTrue(
            (reason.label).contains("API key"),
            "the reason should name what is missing, got: \(reason.label)")
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
        for control in [
            "api-key", "model", "fidelity", "rewrite-style", "open-dictionary", "retention",
            "keep-audio", "open-prompt",
        ] {
            XCTAssertTrue(
                reveal(app.descendants(matching: .any)[control].firstMatch, in: app),
                "\(control) should be reachable in Settings")
        }

        let dictionary = app.descendants(matching: .any)["open-dictionary"].firstMatch
        XCTAssertFalse(dictionary.label.contains("model.personalDictionaryTerms.count"))
        XCTAssertNotNil(
            dictionary.label.range(of: #"\d+ (entry|entries)"#, options: .regularExpression),
            "the dictionary row should show a human-readable entry count, got \(dictionary.label)")
    }

    /// Covers the complete safe round trip without changing a preference: Settings exports the
    /// current profile into the editor first, QR generation accepts those exact bytes, and import
    /// applies only after the explicit button is pressed.
    func testSettingsTransferStagesExportsAndImports() {
        let app = launch()
        app.buttons["open-settings"].tap()

        let transfer = app.descendants(matching: .any)["open-settings-transfer"].firstMatch
        XCTAssertTrue(reveal(transfer, in: app), "the transfer row should be reachable")
        transfer.tap()
        XCTAssertTrue(app.navigationBars["Settings transfer"].waitForExistence(timeout: 10))
        XCTAssertTrue(
            reveal(app.buttons["Import QR image…"], in: app),
            "a saved QR image should be importable without opening the camera")

        let editor = app.descendants(matching: .any)["settings-transfer-json"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        let json = (editor.value as? String) ?? ""
        XCTAssertTrue(json.contains("\"format\" : \"app.donottype.settings\""))
        XCTAssertTrue(json.contains("\"version\" : 1"))
        XCTAssertTrue(json.contains("\"selectedProvider\""))

        let showQR = app.buttons["Show QR code"]
        XCTAssertTrue(reveal(showQR, in: app), "QR export should be reachable")
        showQR.tap()
        XCTAssertTrue(app.images["Settings QR code"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()

        let importSettings = app.buttons["Import settings"]
        XCTAssertTrue(reveal(importSettings, in: app), "the explicit import step should be reachable")
        importSettings.tap()
        XCTAssertTrue(
            app.staticTexts["Settings imported. API keys were stored in Keychain."]
                .waitForExistence(timeout: 5))
    }

    /// Typing a key and leaving the screen has to persist it. This is the setting without which
    /// the app cannot do anything at all, so "it looked like it saved" is not good enough.
    func testAPIKeySurvivesLeavingSettings() {
        let app = launch(arguments: ["-ui-testing-no-api-key"])
        app.buttons["open-settings"].tap()

        let field = app.secureTextFields["api-key"]
        XCTAssertTrue(reveal(field, in: app))
        field.tap()
        field.typeText("test-key-12345")

        app.navigationBars["Settings"].buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["DoNotType"].waitForExistence(timeout: 5))

        app.buttons["open-settings"].tap()
        XCTAssertTrue(reveal(field, in: app))
        XCTAssertEqual(field.value as? String, "••••••••••••••",
                       "the key should still be there after leaving and coming back")
    }

    func testMissingAPIKeyDisablesDictationBeforeRecording() {
        let app = launch(arguments: ["-ui-testing-no-api-key"])
        let record = app.buttons["record"]

        XCTAssertTrue(record.waitForExistence(timeout: 10))
        XCTAssertFalse(record.isEnabled)
        XCTAssertTrue(app.buttons["configure-api-key"].exists)
    }

    func testFirstLaunchGuidesProviderMicrophoneAndKeyboardSetup() {
        let app = launch(arguments: ["-ui-testing-no-api-key", "-ui-testing-onboarding"])

        XCTAssertTrue(app.navigationBars["Set up DoNotType"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["setup-scan-settings-qr"].exists)
        XCTAssertTrue(app.buttons["setup-import-settings"].exists)
        XCTAssertTrue(app.secureTextFields["setup-api-key"].exists)
        XCTAssertFalse(app.buttons["finish-initial-setup"].isEnabled)
    }

    func testSettingsScanShortcutPresentsScanner() {
        let app = launch()
        app.buttons["open-settings"].tap()
        XCTAssertTrue(app.buttons["scan-settings-qr"].waitForExistence(timeout: 5))
        app.buttons["scan-settings-qr"].tap()

        XCTAssertTrue(
            app.staticTexts["Scan a DoNotType settings QR code"].waitForExistence(timeout: 5),
            "the scan shortcut should present the camera surface after navigation")
        XCTAssertTrue(app.buttons["Cancel"].exists)
    }

    /// A successful scan is a complete import, not a silent replacement of the JSON editor.
    /// Camera frames are unavailable in Simulator, so the launch argument injects a valid payload
    /// immediately after presenting the same scanner flow.
    func testCompletedQRScanShowsImportConfirmation() {
        let app = launch(arguments: ["-ui-testing-completed-qr-scan"])
        app.buttons["open-settings"].tap()
        let scan = app.buttons["scan-settings-qr"]
        XCTAssertTrue(scan.waitForExistence(timeout: 5))
        scan.tap()

        let imported = app.staticTexts["Settings imported"]
        if !imported.waitForExistence(timeout: 3) {
            // SwiftUI's navigation-bar link can occasionally receive a synthesized tap without
            // activating. The ordinary scanner test independently proves the shortcut works on
            // its first tap; here retry once so this test remains about the completed import flow.
            XCTAssertTrue(scan.waitForExistence(timeout: 2))
            scan.tap()
        }

        XCTAssertTrue(imported.waitForExistence(timeout: 10))
        XCTAssertTrue(
            app.staticTexts[
                "Your DoNotType settings are ready. API keys were stored in Keychain."
            ].exists)
        XCTAssertTrue(app.buttons["finish-qr-import"].exists)
        app.buttons["finish-qr-import"].tap()

        XCTAssertTrue(app.navigationBars["Settings transfer"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            reveal(
                app.staticTexts[
                    "Settings imported from QR code. API keys were stored in Keychain."
                ],
                in: app))
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

        XCTAssertTrue(app.navigationBars["Prompt"].waitForExistence(timeout: 10))
        // TextEditor has been exposed as both TextView and Other across iOS/Xcode releases; the
        // identifier is ours and is the stable contract.
        let editor = app.descendants(matching: .any)["prompt-editor"].firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        let text = (editor.value as? String) ?? ""
        XCTAssertTrue(
            text.contains("SPELLING"),
            "the editor should open on the shipped prompt/system.md, not an empty box")
    }

    /// The offline half of the product. Nothing here can be exercised without a real recording and
    /// a paid request, so the test covers what can silently break instead: that the screen exists,
    /// that it offers all three modes, and that the mode survives leaving and returning — which is
    /// the part backed by `UserDefaults` and therefore the part that breaks quietly.
    func testFileTranscriptionScreenOffersEveryMode() {
        let app = launch()
        app.buttons["open-files"].tap()

        XCTAssertTrue(app.navigationBars["Transcribe a Recording"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["choose-recording"].firstMatch.exists)

        let mode = app.buttons["file-mode"]
        XCTAssertTrue(mode.waitForExistence(timeout: 5))
        mode.tap()

        // The three the CLI and the desktop offer. A summary that quietly stopped being reachable
        // would look exactly like a summary that was never added.
        XCTAssertTrue(app.buttons["Verbatim — word for word"].exists)
        XCTAssertTrue(app.buttons["Rewrite — Formal — professional prose"].exists)
        XCTAssertTrue(app.buttons["Summary — Brief — a short paragraph"].exists)

        app.buttons["Summary — Bullets — the key points"].tap()
        app.navigationBars["Transcribe a Recording"].buttons.firstMatch.tap()
        app.buttons["open-files"].tap()

        XCTAssertTrue(mode.waitForExistence(timeout: 5))
        XCTAssertTrue(
            mode.label.contains("Bullets"), "the chosen mode should persist, was \(mode.label)")
    }

    /// On a phone there is no Console and no shell, so this screen is the only evidence a bug
    /// report can carry. It must open, and it must already have something in it — the app logs its
    /// own launch, so an empty list here means logging never started.
    func testLogsScreenShowsWhatTheAppRecorded() {
        let app = launch()
        app.buttons["open-settings"].tap()

        let logs = app.descendants(matching: .any)["open-logs"].firstMatch
        XCTAssertTrue(reveal(logs, in: app), "the logs row should be reachable in Settings")
        logs.tap()

        XCTAssertTrue(app.navigationBars["Logs"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["log-level"].firstMatch.exists)
        XCTAssertTrue(
            app.staticTexts["started"].waitForExistence(timeout: 5),
            "the app logs its own launch, so that line should be here")
        XCTAssertTrue(app.buttons["share-log"].exists, "a log you cannot send is not evidence")
    }

    /// Changing fidelity has to stick: it is the setting that decides whether the app rewrites
    /// you, which is the whole argument the project makes.
    ///
    /// Both lookups go through `reveal`, which is the rule this file already documents and this
    /// test was the last one not following. Fidelity sits below the provider section, so whether it
    /// is on screen when Settings opens depends on how tall the simulator is — it was reachable on
    /// an iPhone 16 and below the fold on a 17, which is a fact about the device rather than about
    /// the app. `waitForExistence` cannot fix that, because a row a lazy `List` has not built does
    /// not exist to wait for.
    /// The dictation style is the setting this app's whole formatting story now hangs off, and it
    /// is two controls rather than one: a preset picker, and a box that only matters for Custom.
    /// Both have to survive leaving the screen, which is where a setting that saves on change but
    /// never reloads would look fine and be lost.
    func testDictationStyleSelectionPersists() {
        let app = launch()
        app.buttons["open-settings"].tap()

        let picker = app.buttons["dictation-style"]
        XCTAssertTrue(reveal(picker, in: app), "the dictation style picker should be reachable")
        picker.tap()
        app.buttons["Chat — short lines, light punctuation"].tap()

        app.navigationBars["Settings"].buttons.firstMatch.tap()
        app.buttons["open-settings"].tap()
        XCTAssertTrue(reveal(picker, in: app), "and still reachable after coming back")
        XCTAssertTrue(
            picker.label.contains("Chat"),
            "the dictation style should still read Chat, was \(picker.label)")
    }

    func testFidelitySelectionPersists() {
        let app = launch()
        app.buttons["open-settings"].tap()

        let picker = app.buttons["fidelity"]
        XCTAssertTrue(reveal(picker, in: app), "the fidelity picker should be reachable")
        picker.tap()
        app.buttons["Raw — every um and false start"].tap()

        app.navigationBars["Settings"].buttons.firstMatch.tap()
        app.buttons["open-settings"].tap()
        XCTAssertTrue(reveal(picker, in: app), "and still reachable after coming back")
        XCTAssertTrue(
            picker.label.contains("Raw"),
            "fidelity should still read Raw, was \(picker.label)")
    }
}
