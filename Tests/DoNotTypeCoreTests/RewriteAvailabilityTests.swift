import XCTest

@testable import DoNotTypeCore

/// The one rule four clients used to answer four ways.
final class RewriteAvailabilityTests: XCTestCase {
    private func resolve(
        _ provider: ProviderKind, keyed: Set<ProviderKind>
    ) -> RewriteAvailability {
        RewriteAvailability.resolve(provider: provider) { keyed.contains($0) }
    }

    /// The regression this rule exists for.
    ///
    /// A fresh install has no key. The old test asserted the control was hidden then, and it
    /// passed only because the default backend was a recogniser — `!isSpeechRecognition` was false
    /// and the second clause found nothing. Moving the default to Google flipped the first clause
    /// true and the control appeared on an install that cannot transcribe at all, let alone
    /// rewrite. The question was never "what kind of backend is this", it was "can anything run".
    func testAFreshInstallWithNoKeyCannotRewriteWhicheverBackendIsSelected() {
        for provider in ProviderKind.allCases {
            XCTAssertEqual(
                resolve(provider, keyed: []), .noKey(.rewriting),
                "\(provider.rawValue) with no key must not offer a rewrite")
        }
    }

    func testAModelBackendWithAKeyCanRewrite() {
        for provider in ProviderKind.allCases where !provider.isSpeechRecognition {
            XCTAssertEqual(resolve(provider, keyed: [provider]), .available, provider.rawValue)
        }
    }

    /// xAI is a recogniser that also sells chat, reached with the same key. "Cannot read your
    /// screen" and "cannot rewrite what you said" are different questions for it.
    func testARecogniserThatSellsChatCanRewriteOnItsOwnKey() {
        XCTAssertTrue(ProviderKind.xai.isSpeechRecognition)
        XCTAssertEqual(resolve(.xai, keyed: [.xai]), .available)
    }

    func testARecogniserWithNoTextEndpointNeedsAnotherBackend() {
        let recognisers = ProviderKind.allCases.filter {
            $0.isSpeechRecognition && !$0.supportsTextGeneration
        }
        XCTAssertFalse(recognisers.isEmpty, "the case this rule exists for must still exist")

        for provider in recognisers {
            XCTAssertEqual(
                resolve(provider, keyed: [provider]), .backendCannotRewrite(provider, .rewriting),
                "\(provider.rawValue) alone cannot rewrite")
            XCTAssertEqual(
                resolve(provider, keyed: [provider, .google]), .available,
                "\(provider.rawValue) paired with a model backend can")
        }
    }

    /// A greyed-out control that does not say why is barely better than a missing one, and a
    /// missing one is how this feature came to look absent.
    func testEveryUnavailableCaseExplainsItselfAndSaysWhatToDo() {
        let unavailable: [RewriteAvailability] = [
            .noKey(.rewriting), .backendCannotRewrite(.deepgram, .rewriting),
            .noKey(.translating), .backendCannotRewrite(.deepgram, .translating),
        ]
        for state in unavailable {
            let reason = try? XCTUnwrap(state.reason)
            let text = reason ?? ""
            XCTAssertFalse(text.isEmpty, "\(state) must say why")
            XCTAssertTrue(text.contains("Add a"), "\(state) must say what to do, got: \(text)")
        }
        let noLanguage = RewriteAvailability.noTargetLanguage.reason ?? ""
        XCTAssertTrue(noLanguage.contains("Settings"), "must say where to set it, got: \(noLanguage)")
        XCTAssertNil(RewriteAvailability.available.reason)
    }

    /// The message names the backend that cannot do it, not a generic "this provider".
    func testTheReasonNamesTheBackend() {
        let reason = RewriteAvailability.backendCannotRewrite(.deepgram, .rewriting).reason ?? ""
        XCTAssertTrue(reason.contains(ProviderKind.deepgram.displayName), reason)
    }

    /// The strings are hand-ported and must stay word-identical across the four clients, so they
    /// are asserted literally rather than by shape — see `docs/PARITY.md`. The C# and Kotlin
    /// suites assert the same two sentences; a change here that is not made there is a change
    /// that makes a phone and a laptop different products.
    func testTheWordingMatchesTheOtherClients() {
        XCTAssertEqual(
            RewriteAvailability.noKey(.rewriting).reason,
            "Add an API key first — without one nothing can run, rewriting included.")
        XCTAssertEqual(
            RewriteAvailability.backendCannotRewrite(.deepgram, .rewriting).reason,
            "Deepgram only transcribes audio and cannot rewrite text. Add a key for a backend "
                + "that can, and rewriting will use it.")
        XCTAssertEqual(
            RewriteAvailability.noKey(.translating).reason,
            "Add an API key first — without one nothing can run, translating included.")
        XCTAssertEqual(
            RewriteAvailability.backendCannotRewrite(.deepgram, .translating).reason,
            "Deepgram only transcribes audio and cannot translate text. Add a key for a backend "
                + "that can, and translating will use it.")
        XCTAssertEqual(
            RewriteAvailability.noTargetLanguage.reason,
            "Set a target language in Settings first, and Translate will write in it.")
    }

    /// The rule every client asks, through the mode rather than through a desktop-only entry
    /// point. A target language used to be reported *here*, as a reason the second key could not
    /// rewrite, because on a desktop it silently replaced what that key produced. It is a key of
    /// its own now, so a rewrite key with a target language set is simply a rewrite key.
    func testATargetLanguageNoLongerDisplacesTheRewriteKey() {
        let keyed: (ProviderKind) -> Bool = { _ in true }
        XCTAssertEqual(
            LiveMode.rewrite.availability(provider: .google, language: "French", hasKey: keyed),
            .available)
        XCTAssertEqual(
            LiveMode.translate.availability(provider: .google, language: "French", hasKey: keyed),
            .available)
        XCTAssertEqual(
            LiveMode.translate.availability(provider: .google, language: "  ", hasKey: keyed),
            .noTargetLanguage,
            "whitespace is not a target language")
    }

    /// The picker asks the mode, not the rule, and the two backend-shaped answers come back worded
    /// for the job that was actually chosen.
    func testTheModeAsksForItsOwnJob() {
        let keyed: (ProviderKind) -> Bool = { _ in false }
        XCTAssertEqual(
            LiveMode.dictate.availability(provider: .google, language: "", hasKey: keyed),
            .available,
            "a plain dictation has no second stage to be unavailable")
        XCTAssertEqual(
            LiveMode.rewrite.availability(provider: .google, language: "", hasKey: keyed),
            .noKey(.rewriting))
        XCTAssertEqual(
            LiveMode.translate.availability(provider: .google, language: "French", hasKey: keyed),
            .noKey(.translating))
    }

    /// Translate with nothing to translate into is the one state the old two-way toggle could not
    /// represent: it used to be a target language silently overriding whatever the chip said.
    func testTranslateWithoutALanguageIsUnavailableForThatReasonAlone() {
        let keyed: (ProviderKind) -> Bool = { _ in true }
        XCTAssertEqual(
            LiveMode.translate.availability(provider: .google, language: "  ", hasKey: keyed),
            .noTargetLanguage,
            "whitespace is not a language")
        XCTAssertEqual(
            LiveMode.translate.availability(provider: .google, language: "French", hasKey: keyed),
            .available)
    }
}
