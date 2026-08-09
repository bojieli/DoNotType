import XCTest

@testable import DoNotTypeCore

final class ContextEncoderTests: XCTestCase {
    private func text(_ part: InputPart) -> String {
        if case .text(let value) = part { return value }
        return ""
    }

    func testEmptyContextProducesNoParts() {
        XCTAssertTrue(ContextEncoder().encode(ScreenContext()).isEmpty)
    }

    func testContextIsWrappedInDelimiters() {
        let parts = ContextEncoder().encode(
            ScreenContext(appName: "Xcode", visibleText: String(repeating: "context ", count: 60)))
        let joined = parts.map(text).joined(separator: "\n")

        XCTAssertTrue(joined.contains("REFERENCE ONLY, DO NOT TRANSCRIBE"))
        XCTAssertTrue(joined.contains("END SCREEN CONTEXT"))
        XCTAssertTrue(
            joined.contains("ONLY thing to transcribe"),
            "the closing line re-establishes the audio as the target after untrusted text")
    }

    /// An empty labelled header costs tokens and invites the model to fill it in.
    func testEmptySectionsAreOmittedEntirely() {
        let parts = ContextEncoder().encode(
            ScreenContext(appName: "Terminal", textBeforeCaret: "git comm"))
        let joined = parts.map(text).joined(separator: "\n")

        XCTAssertTrue(joined.contains("TEXT BEFORE CARET"))
        XCTAssertFalse(joined.contains("TEXT AFTER CARET"))
        XCTAssertFalse(joined.contains("SELECTED TEXT"))
    }

    func testVisibleTextIsClippedKeepingTheTail() {
        let encoder = ContextEncoder(limits: .init(visibleTextChars: 40, thinTextThreshold: 0))
        let visible = String(repeating: "A", count: 100) + "CARET_END"
        let joined = encoder.encode(ScreenContext(appName: "X", visibleText: visible))
            .map(text).joined()

        XCTAssertTrue(joined.contains("CARET_END"))
        XCTAssertFalse(joined.contains(String(repeating: "A", count: 60)))
    }

    func testScreenshotBecomesAnImagePartBeforeTheCaretBlock() {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let parts = ContextEncoder().encode(
            ScreenContext(appName: "Figma", screenshotPNG: png))

        guard case .image(let data, let mimeType) = parts[1] else {
            return XCTFail("expected an image part after the header, got \(parts[1])")
        }
        XCTAssertEqual(data, png)
        XCTAssertEqual(mimeType, "image/png")
    }

    func testThinAccessibilityTextIsDetected() {
        let thin = ScreenContext(appName: "Figma", visibleText: "Layer 1")
        let rich = ScreenContext(appName: "Xcode", visibleText: String(repeating: "x ", count: 400))

        XCTAssertTrue(thin.isAccessibilityThin())
        XCTAssertFalse(rich.isAccessibilityThin())
    }

    func testIdentityLinesRenderWhenPresentAndAreSkippedWhenNot() {
        let full = ContextEncoder().encode(
            ScreenContext(
                appName: "Safari", windowTitle: "Pricing", browserURL: "https://example.com",
                role: "AXTextField", isEditable: true, textBeforeCaret: "hi"))
        let header = text(full[0])

        XCTAssertTrue(header.contains("App: Safari — Pricing"))
        XCTAssertTrue(header.contains("URL: https://example.com"))
        XCTAssertTrue(header.contains("Field: AXTextField · editable"))

        let bare = ContextEncoder().encode(ScreenContext(textBeforeCaret: "hi"))
        XCTAssertFalse(text(bare[0]).contains("URL:"))
    }
}
