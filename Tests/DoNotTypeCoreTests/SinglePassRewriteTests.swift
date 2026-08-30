import XCTest

@testable import DoNotTypeCore

/// A provider that reports whichever fields the request asked for, so a test can tell a folded
/// single-pass request apart from a transcription followed by a second stage.
private final class StyleAwareProvider: TranscriptionProvider, @unchecked Sendable {
    let name: String
    private let support: GroundingSupport
    /// When false, the model ignores the wider schema and answers with the transcript alone —
    /// exactly what `gpt-audio` does to a JSON schema, and what the fallback exists for.
    private let honoursStyledSchema: Bool
    private(set) var requests: [TranscriptionRequest] = []

    var transcript = "so the version is one point five and Kaelith owns the rollout"
    var styled = "The version is 1.5, and Kaelith owns the rollout."
    var secondStage = "Second-stage prose."

    init(
        name: String = "stub", grounding: GroundingSupport = .multimodal,
        honoursStyledSchema: Bool = true
    ) {
        self.name = name
        self.support = grounding
        self.honoursStyledSchema = honoursStyledSchema
    }

    func grounding(forModel model: String) -> GroundingSupport { support }

    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        requests.append(request)
        if !request.containsAudio {
            return TranscriptionResult(
                transcript: Transcript(transcript: secondStage, language: "en"),
                usage: TokenUsage(), rawOutput: secondStage)
        }
        let carries = request.wantsStyledOutput && honoursStyledSchema
        return TranscriptionResult(
            transcript: Transcript(
                transcript: transcript, language: "en", styled: carries ? styled : nil),
            usage: TokenUsage(audioTokens: 96), rawOutput: transcript)
    }

    var audioRequests: [TranscriptionRequest] { requests.filter(\.containsAudio) }
    var textRequests: [TranscriptionRequest] { requests.filter { !$0.containsAudio } }
}

/// The rewrite that costs no second round trip, and the invariant it must not break.
final class SinglePassRewriteTests: XCTestCase {
    private var audio: AudioFile!

    override func setUpWithError() throws {
        try super.setUpWithError()
        var directory = URL(fileURLWithPath: #filePath)
        var fixture: URL?
        for _ in 0..<6 {
            directory.deleteLastPathComponent()
            let candidate = directory.appendingPathComponent("eval/audio/formats/speech.wav")
            if FileManager.default.fileExists(atPath: candidate.path) {
                fixture = candidate
                break
            }
        }
        audio = try AudioFile(contentsOf: try XCTUnwrap(fixture))
    }

    private func service(_ provider: any TranscriptionProvider) -> TranscriptionService {
        TranscriptionService(
            provider: provider, model: "test-model", systemInstruction: "Transcribe.",
            hedgeStalledRequests: false)
    }

    /// The whole point: one request, and the verbatim transcript survives it.
    func testStyledArrivesInOneRequestAndKeepsTheVerbatimText() async throws {
        let provider = StyleAwareProvider()
        let outcome = try await service(provider).transcribeStyled(
            audio: audio, context: nil, styled: .style(clause: "Formal."),
            secondPassInstruction: "Rewrite formally.")

        XCTAssertTrue(outcome.wasSinglePass)
        XCTAssertEqual(outcome.styled, provider.styled)
        // The invariant that makes ⌘⌥Z possible: the stored transcript is what was said, not the
        // rewrite of it.
        XCTAssertEqual(outcome.result.transcript.transcript, provider.transcript)
        XCTAssertEqual(provider.requests.count, 1)
        XCTAssertEqual(provider.textRequests.count, 0)
    }

    /// A model that ignores the wider schema still owes the user a rewrite.
    func testFallsBackToASecondPassWhenTheModelDropsTheField() async throws {
        let provider = StyleAwareProvider(honoursStyledSchema: false)
        let outcome = try await service(provider).transcribeStyled(
            audio: audio, context: nil, styled: .style(clause: "Formal."),
            secondPassInstruction: "Rewrite formally.")

        XCTAssertFalse(outcome.wasSinglePass)
        XCTAssertEqual(outcome.styled, provider.secondStage)
        XCTAssertEqual(outcome.result.transcript.transcript, provider.transcript)
        XCTAssertEqual(provider.textRequests.count, 1)
    }

    /// A recogniser cannot answer a JSON schema, so the schema must not be asked for at all.
    func testRecogniserIsNotSentTheStyleAndStillGetsRewritten() async throws {
        let provider = StyleAwareProvider(
            grounding: .keyterms(maxTerms: 50, maxCharsPerTerm: 40))
        let outcome = try await service(provider).transcribeStyled(
            audio: audio, context: nil, styled: .style(clause: "Formal."),
            secondPassInstruction: "Rewrite formally.")

        XCTAssertFalse(outcome.wasSinglePass)
        let audioRequest = try XCTUnwrap(provider.audioRequests.first)
        XCTAssertFalse(audioRequest.wantsStyledOutput)
        XCTAssertFalse(audioRequest.systemInstruction.contains("Formal."))
        XCTAssertEqual(outcome.styled, provider.secondStage)
    }

    /// A verbatim dictation must be exactly the request it always was.
    func testVerbatimRequestAsksForNothingExtra() async throws {
        let provider = StyleAwareProvider()
        _ = try await service(provider).transcribe(audio: audio, context: nil)

        let request = try XCTUnwrap(provider.audioRequests.first)
        XCTAssertFalse(request.wantsStyledOutput)
        XCTAssertEqual(request.systemInstruction, "Transcribe.")
    }

    /// The style rule reaches the request that has the audio, which is the point of folding it in.
    func testFoldedInstructionCarriesTheStyleAndThePreservationRule() async throws {
        let provider = StyleAwareProvider()
        _ = try await service(provider).transcribeStyled(
            audio: audio, context: nil, styled: .style(clause: "Formal, no contractions."),
            secondPassInstruction: "Rewrite formally.")

        let request = try XCTUnwrap(provider.audioRequests.first)
        XCTAssertTrue(request.wantsStyledOutput)
        XCTAssertTrue(request.systemInstruction.contains("Formal, no contractions."))
        XCTAssertTrue(request.systemInstruction.contains("Transcribe."))
        // Without this the rewriter is free to "fix" a version number it thinks is stale, which is
        // the failure the two-pass measurement exposed.
        XCTAssertTrue(request.systemInstruction.contains("may not alter any number"))
    }

    /// `styled` is additive: a response without it decodes exactly as before.
    func testSchemaAndDecodingStayBackwardsCompatible() throws {
        let plain = try Transcript.parse(#"{"transcript":"hello","language":"en"}"#)
        XCTAssertNil(plain.styled)

        let both = try Transcript.parse(
            #"{"transcript":"hello","styled":"Hello.","language":"en"}"#)
        XCTAssertEqual(both.styled, "Hello.")

        let required = try XCTUnwrap(Transcript.styledJSONSchema["required"] as? [String])
        XCTAssertEqual(Set(required), ["transcript", "styled", "language"])
        let plainRequired = try XCTUnwrap(Transcript.jsonSchema["required"] as? [String])
        XCTAssertFalse(plainRequired.contains("styled"))
    }
}
