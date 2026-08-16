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
                resolve(provider, keyed: []), .noKey,
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
                resolve(provider, keyed: [provider]), .backendCannotRewrite(provider),
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
            .noKey, .backendCannotRewrite(.deepgram),
        ]
        for state in unavailable {
            let reason = try? XCTUnwrap(state.reason)
            let text = reason ?? ""
            XCTAssertFalse(text.isEmpty, "\(state) must say why")
            XCTAssertTrue(text.contains("Add a"), "\(state) must say what to do, got: \(text)")
        }
        XCTAssertNil(RewriteAvailability.available.reason)
    }

    /// The message names the backend that cannot do it, not a generic "this provider".
    func testTheReasonNamesTheBackend() {
        let reason = RewriteAvailability.backendCannotRewrite(.deepgram).reason ?? ""
        XCTAssertTrue(reason.contains(ProviderKind.deepgram.displayName), reason)
    }

    /// The strings are hand-ported and must stay word-identical across the four clients, so they
    /// are asserted literally rather than by shape — see `docs/PARITY.md`. The C# and Kotlin
    /// suites assert the same two sentences; a change here that is not made there is a change
    /// that makes a phone and a laptop different products.
    func testTheWordingMatchesTheOtherClients() {
        XCTAssertEqual(
            RewriteAvailability.noKey.reason,
            "Add an API key first — without one nothing can run, rewriting included.")
        XCTAssertEqual(
            RewriteAvailability.backendCannotRewrite(.deepgram).reason,
            "Deepgram only transcribes audio and cannot rewrite text. Add a key for a backend "
                + "that can, and rewriting will use it.")
    }
}
