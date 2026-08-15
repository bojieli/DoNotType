import Foundation
import XCTest

@testable import DoNotTypeCore

final class HistoryQueryTests: XCTestCase {
    private func record(
        _ text: String, status: DictationRecord.Status = .completed, app: String? = nil,
        error: String? = nil, minutesAgo: Int = 0
    ) -> DictationRecord {
        DictationRecord(
            createdAt: Date().addingTimeInterval(TimeInterval(-60 * minutesAgo)),
            status: status, text: text, errorMessage: error,
            provider: "gemini", model: "m", fidelity: .light, appName: app)
    }

    private lazy var corpus: [DictationRecord] = [
        record("Ship the pricing page today", app: "Slack", minutesAgo: 5),
        record("Refactor the ContextEncoder", app: "Xcode", minutesAgo: 60),
        record("", status: .failed, app: "Slack", error: "Rate limited — saved", minutesAgo: 10),
        record("Meet at the café at noon", app: "Mail", minutesAgo: 2_000),
        record("", status: .pending, app: "Xcode", error: "Offline when recorded.", minutesAgo: 1),
    ]

    func testEmptyQueryReturnsEverythingNewestFirst() {
        let results = HistoryQuery().apply(to: corpus)
        XCTAssertEqual(results.count, corpus.count)
        XCTAssertEqual(results.first?.appName, "Xcode")  // the 1-minute-old pending one
        XCTAssertEqual(results.last?.text, "Meet at the café at noon")
    }

    func testTextSearchIsCaseInsensitive() {
        var query = HistoryQuery()
        query.text = "PRICING"
        XCTAssertEqual(query.apply(to: corpus).count, 1)
    }

    /// Searching "cafe" should find "café" — otherwise search fails exactly when the transcript
    /// contains the sort of word people search for.
    func testTextSearchIgnoresDiacritics() {
        var query = HistoryQuery()
        query.text = "cafe"
        XCTAssertEqual(query.apply(to: corpus).first?.text, "Meet at the café at noon")
    }

    /// When hunting for a failure, the error message is what you remember, not the transcript —
    /// which is empty anyway.
    func testSearchCoversErrorMessages() {
        var query = HistoryQuery()
        query.text = "rate limited"
        let results = query.apply(to: corpus)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.status, .failed)
    }

    func testSearchCoversAppNames() {
        var query = HistoryQuery()
        query.text = "xcode"
        XCTAssertEqual(query.apply(to: corpus).count, 2)
    }

    func testNeedsAttentionFiltersToRetryableStates() {
        var query = HistoryQuery()
        query.status = .needsAttention
        let results = query.apply(to: corpus)
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.allSatisfy { $0.status != .completed })
    }

    func testAppFilter() {
        var query = HistoryQuery()
        query.appName = "Slack"
        XCTAssertEqual(query.apply(to: corpus).count, 2)
    }

    func testSinceFilter() {
        var query = HistoryQuery()
        query.since = Date().addingTimeInterval(-3_600)
        let results = query.apply(to: corpus)
        XCTAssertFalse(results.contains { $0.text.contains("café") })
    }

    func testFiltersCombine() {
        var query = HistoryQuery()
        query.appName = "Slack"
        query.status = .needsAttention
        XCTAssertEqual(query.apply(to: corpus).count, 1)
    }

    func testAppNamesAreDeduplicatedAndSorted() {
        XCTAssertEqual(HistoryQuery.appNames(in: corpus), ["Mail", "Slack", "Xcode"])
    }

    func testIsEmptyReflectsWhetherAnyFilterIsSet() {
        XCTAssertTrue(HistoryQuery().isEmpty)
        var query = HistoryQuery()
        query.text = "x"
        XCTAssertFalse(query.isEmpty)
    }
}

final class FailureAdviceTests: XCTestCase {
    /// Every message has to answer "what do I do now?".
    func testOfflineIsQueuedAndNeedsNoAction() {
        let advice = FailureAdvice.describe(
            ProviderError.http(status: 500, body: ""), isOnline: false)
        XCTAssertTrue(advice.isQueued)
        XCTAssertFalse(advice.needsUserAction)
        XCTAssertTrue(advice.message.lowercased().contains("reconnect"))
    }

