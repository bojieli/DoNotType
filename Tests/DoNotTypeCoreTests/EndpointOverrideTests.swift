import XCTest

@testable import DoNotTypeCore

/// Pointing a backend at a URL somebody else runs.
///
/// This was reachable for exactly one backend, only through `DNT_LOCAL_BASE_URL`, and only in a
/// process that inherits a shell environment — which a menu-bar app opened from Finder does not.
/// So the documented way to use a compatible third-party service did not work for the people most
/// likely to want it.
final class EndpointOverrideTests: XCTestCase {

    private let key = ["GEMINI_API_KEY": "k", "OPENROUTER_API_KEY": "k", "XAI_API_KEY": "k",
                       "DEEPGRAM_API_KEY": "k", "MISTRAL_API_KEY": "k"]

    /// Every backend takes one. "I want to use a mirror of this API" is not a wish specific to any
    /// of them, and a per-backend allowlist would be a list somebody has to remember to extend.
    func testEveryBackendAcceptsAnEndpointOverride() throws {
        let mirror = "https://mirror.example.com/v1/transcribe"
        for kind in ProviderKind.allCases {
            let provider = try ProviderFactory.make(kind, endpoint: mirror, environment: key)
            XCTAssertEqual(
                provider.endpointOrigin?.absoluteString, "https://mirror.example.com/",
                "\(kind.rawValue) ignored the endpoint it was given")
        }
    }

    /// The default is what it always was, so an install that has never touched this setting sends
    /// its audio exactly where it used to.
    func testNoOverrideKeepsTheBuiltInEndpoint() throws {
        let google = try ProviderFactory.make(.google, environment: key)
        XCTAssertEqual(
            google.endpointOrigin?.absoluteString, "https://generativelanguage.googleapis.com/")

        let xai = try ProviderFactory.make(.xai, environment: key)
        XCTAssertEqual(xai.endpointOrigin?.absoluteString, "https://api.x.ai/")
    }

    /// Empty and whitespace mean "unset", because that is what an emptied text field produces and
    /// it must not be read as a URL.
    func testAnEmptyOverrideIsNotAnEndpoint() throws {
        for blank in ["", "   ", "\n"] {
            let provider = try ProviderFactory.make(.google, endpoint: blank, environment: key)
            XCTAssertEqual(
                provider.endpointOrigin?.absoluteString,
                "https://generativelanguage.googleapis.com/",
                "a blank field must not be treated as a URL")
        }
    }

    /// A half-typed setting must not be able to cost somebody their words: the dictation goes to
    /// the built-in endpoint rather than failing.
    func testAnUnparseableOverrideFallsBackRatherThanThrowing() throws {
        let provider = try ProviderFactory.make(
            .google, endpoint: "not a url at all", environment: key)
        XCTAssertEqual(
            provider.endpointOrigin?.absoluteString, "https://generativelanguage.googleapis.com/")
    }

    /// The placeholder the settings field shows has to be the URL that is actually used, or it
    /// documents something the app does not do.
    func testTheAdvertisedDefaultIsTheOneUsed() throws {
        for kind in ProviderKind.allCases {
            let provider = try ProviderFactory.make(kind, environment: key)
            let advertised = URL(string: kind.defaultEndpoint)?.origin?.absoluteString
            XCTAssertEqual(
                provider.endpointOrigin?.absoluteString, advertised,
                "\(kind.rawValue)'s advertised default endpoint is not where it posts")
        }
    }

    /// The key path callers actually use, which resolves the key and the endpoint together.
    func testTheKeyedFactoryForwardsTheEndpoint() throws {
        let provider = try ProviderFactory.make(
            .openrouter, apiKey: "k", endpoint: "https://gateway.example.com/v1/chat/completions",
            environment: [:])
        XCTAssertEqual(provider.endpointOrigin?.absoluteString, "https://gateway.example.com/")
    }

    /// A recogniser's override points at its *audio* endpoint. Sending a chat request there would
    /// fail for a reason nobody could read off the setting, so the second stage keeps its own URL.
    func testARecognisersOverrideDoesNotRedirectItsRewriteEndpoint() throws {
        let text = try ProviderFactory.makeTextProvider(
            .xai, apiKey: "k", endpoint: "https://mirror.example.com/v1/stt", environment: key)
        XCTAssertEqual(text?.endpointOrigin?.absoluteString, "https://api.x.ai/")
    }
}
