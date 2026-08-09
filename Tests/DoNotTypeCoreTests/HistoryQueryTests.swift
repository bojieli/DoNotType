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