    func testBadKeyNeedsUserActionAndIsNotQueued() {
        let advice = FailureAdvice.describe(ProviderError.http(status: 401, body: ""))
        XCTAssertTrue(advice.needsUserAction)
        XCTAssertFalse(advice.isRetryable)
        XCTAssertFalse(advice.isQueued)
    }

    /// The exact response xAI returns for a bad key: a 400, not a 401. Classified by status alone
    /// it reads as a transient request problem and the user is told to retry a dictation that is
    /// guaranteed to fail the same way.
    func testABadKeyReportedAsA400IsStillABadKey() {
        let advice = FailureAdvice.describe(
            ProviderError.http(
                status: 400,
                body: "Incorrect API key provided. You can obtain an API key from "
                    + "https://console.x.ai."))
        XCTAssertTrue(advice.needsUserAction)
        XCTAssertFalse(advice.isRetryable)
        XCTAssertTrue(advice.message.contains("Settings"))
    }

    /// The reattribution above stays narrow: an ordinary 400 is this app's bug, not the user's.
    func testAnOrdinary400IsNotBlamedOnTheKey() {
        let advice = FailureAdvice.describe(
            ProviderError.http(status: 400, body: "unsupported sample rate"))
        XCTAssertFalse(advice.needsUserAction)
        XCTAssertTrue(advice.isQueued)
    }

    func testUnavailableModelPointsAtSettings() {
        let advice = FailureAdvice.describe(ProviderError.http(status: 404, body: ""))
        XCTAssertTrue(advice.needsUserAction)
        XCTAssertTrue(advice.message.contains("Settings"))
    }

    func testRateLimitIsQueuedNotFatal() {
        let advice = FailureAdvice.describe(ProviderError.http(status: 429, body: ""))
        XCTAssertTrue(advice.isQueued)
        XCTAssertTrue(advice.isRetryable)
        XCTAssertFalse(advice.needsUserAction)
    }

    /// A fabricated transcript is worse than an error, so this must never look retryable.
    func testSilentlyDroppedAudioDemandsAProviderChange() {
        let advice = FailureAdvice.describe(
            ProviderError.audioSilentlyDropped(provider: "x", model: "y"))
        XCTAssertFalse(advice.isRetryable)
        XCTAssertTrue(advice.needsUserAction)
        XCTAssertTrue(advice.message.lowercased().contains("invented"))
    }

    func testNetworkErrorsAreQueued() {
        let advice = FailureAdvice.describe(
            NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut))
        XCTAssertTrue(advice.isQueued)
        XCTAssertTrue(advice.isRetryable)
    }
}

