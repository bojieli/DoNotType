import XCTest

@testable import DoNotTypeCore

/// The rules that decide which connection a dictation goes out on.
///
/// These are cheap assertions about object identity rather than anything that touches a network,
/// and that is deliberate: the failure they exist to catch was invisible in every functional test
/// the app had. Transcripts were correct, retries recovered, nothing threw — and a quarter of
/// dictations took a minute because two requests shared one dead TCP connection. What went wrong
/// was *which session the request used*, so that is what is checked here.
final class ProviderTransportTests: XCTestCase {

    private let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/interactions")!

    /// Back-to-back dictations reuse the connection. Never reusing costs a measured 1.08 s on
    /// every request, and within the idle window there is nothing wrong with the one already open.
    func testAConnectionIsReusedWhileItIsStillFresh() async {
        let transport = ProviderTransport()

        let first = await transport.session(for: url)
        let second = await transport.session(for: url)

        XCTAssertTrue(first === second, "a warm connection must not be thrown away")
    }

    /// The whole point. A caller that knows the pooled connection is suspect — the stall hedge, or
    /// any retry after a failure — must not be handed it back.
    func testAskingForAFreshConnectionReplacesThePooledOne() async {
        let transport = ProviderTransport()

        let pooled = await transport.session(for: url)
        let fresh = await transport.session(for: url, connection: .fresh)

        XCTAssertFalse(pooled === fresh, "a hedge on the failing connection is not a second draw")
    }

    /// And the replacement sticks: the next ordinary request uses the new connection, not the one
    /// that was just retired.
    func testTheFreshConnectionBecomesThePooledOne() async {
        let transport = ProviderTransport()

        _ = await transport.session(for: url)
        let fresh = await transport.session(for: url, connection: .fresh)
        let next = await transport.session(for: url)

        XCTAssertTrue(fresh === next)
    }

    /// Two backends, two connections. Without this a rewrite through one provider would refresh
    /// the "recently used" timestamp that a dictation to another then trusts — and trusting it is
    /// the entire failure mode.
    func testHostsDoNotShareAConnection() async {
        let transport = ProviderTransport()

        let google = await transport.session(for: url)
        let xai = await transport.session(for: URL(string: "https://api.x.ai/v1/stt")!)

        XCTAssertFalse(google === xai)
    }

    /// The window is bounded and the bound is the measured one: in the history this was built
    /// from, no request that followed the previous one inside a minute was ever slow, and thirty
    /// seconds sits inside that with the margin doubled.
    func testTheIdleWindowIsThirtySeconds() {
        XCTAssertEqual(ProviderTransport.maxIdleSeconds, 30)
    }

    /// Two minutes was never a wait anybody wanted — a healthy request answers in 2.6 s at p95 —
    /// only a long delay before the retry that was going to fix it.
    func testTheRequestTimeoutIsNotTwoMinutes() {
        XCTAssertEqual(ProviderTransport.requestTimeoutSeconds, 25)
        XCTAssertLessThan(
            ProviderTransport.warmUpTimeoutSeconds, ProviderTransport.requestTimeoutSeconds,
            "warm-up exists to find a dead connection fast, not to wait for a slow one")
    }

    /// A test that hands a provider its own session must still get that session, or every provider
    /// test in this suite would start opening real connections.
    func testAnInjectedSessionWins() async {
        let injected = URLSession(configuration: .ephemeral)
        defer { injected.invalidateAndCancel() }

        let chosen = await ProviderTransport.session(
            override: injected, for: url, connection: .fresh)

        XCTAssertTrue(chosen === injected)
    }

    // MARK: - Warm-up targets

    /// Warm-up opens a connection to the host and must not call the API path: any answer from the
    /// host proves the connection, while a GET to the endpoint would be a real request with a real
    /// bill attached.
    func testTheWarmUpTargetIsTheHostAndNotTheEndpoint() {
        XCTAssertEqual(
            url.origin?.absoluteString, "https://generativelanguage.googleapis.com/")
    }

    /// A base URL carrying a token — which one of this project's own providers is configured by
    /// pasting — must not keep it just because the path was dropped.
    func testAnOriginCarriesNoCredentialsOrQuery() {
        let url = URL(string: "https://user:secret@example.com/v1/chat?key=abc123#frag")!
        XCTAssertEqual(url.origin?.absoluteString, "https://example.com/")
    }

    /// Every backend the app ships knows where it will be connecting, so every one of them can be
    /// warmed. A provider that returned nil here would silently go back to paying for the
    /// handshake in front of the user.
    func testEveryShippedProviderKnowsItsOrigin() {
        let providers: [any TranscriptionProvider] = [
            GeminiProvider(apiKey: "k"),
            OpenAICompatibleProvider(
                name: "openrouter",
                baseURL: URL(string: "https://openrouter.ai/api/v1/chat/completions")!,
                apiKey: "k"),
            XAISpeechProvider(apiKey: "k"),
            DeepgramProvider(apiKey: "k"),
            MistralProvider(apiKey: "k"),
        ]

        for provider in providers {
            XCTAssertNotNil(provider.endpointOrigin, "\(provider.name) cannot be warmed up")
            XCTAssertEqual(provider.endpointOrigin?.path, "/", "\(provider.name)")
        }
    }
}
