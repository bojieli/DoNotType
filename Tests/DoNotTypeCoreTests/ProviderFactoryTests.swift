import XCTest

@testable import DoNotTypeCore

/// Building a provider from a key that did not come from the environment.
final class ProviderFactoryTests: XCTestCase {

    /// The app and the CLI have a key already — from the Keychain, a settings field or a flag — and
    /// used to pass `environment: [envVar: key]`, which *replaces* the environment instead of adding
    /// to it. Everything else the factory reads from there was therefore unreachable from the app.
    func testSuppliedKeyDoesNotHideTheRestOfTheEnvironment() throws {
        let provider = try ProviderFactory.make(
            .local, apiKey: "from-the-keychain",
            environment: ["DNT_LOCAL_BASE_URL": "http://gpu-box:8000/v1/chat/completions"])

        let openAI = try XCTUnwrap(provider as? OpenAICompatibleProvider)
        XCTAssertEqual(openAI.baseURL.absoluteString, "http://gpu-box:8000/v1/chat/completions")
        XCTAssertEqual(openAI.apiKey, "from-the-keychain")
    }

    /// The settings panel tells Chinese-speaking users to set this. Before the fix it could not
    /// have had any effect, because the app never passed the environment through.
    func testDeepgramLanguageFromTheEnvironmentSurvivesASuppliedKey() throws {
        let provider = try ProviderFactory.make(
            .deepgram, apiKey: "k", environment: ["DNT_DEEPGRAM_LANGUAGE": "zh"])
        XCTAssertEqual((provider as? DeepgramProvider)?.language, "zh")
    }

    func testSuppliedKeyBeatsOneOfItsOwnSpellingsInTheEnvironment() throws {
        let provider = try ProviderFactory.make(
            .xai, apiKey: "chosen",
            environment: ["XAI_API_KEY": "stale", "GROK_API_KEY": "staler"])
        XCTAssertEqual((provider as? XAISpeechProvider)?.apiKey, "chosen")
    }
}
