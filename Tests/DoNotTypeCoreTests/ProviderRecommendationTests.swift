import XCTest

@testable import DoNotTypeCore

/// What the settings pickers advise, and the invariants that keep the advice honest.
///
/// These are cheap assertions about strings, which is normally a smell. They are here because the
/// same recommendation is hand-written four times — Swift for macOS and iOS, C# for Windows,
/// Kotlin for Android — and the failure mode of that arrangement is one client quietly advising
/// something the others do not. Matching tests exist in `FailureAdviceTests` for the same reason.
final class ProviderRecommendationTests: XCTestCase {

    /// Two, and these two. The list is the product decision; everything below is a consequence of
    /// it, so a change here should be deliberate enough to update this line.
    func testTheRecommendedSetIsTheTwoEndsOfOneAxis() {
        XCTAssertEqual(ProviderKind.recommended, [.google, .xai])
        // The axis itself: one reads the screen, the other cannot. A recommendation of two
        // backends that differed on nothing would be a coin toss dressed as advice.
        XCTAssertFalse(ProviderKind.google.isSpeechRecognition)
        XCTAssertTrue(ProviderKind.xai.isSpeechRecognition)
    }

    /// A picker that recommends everything recommends nothing.
    func testOnlyTheRecommendedTwoCarryANote() {
        for kind in ProviderKind.allCases {
            XCTAssertEqual(
                kind.recommendationNote != nil, kind.isRecommended,
                "\(kind.rawValue) disagrees about whether it is recommended")
            XCTAssertEqual(kind.ungroundedRecommendationNote != nil, kind.isRecommended)
        }
    }

    /// Order is the recommendation that survives a fixed-height dropdown, so it is asserted rather
    /// than left to whatever order `allCases` happens to have.
    func testEveryBackendIsOfferedAndTheRecommendedOnesComeFirst() {
        XCTAssertEqual(Set(ProviderKind.pickerOrder), Set(ProviderKind.allCases))
        XCTAssertEqual(ProviderKind.pickerOrder.count, ProviderKind.allCases.count)
        XCTAssertEqual(Array(ProviderKind.pickerOrder.prefix(2)), ProviderKind.recommended)
    }

    /// The default a fresh install gets has to be one of the two we tell people to pick, or the
    /// settings window is arguing with the installer.
    func testTheDefaultForNewInstallsIsRecommended() {
        XCTAssertTrue(ProviderKind.defaultForNewInstalls.isRecommended)
        XCTAssertEqual(ProviderKind.defaultForNewInstalls.defaultModel, "gemini-3.5-flash")
    }

    /// `displayName` names what ran, and it is written into history rows, log lines and connection
    /// errors. Advice belongs only on the row of a picker.
    func testAdviceStaysOutOfTheNameUsedForRecords() {
        for kind in ProviderKind.allCases {
            XCTAssertFalse(kind.displayName.contains("recommended"))
            XCTAssertTrue(kind.pickerLabel.hasPrefix(kind.displayName))
        }
        XCTAssertEqual(ProviderKind.google.pickerLabel, "Google — recommended")
        XCTAssertEqual(ProviderKind.xai.pickerLabel, "xAI — recommended")
        XCTAssertEqual(ProviderKind.openrouter.pickerLabel, "OpenRouter")
    }

    /// The iOS wording exists because iOS cannot read another app's screen. If it ever claimed the
    /// screen the note would be a promise the platform forbids — see `docs/PARITY.md`.
    func testTheUngroundedWordingNeverClaimsTheScreen() throws {
        let note = try XCTUnwrap(ProviderKind.google.ungroundedRecommendationNote)
        XCTAssertFalse(note.contains("reads the screen"))
        XCTAssertTrue(note.contains("audio alone"))
        // And the grounded one must, since that is the entire claim being made for it.
        let grounded = try XCTUnwrap(ProviderKind.google.recommendationNote)
        XCTAssertTrue(grounded.contains("reads the screen"))
        XCTAssertTrue(grounded.contains("seven recent jargon-heavy recordings"))
        XCTAssertTrue(grounded.contains("no human goldens"))
    }
}