final class PromptStoreTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dnt-prompt-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private static let valid = """
        <!-- BEGIN SYSTEM -->
        Engine. 5. {{FIDELITY_RULE}}
        <!-- END SYSTEM -->

        ### raw
        ```
        RAW
        ```
        ### light
        ```
        LIGHT
        ```
        ### tidy
        ```
        TIDY
        ```
        """

    func testValidPromptSavesAndBecomesActive() throws {
        let store = PromptStore(directory: directory)
        XCTAssertFalse(store.hasCustomPrompt)

        try store.save(Self.valid)
        XCTAssertTrue(store.hasCustomPrompt)

        let bundled = directory.appendingPathComponent("bundled.md")
        try Self.valid.write(to: bundled, atomically: true, encoding: .utf8)
        let instruction = try store.builder(default: bundled).systemInstruction(fidelity: .light)
        XCTAssertTrue(instruction.contains("LIGHT"))
    }

    /// A prompt that cannot build would fail mid-dictation rather than at the moment of editing.
    func testInvalidPromptsAreRejectedBeforeTheyCanBreakADictation() {
        let store = PromptStore(directory: directory)

        XCTAssertThrowsError(try store.save("")) { error in
            XCTAssertEqual(error as? PromptStore.ValidationError, .empty)
        }
        XCTAssertThrowsError(try store.save("no markers at all")) { error in
            XCTAssertEqual(error as? PromptStore.ValidationError, .missingSystemMarkers)
        }
        XCTAssertThrowsError(
            try store.save("<!-- BEGIN SYSTEM -->\nno placeholder\n<!-- END SYSTEM -->")
        ) { error in
            XCTAssertEqual(error as? PromptStore.ValidationError, .missingFidelityPlaceholder)
        }
        XCTAssertFalse(store.hasCustomPrompt, "a rejected prompt must not be written")
    }

    /// Every fidelity must resolve, or switching to one later breaks mid-use.
    func testMissingFidelitySectionIsRejected() {
        let missingTidy = Self.valid.replacingOccurrences(
            of: "### tidy\n```\nTIDY\n```", with: "")
        XCTAssertThrowsError(try PromptStore(directory: directory).save(missingTidy))
    }

    func testRestoreDefaultRemovesTheOverride() throws {
        let store = PromptStore(directory: directory)
        try store.save(Self.valid)
        XCTAssertTrue(store.hasCustomPrompt)

        try store.restoreDefault()
        XCTAssertFalse(store.hasCustomPrompt)
    }

    func testFallsBackToTheBundledPromptWhenNoOverrideExists() throws {
        let bundled = directory.appendingPathComponent("bundled.md")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.valid.write(to: bundled, atomically: true, encoding: .utf8)

        let template = try PromptStore(directory: directory).activeTemplate(default: bundled)
        XCTAssertTrue(template.contains("{{FIDELITY_RULE}}"))
    }

    /// The shipped prompt has to pass its own validator.
    func testShippedPromptIsValid() throws {
        guard let url = PromptBuilder.findPromptFile() else {
            throw XCTSkip("PROMPT.md not found from the test working directory")
        }
        try PromptStore.validate(try String(contentsOf: url, encoding: .utf8))
    }
}

/// The rewrite lives beside the transcript rather than replacing it — the property that makes
/// "revert to what I said" possible at all.
final class DeliveredTextTests: XCTestCase {
    private func record(text: String, styled: String? = nil) -> DictationRecord {
        DictationRecord(
            status: .completed, text: text, styledText: styled,
            style: styled == nil ? nil : .formal,
            provider: "gemini", model: "m", fidelity: .light)
    }

    func testDeliveredTextIsTheStyledVersionWhenOneExists() {
        XCTAssertEqual(record(text: "so uh ship it", styled: "Please ship it.").deliveredText,
                       "Please ship it.")
    }

    func testDeliveredTextFallsBackToTheTranscript() {
        XCTAssertEqual(record(text: "ship it").deliveredText, "ship it")
    }

    /// The verbatim text must survive a rewrite, or the whole separation is pointless.
    func testVerbatimSurvivesAlongsideTheRewrite() {
        let stored = record(text: "so uh ship it", styled: "Please ship it.")
        XCTAssertEqual(stored.text, "so uh ship it")
        XCTAssertNotEqual(stored.text, stored.deliveredText)
    }

    func testSummaryShowsWhatWasActuallyInserted() {
        XCTAssertEqual(record(text: "raw", styled: "polished").summary, "polished")
    }

    /// Round-tripping must not drop the styled version, or history loses which text was inserted.
    func testStyledTextSurvivesEncoding() throws {
        let original = record(text: "raw words", styled: "Polished words.")
        let data = try JSONEncoder.history.encode([original])
        let decoded = try JSONDecoder.history.decode([DictationRecord].self, from: data)

        XCTAssertEqual(decoded.first?.text, "raw words")
        XCTAssertEqual(decoded.first?.styledText, "Polished words.")
        XCTAssertEqual(decoded.first?.style, .formal)
    }

    // MARK: - What the provider itself said

