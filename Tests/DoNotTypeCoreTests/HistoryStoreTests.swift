import Foundation
import XCTest

@testable import DoNotTypeCore

final class HistoryStoreTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dnt-history-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func makeRecord(status: DictationRecord.Status) -> DictationRecord {
        DictationRecord(
            status: status, text: "hello", provider: "gemini",
            model: "gemini-3.6-flash", fidelity: .light)
    }

    /// Without the recording, "Retry" is a button that cannot work — so a failed entry must keep
    /// its audio even when audio retention is off.
    func testFailedRecordsKeepAudioEvenWhenRetentionOfCompletedIsOff() async {
        let store = HistoryStore(directory: directory)
        await store.configure(retention: .forever, keepAudioForCompleted: false)

        let stored = await store.insert(makeRecord(status: .failed), audio: Data([1, 2, 3, 4]))

        XCTAssertNotNil(stored.audioFileName)
        XCTAssertTrue(stored.canRetry)
        let audioURL = await store.audioURL(for: stored)
        XCTAssertNotNil(audioURL)
    }

    func testCompletedRecordsDiscardAudioByDefault() async {
        let store = HistoryStore(directory: directory)
        await store.configure(retention: .forever, keepAudioForCompleted: false)

        let stored = await store.insert(makeRecord(status: .completed), audio: Data([1, 2, 3]))

        XCTAssertNil(stored.audioFileName)
        XCTAssertFalse(stored.canRetry)
    }

    /// A successful retry should release the recording it was holding on to.
    func testSucceedingReleasesTheRetainedAudio() async {
        let store = HistoryStore(directory: directory)
        await store.configure(retention: .forever, keepAudioForCompleted: false)

        var record = await store.insert(makeRecord(status: .failed), audio: Data([1, 2, 3]))
        let audioURL = await store.audioURL(for: record)
        XCTAssertNotNil(audioURL)

        record.status = .completed
        record.text = "transcribed on the second try"
        await store.update(record)

        let refreshed = await store.record(id: record.id)
        XCTAssertEqual(refreshed?.status, .completed)
        XCTAssertNil(refreshed?.audioFileName)
        let bytes = await store.audioBytes()
        XCTAssertEqual(bytes, 0)
    }

    func testRetryableReturnsOldestFirst() async {
        let store = HistoryStore(directory: directory)
        await store.configure(retention: .forever, keepAudioForCompleted: false)

        let older = DictationRecord(
            createdAt: Date(timeIntervalSince1970: 1_000), status: .failed,
            provider: "gemini", model: "m", fidelity: .light)
        let newer = DictationRecord(
            createdAt: Date(timeIntervalSince1970: 2_000), status: .pending,
            provider: "gemini", model: "m", fidelity: .light)

        await store.insert(newer, audio: Data([1]))
        await store.insert(older, audio: Data([1]))

        let queue = await store.retryable()
        XCTAssertEqual(queue.map(\.id), [older.id, newer.id])
    }

    func testNeverRetentionWritesNothingToDisk() async {
        let store = HistoryStore(directory: directory)
        await store.configure(retention: .never, keepAudioForCompleted: false)

        await store.insert(makeRecord(status: .completed), audio: Data([1, 2, 3]))

        let visible = await store.all()
        XCTAssertTrue(visible.isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("history.json").path))
    }

    func testDeleteAllRemovesRecordsAndAudio() async {
        let store = HistoryStore(directory: directory)
        await store.configure(retention: .forever, keepAudioForCompleted: true)

        await store.insert(makeRecord(status: .failed), audio: Data([1, 2, 3, 4, 5]))
        let bytesBeforeDelete = await store.audioBytes()
        XCTAssertGreaterThan(bytesBeforeDelete, 0)

        await store.deleteAll()
        let remaining = await store.all()
        let bytesAfterDelete = await store.audioBytes()
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertEqual(bytesAfterDelete, 0)
    }

    func testRecordsSurviveAcrossInstances() async {
        let first = HistoryStore(directory: directory)
        await first.configure(retention: .forever, keepAudioForCompleted: false)
        await first.insert(makeRecord(status: .completed), audio: nil)

        let second = HistoryStore(directory: directory)
        await second.configure(retention: .forever, keepAudioForCompleted: false)
        let restored = await second.all()
        XCTAssertEqual(restored.count, 1)
    }

    func testPersistedAudioNamesCannotEscapeTheHistoryDirectory() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let outside = directory.appendingPathComponent("outside.wav")
        try Data([1, 2, 3]).write(to: outside)

        let store = HistoryStore(directory: directory)
        await store.configure(retention: .forever, keepAudioForCompleted: true)
        var record = await store.insert(makeRecord(status: .failed), audio: Data([4, 5, 6]))
        record.audioFileName = "../outside.wav"
        await store.update(record)

        let escaped = await store.audioURL(for: record)
        XCTAssertNil(escaped)
        await store.delete(id: record.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    func testFailedIndexReplacementDoesNotDeleteRetryAudio() async throws {
        let store = HistoryStore(directory: directory)
        await store.configure(retention: .forever, keepAudioForCompleted: false)
        let record = await store.insert(makeRecord(status: .failed), audio: Data([1, 2, 3]))
        let originalAudio = await store.audioURL(for: record)
        XCTAssertNotNil(originalAudio)

        // Removing directory write permission makes the next atomic replacement fail while the
        // existing index and recording remain readable.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
        await store.delete(id: record.id)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: directory.path)

        let retainedAudio = await store.audioURL(for: record)
        let inMemoryCount = await store.all().count
        XCTAssertNotNil(retainedAudio)
        XCTAssertEqual(inMemoryCount, 1)
        let restored = HistoryStore(directory: directory)
        let restoredCount = await restored.all().count
        XCTAssertEqual(restoredCount, 1)
    }
}

final class RetryClassificationTests: XCTestCase {
    /// Retrying a bad key just burns the user's time; retrying a 503 is the entire point.
    func testAuthAndDroppedAudioAreNotRetried() {
        XCTAssertFalse(
            TranscriptionService.isTransient(ProviderError.http(status: 401, body: "")))
        XCTAssertFalse(
            TranscriptionService.isTransient(ProviderError.missingAPIKey(envVar: "X")))
        XCTAssertFalse(
            TranscriptionService.isTransient(
                ProviderError.audioSilentlyDropped(provider: "x", model: "y")))
    }

    func testServerAndNetworkFailuresAreRetried() {
        XCTAssertTrue(TranscriptionService.isTransient(ProviderError.http(status: 503, body: "")))
        XCTAssertTrue(TranscriptionService.isTransient(ProviderError.http(status: 429, body: "")))
        XCTAssertTrue(
            TranscriptionService.isTransient(
                NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)))
    }
}
