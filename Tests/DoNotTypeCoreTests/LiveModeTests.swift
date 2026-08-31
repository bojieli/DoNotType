import XCTest

@testable import DoNotTypeCore

/// The phone keyboards' mode picker.
///
/// The same cases are asserted in `android/app/src/test/kotlin/app/donottype/core/LiveModeTest.kt`
/// and `windows/DoNotType.Core.Tests/CoreTests.cs` — see `docs/PARITY.md`. Windows has no picker,
/// but it ships the settings transfer that carries the value between the phones, so it has to
/// agree about the spellings.
final class LiveModeTests: XCTestCase {

    /// The persisted spelling is what the settings transfer writes, so a rename here silently
    /// resets every phone that reads a file written by an older build.
    func testTheSpellingsAreStableAndUnknownValuesFallBack() {
        XCTAssertEqual(LiveMode.allCases.map(\.rawValue), ["dictate", "rewrite", "translate"])
        XCTAssertEqual(LiveMode(rawValue: "nonsense"), nil)
        XCTAssertEqual(LiveMode.default, .dictate)
    }

    /// Dictation is the product. A mode picker that starts anywhere else changes what the app does
    /// on a fresh install.
    func testTheDefaultIsAPlainDictation() {
        XCTAssertEqual(
            LiveMode.default.stage(style: .formal, language: "French"), .verbatim,
            "neither a configured style nor a configured language may start a second stage")
    }

    func testEachModeAsksForItsOwnStage() {
        XCTAssertEqual(LiveMode.dictate.stage(style: .formal, language: "French"), .verbatim)
        XCTAssertEqual(LiveMode.rewrite.stage(style: .formal, language: "French"), .rewrite(.formal))
        XCTAssertEqual(
            LiveMode.translate.stage(style: .formal, language: "French"), .translate("French"))
    }

    /// The exclusivity the picker exists to make visible. A target language used to override the
    /// rewrite toggle from Settings, so the chip said Rewrite over a request that translated.
    func testTranslateAndRewriteCannotHappenAtOnce() {
        for mode in LiveMode.allCases {
            let stage = mode.stage(style: .formal, language: "French")
            let isRewrite = stage == .rewrite(.formal)
            let isTranslate = stage == .translate("French")
            XCTAssertFalse(isRewrite && isTranslate, "\(mode) asked for two second stages")
        }
    }

    /// An unconfigured mode is a dictation rather than a request that asks a model to do something
    /// unspecified to a transcript. The picker greys these out — `availability` is what it asks —
    /// but a stale persisted value must not turn into a strange request either.
    func testAnUnconfiguredModeFallsBackToTheTranscript() {
        XCTAssertEqual(LiveMode.translate.stage(style: .formal, language: ""), .verbatim)
        XCTAssertEqual(LiveMode.translate.stage(style: .formal, language: "   "), .verbatim)
        XCTAssertEqual(LiveMode.rewrite.stage(style: .verbatim, language: "French"), .verbatim)
    }

    /// 68dp on Android, 86pt on iOS. Both are laid out for these three words.
    func testTheLabelsAreShortEnoughForTheChip() {
        for mode in LiveMode.allCases {
            XCTAssertFalse(mode.label.isEmpty)
            XCTAssertLessThanOrEqual(mode.label.count, 9, mode.label)
        }
    }
}