    /// A status code cannot express "this model does not accept audio input". The provider can,
    /// and it knows what it refused. This was read only to sniff for the words "api key" and then
    /// discarded, so the single most useful sentence available never reached anybody.
    func testTheProvidersOwnExplanationSurvives() {
        let advice = FailureAdvice.describe(
            ProviderError.http(
                status: 400,
                body: #"{"error": {"message": "This model does not accept audio input."}}"#))
        XCTAssertTrue(advice.message.contains("does not accept audio input"), advice.message)
    }

    func testAMessageAtTheTopLevelIsFoundToo() {
        let advice = FailureAdvice.describe(
            ProviderError.http(status: 404, body: #"{"message": "Unknown model: gemini-9"}"#))
        XCTAssertTrue(advice.message.contains("gemini-9"), advice.message)
    }

    /// Everything that is not a sentence is dropped rather than pasted into the corner of the
    /// screen. A user reading an overlay is not debugging.
    func testNothingUnreadableIsShown() {
        let bodies = [
            #"{"trace_id": "abc123", "status": {"code": 13}}"#,
            "<html><head><title>502 Bad Gateway</title></head></html>",
            String(repeating: "{\"a\":1},", count: 400),
        ]
        for body in bodies {
            let advice = FailureAdvice.describe(ProviderError.http(status: 500, body: body))
            XCTAssertFalse(advice.message.contains("{"), advice.message)
            XCTAssertFalse(advice.message.contains("<"), advice.message)
            XCTAssertLessThanOrEqual(advice.message.count, 220, advice.message)
        }
    }

    func testAShortGatewayMessageIsKept() {
        let advice = FailureAdvice.describe(
            ProviderError.http(status: 503, body: "upstream connect error before headers"))
        XCTAssertTrue(advice.message.contains("upstream connect error"), advice.message)
    }

    func testAMultiLineMessageBecomesOneLine() {
        let advice = FailureAdvice.describe(
            ProviderError.http(status: 400, body: "it failed\nand here is why\nat length"))
        XCTAssertFalse(advice.message.contains("\n"), advice.message)
    }

    // MARK: - Advice that can actually work

    /// The comment above the 400 case makes this argument and the default branch ignored it: a 4xx
    /// is a request this app got wrong and will get wrong again identically. "Saved, retry from
    /// History" was being offered for every unhandled one.
    func testAnUnhandledClientErrorDoesNotPromiseARetryThatCannotWork() {
        for status in [400, 415, 422] {
            let advice = FailureAdvice.describe(ProviderError.http(status: status, body: ""))
            XCTAssertFalse(advice.isRetryable, "HTTP \(status) claimed to be retryable")
            XCTAssertTrue(
                advice.message.contains("not change it"),
                "HTTP \(status): \(advice.message)")
            // Nothing in Settings fixes a malformed request. Sending somebody there when nothing
            // they can change will help is worse than telling them it is not their fault.
            XCTAssertFalse(advice.needsUserAction, "HTTP \(status)")
            XCTAssertTrue(advice.isQueued, "HTTP \(status): the recording is still kept")
        }
    }

    func testAServerErrorIsStillWorthRetrying() {
        for status in [500, 502, 503, 429, 408] {
            let advice = FailureAdvice.describe(ProviderError.http(status: status, body: ""))
            XCTAssertTrue(advice.isRetryable, "HTTP \(status) should be retryable")
            XCTAssertTrue(advice.isQueued, "HTTP \(status) should be kept")
        }
    }

    /// The one that produced a wrong answer rather than an unhelpful one: too large is not a
    /// transient fault, and retrying it identically wastes the user's time twice.
    func testATooLargeRecordingIsNotOfferedAsARetry() {
        let advice = FailureAdvice.describe(ProviderError.http(status: 413, body: ""))
        XCTAssertFalse(advice.isRetryable)
        XCTAssertTrue(advice.message.contains("too large"), advice.message)
    }

    /// The retry loop and the sentence shown for the same failure have to agree. Telling somebody
    /// "saved, retry from History" about a failure the retry loop has already written off is worse
    /// than saying nothing, and the two rules live in different files.
    func testTheGuidanceAndTheRetryRuleAgreeAboutEveryStatus() {
        for status in [400, 401, 403, 404, 408, 413, 422, 429, 500, 502, 503] {
            let error = ProviderError.http(status: status, body: "")
            XCTAssertEqual(
                TranscriptionService.isTransient(error),
                FailureAdvice.describe(error).isRetryable,
                "HTTP \(status): the retry rule and the advice disagree")
        }
    }
}
