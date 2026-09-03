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

    /// A placeholder is written the moment transcription starts, and its audio must survive with
    /// it — the row is what a later cancellation or failure turns into something retryable.
    func testTranscribingPlaceholderKeepsItsAudio() async {
        let store = HistoryStore(directory: directory)
        await store.configure(retention: .forever, keepAudioForCompleted: false)

        let stored = await store.insert(makeRecord(status: .transcribing), audio: Data([1, 2, 3]))

        XCTAssertNotNil(stored.audioFileName)
        let audioURL = await store.audioURL(for: stored)
        XCTAssertNotNil(audioURL)
        // But it is not retryable while it is still in flight.
        XCTAssertFalse(stored.canRetry)
    }

    /// The placeholder finishing releases the recording it was holding, exactly as a succeeded
    /// retry does.
    func testCompletingAPlaceholderReleasesItsAudio() async {
        let store = HistoryStore(directory: directory)
        await store.configure(retention: .forever, keepAudioForCompleted: false)

        var record = await store.insert(makeRecord(status: .transcribing), audio: Data([1, 2, 3]))
        let audioBeforeUpdate = await store.audioURL(for: record)
        XCTAssertNotNil(audioBeforeUpdate)

        record.status = .completed
        record.text = "transcribed"
        await store.update(record)

        let refreshed = await store.record(id: record.id)
        XCTAssertEqual(refreshed?.status, .completed)
        XCTAssertNil(refreshed?.audioFileName)
        let bytes = await store.audioBytes()
        XCTAssertEqual(bytes, 0)
    }

    func testCompletingAPlaceholderKeepsAudioWhenKeepAudioIsOn() async {
        let store = HistoryStore(directory: directory)
        await store.configure(retention: .forever, keepAudioForCompleted: true)

        var record = await store.insert(makeRecord(status: .transcribing), audio: Data([1, 2, 3]))
        record.status = .completed
        record.text = "transcribed"
        await store.update(record)

        let refreshed = await store.record(id: record.id)
        XCTAssertEqual(refreshed?.status, .completed)
        XCTAssertNotNil(refreshed?.audioFileName)
        let keptAudio = await store.audioURL(for: record)
        XCTAssertNotNil(keptAudio)
    }

    /// A cancelled dictation keeps its recording, so the per-row Retry can still send it.
    func testCancellingAPlaceholderKeepsAudioAndStaysRetryable() async {
        let store = HistoryStore(directory: directory)
        await store.configure(retention: .forever, keepAudioForCompleted: false)

        var record = await store.insert(makeRecord(status: .transcribing), audio: Data([1, 2, 3]))
        record.status = .cancelled
        await store.update(record)

        let refreshed = await store.record(id: record.id)
        XCTAssertEqual(refreshed?.status, .cancelled)
        XCTAssertEqual(refreshed?.canRetry, true)
        let keptAudio = await store.audioURL(for: record)
        XCTAssertNotNil(keptAudio)
    }

    /// A row still marked transcribing on disk means the app quit mid-flight: it loads back as
    /// cancelled, never as something still under way.
    func testInFlightPlaceholderLoadsBackAsCancelled() async {
        let first = HistoryStore(directory: directory)
        await first.configure(retention: .forever, keepAudioForCompleted: false)
        let placeholder = await first.insert(
            makeRecord(status: .transcribing), audio: Data([1, 2, 3]))

        let second = HistoryStore(directory: directory)
        await second.configure(retention: .forever, keepAudioForCompleted: false)
        let restored = await second.record(id: placeholder.id)

        XCTAssertEqual(restored?.status, .cancelled)
        XCTAssertEqual(restored?.canRetry, true)
        let keptAudio = await second.audioURL(for: placeholder)
        XCTAssertNotNil(keptAudio)
    }

    /// The automatic drain retries what failed or never sent — never what the user cancelled.
    func testRetryableExcludesCancelledButIncludesFailedAndPending() async {
        let store = HistoryStore(directory: directory)
        await store.configure(retention: .forever, keepAudioForCompleted: false)

        let failed = await store.insert(makeRecord(status: .failed), audio: Data([1]))
        let pending = await store.insert(makeRecord(status: .pending), audio: Data([1]))
        let cancelled = await store.insert(makeRecord(status: .cancelled), audio: Data([1]))

        let queue = await store.retryable()
        XCTAssertEqual(Set(queue.map(\.id)), [failed.id, pending.id])
        XCTAssertFalse(queue.contains { $0.id == cancelled.id })
        // The cancelled row itself still offers its own Retry button.
        XCTAssertTrue(cancelled.canRetry)
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

    func testRestartRemovesOnlyUnreferencedManagedAudio() async throws {
        let first = HistoryStore(directory: directory)
        await first.configure(retention: .forever, keepAudioForCompleted: false)
        let retained = await first.insert(makeRecord(status: .failed), audio: Data([1, 2, 3]))

        let audioDirectory = directory.appendingPathComponent("audio")
        let orphan = audioDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        let unrelated = audioDirectory.appendingPathComponent("notes.wav")
        try Data([4, 5, 6]).write(to: orphan)
        try Data([7, 8, 9]).write(to: unrelated)

        let restarted = HistoryStore(directory: directory)
        _ = await restarted.all()

        let retainedURL = await restarted.audioURL(for: retained)
        XCTAssertNotNil(retainedURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    func testUnreadableIndexPreservesUnreferencedAudioForRecovery() async throws {
        let audioDirectory = directory.appendingPathComponent("audio")
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        let recoverable = audioDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        try Data([1, 2, 3]).write(to: recoverable)
        try Data("not json".utf8).write(to: directory.appendingPathComponent("history.json"))

        _ = await HistoryStore(directory: directory).all()

        XCTAssertTrue(FileManager.default.fileExists(atPath: recoverable.path))
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
