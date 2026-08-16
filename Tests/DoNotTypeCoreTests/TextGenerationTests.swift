import Foundation
import XCTest

@testable import DoNotTypeCore

/// "Cannot read your screen" and "cannot rewrite what you said" are different questions.
///
/// They had the same answer for every backend until xAI, which recognises speech on one endpoint
/// and serves Grok chat models on another behind the same key. Answering the first when the
/// second was asked takes away a hotkey the key already pays for.
final class TextGenerationTests: XCTestCase {
    func testARecogniserWhoseKeyReachesChatCanStillRewrite() {
        XCTAssertTrue(ProviderKind.xai.isSpeechRecognition)
        XCTAssertTrue(ProviderKind.xai.supportsTextGeneration)
        XCTAssertNotNil(ProviderKind.xai.defaultTextModel)
        XCTAssertNotEqual(ProviderKind.xai.defaultTextModel, ProviderKind.xai.defaultModel)
    }

    func testRecognisersThatSellNothingElseCannot() {
        for kind in [ProviderKind.deepgram, .mistral] {
            XCTAssertFalse(kind.supportsTextGeneration, "\(kind.rawValue)")
            XCTAssertNil(kind.defaultTextModel, "\(kind.rawValue)")
        }
    }

    /// A language model needs no second entry: the model that transcribes also rewrites, and a
    /// second field would only be somewhere for the two to disagree.
    func testLanguageModelsRewriteWithTheModelThatTranscribes() {
        for kind in [ProviderKind.gemini, .openrouter, .local] {
            XCTAssertTrue(kind.supportsTextGeneration, "\(kind.rawValue)")
            XCTAssertNil(kind.defaultTextModel, "\(kind.rawValue)")
        }
    }

    func testTheTextBackendForXAIIsTheChatEndpointAndNotTheSpeechOne() throws {
        let backend = try XCTUnwrap(ProviderFactory.makeTextProvider(.xai, apiKey: "k"))
        let chat = try XCTUnwrap(backend as? OpenAICompatibleProvider)
        XCTAssertEqual(chat.baseURL.absoluteString, "https://api.x.ai/v1/chat/completions")
        XCTAssertEqual(chat.name, "xai")
        // The speech endpoint would 404 a chat request, and the reasoning field is rejected by
        // the non-reasoning Grok models this stage is meant for.
        XCTAssertNil(chat.reasoningEffort)
    }

    func testTheTextBackendForALanguageModelIsTheOneThatTranscribes() throws {
        let backend = try XCTUnwrap(ProviderFactory.makeTextProvider(.openrouter, apiKey: "k"))
        XCTAssertEqual(backend.name, "openrouter")
    }

    func testABackendWithNoTextSideOffersNone() throws {
        XCTAssertNil(try ProviderFactory.makeTextProvider(.deepgram, apiKey: "k"))
        XCTAssertNil(try ProviderFactory.makeTextProvider(.mistral, apiKey: "k"))
    }

    /// The speech endpoint stays audio-only; the text side is a different provider object, not a
    /// second mode of this one.
    func testTheSpeechEndpointStillRefusesText() async {
        let request = TranscriptionRequest(
            model: "grok-stt", systemInstruction: "", parts: [.text("rewrite this")])
        do {
            _ = try await XAISpeechProvider(apiKey: "k").transcribe(request)
            XCTFail("expected audioRequired")
        } catch ProviderError.audioRequired(let provider) {
            XCTAssertEqual(provider, "xai")
        } catch {
            XCTFail("expected audioRequired, got \(error)")
        }
    }
}
