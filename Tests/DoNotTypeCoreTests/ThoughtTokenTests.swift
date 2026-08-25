import XCTest

@testable import DoNotTypeCore

/// `total_thought_tokens` is a sibling of `total_output_tokens`, not a part of it.
///
/// Measured 2026-08-25 on a 22-second clip: `minimal` and `low` both report exactly 0 on
/// `gemini-3.5-flash` and `gemini-3.6-flash`, `medium` reports 500 and 700, and `total_tokens`
/// equals input + output + thought (881 = 802 + 79 + 0; 1383 = 802 + 81 + 500).
///
/// Before this the field was parsed by nobody, so the cost of a thinking level was invisible in
/// history and in the logs — and `docs/MODELS.md` had reasoned about thinking from the output
/// count, which could never have shown it.
final class GeminiThoughtTokenTests: XCTestCase {
    private func usage(_ json: String) throws -> TokenUsage {
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        return GeminiProvider(apiKey: "test").parseUsageForTesting(object)
    }

    func testMediumThinkingIsReportedSeparatelyFromOutput() throws {
        let reading = try usage(
            #"""
            {"total_tokens": 1383, "total_input_tokens": 802, "total_output_tokens": 81,
             "total_thought_tokens": 500,
             "input_tokens_by_modality": [{"modality": "audio", "tokens": 550}]}
            """#)
        XCTAssertEqual(reading.completionTokens, 81)
        XCTAssertEqual(reading.thoughtTokens, 500)
        XCTAssertEqual(reading.audioTokens, 550)
    }

    /// The reading at `minimal`, and the one that must not be mistaken for silence.
    func testAZeroThoughtCountIsKeptRatherThanTreatedAsMissing() throws {
        let reading = try usage(
            #"""
            {"total_tokens": 881, "total_input_tokens": 802, "total_output_tokens": 79,
             "total_thought_tokens": 0,
             "input_tokens_by_modality": [{"modality": "audio", "tokens": 550}]}
            """#)
        XCTAssertEqual(reading.thoughtTokens, 0)
    }

    func testAProviderThatDoesNotReportThinkingSaysNothingRatherThanZero() throws {
        let reading = try usage(
            #"""
            {"total_input_tokens": 802, "total_output_tokens": 79,
             "input_tokens_by_modality": [{"modality": "audio", "tokens": 550}]}
            """#)
        XCTAssertNil(reading.thoughtTokens)
    }

    /// The arithmetic the API's own totals imply, asserted so a future field rename is caught by
    /// something other than a surprised reader of a bill.
    func testTotalIsInputPlusOutputPlusThought() throws {
        let reading = try usage(
            #"""
            {"total_tokens": 1583, "total_input_tokens": 802, "total_output_tokens": 81,
             "total_thought_tokens": 700,
             "input_tokens_by_modality": [{"modality": "audio", "tokens": 550}]}
            """#)
        XCTAssertEqual(
            (reading.promptTokens ?? 0) + (reading.completionTokens ?? 0)
                + (reading.thoughtTokens ?? 0), 1583)
    }
}
