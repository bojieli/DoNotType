import Foundation

/// Persists dictations and the audio needed to retry them.
///
/// A JSON index plus an `audio/` directory. SQLite would be the reflex, but the access pattern is
/// "load a few hundred rows at launch, append one at a time" — a single file is simpler to
/// inspect, back up and delete, and deleting your history should be something you can verify with
/// `ls`.
///
/// Retention is enforced on load as well as on write, so a policy change takes effect immediately
/// rather than at the next dictation.
public actor HistoryStore {
    public enum StoreError: LocalizedError {
        case audioMissing(UUID)

        public var errorDescription: String? {
            switch self {
            case .audioMissing: "The recording for this dictation is no longer on disk."
            }
        }
    }

    private let directory: URL
    private let indexURL: URL
    private let audioDirectory: URL
    private var records: [DictationRecord] = []
    private var loaded = false
    private let log = Log("history")

    public private(set) var retention: RetentionPolicy = .forever
    /// Keep audio for successful dictations too. Off by default — the surveyed Typeless install
    /// had 1.8 GB of recordings. Failed entries always keep theirs, so retry stays possible.
    public private(set) var keepAudioForCompleted = false

    public init(directory: URL) {
        self.directory = directory
        self.indexURL = directory.appendingPathComponent("history.json")
        self.audioDirectory = directory.appendingPathComponent("audio", isDirectory: true)
    }

    /// Default location: `~/Library/Application Support/DoNotType` on macOS, the app container
    /// elsewhere.
    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("DoNotType", isDirectory: true)
    }

    public func configure(retention: RetentionPolicy, keepAudioForCompleted: Bool) {
        self.retention = retention
        self.keepAudioForCompleted = keepAudioForCompleted
    }

    public func all() -> [DictationRecord] {
        loadIfNeeded()
        return records
    }

    public func record(id: UUID) -> DictationRecord? {
        loadIfNeeded()
        return records.first { $0.id == id }
    }

    /// Everything that failed or never got sent, oldest first — the natural order to retry in.
    ///
    /// A `cancelled` dictation is retryable from its row but excluded here: cancellation was a
    /// decision, so it is not for a launch-time drain or a bulk retry to second-guess.
    public func retryable() -> [DictationRecord] {
        loadIfNeeded()
        return records.filter { $0.canRetry && $0.status != .cancelled }
            .sorted { $0.createdAt < $1.createdAt }
    }

    // MARK: - Mutation

    /// Stores a record, copying its audio into the history so the caller's temp file can go away.
    @discardableResult
    public func insert(_ record: DictationRecord, audio: Data?) -> DictationRecord {
        loadIfNeeded()
        var stored = record

        // "Don't keep history" also means this process must not keep an in-memory list until it
        // quits. The caller still receives its outcome, but the history view remains empty.
        guard retention != .never else {
            stored.audioFileName = nil
            _ = persist()
            return stored
        }

        // Audio is kept for everything short of a completed entry, regardless of the
        // completed-audio setting: a placeholder is still transcribing, and failed, pending and
        // cancelled entries are all retryable — without the recording, "Retry" is a button that
        // cannot work.
        let needsAudio = record.status != .completed || keepAudioForCompleted
        var writtenAudioURL: URL?
        if let audio, needsAudio {
            let name = "\(record.id.uuidString).wav"
            let url = audioDirectory.appendingPathComponent(name)
            do {
                try FileManager.default.createDirectory(
                    at: audioDirectory, withIntermediateDirectories: true)
                // The recording must be complete before an index can promise that Retry works.
                try audio.write(to: url, options: .atomic)
                stored.audioFileName = name
                writtenAudioURL = url
            } catch {
                try? FileManager.default.removeItem(at: url)
                stored.audioFileName = nil
                log.error(
                    "could not persist retry audio",
                    ["type": String(describing: type(of: error))])
            }
        } else {
            stored.audioFileName = nil
        }

        records.insert(stored, at: 0)
        let persisted = persist()
        if !persisted {
            records.removeFirst()
            if let writtenAudioURL { try? FileManager.default.removeItem(at: writtenAudioURL) }
            stored.audioFileName = nil
        }
        log.debug(
            "stored",
            [
                "id": stored.id.uuidString, "status": stored.status.rawValue,
                "mode": stored.resolvedMode.rawValue,
                "audio": stored.audioFileName == nil ? "discarded" : "kept",
                "persisted": persisted ? "yes" : "no",
                "source": stored.sourceFileName ?? "microphone",
            ])
        return stored
    }

    public func update(_ record: DictationRecord) {
        loadIfNeeded()
        guard let index = records.firstIndex(where: { $0.id == record.id }) else { return }
        let previous = records[index]
        var updated = record
        var audioToRemove: URL?

        // A successful retry releases the audio unless the user asked to keep it.
        if updated.status == .completed, !keepAudioForCompleted {
            if let name = previous.audioFileName { audioToRemove = safeAudioURL(named: name) }
            updated.audioFileName = nil
        }

        records[index] = updated
        if persist() {
            if let audioToRemove { try? FileManager.default.removeItem(at: audioToRemove) }
        } else {
            records[index] = previous
        }
    }

    public func delete(id: UUID) {
        loadIfNeeded()
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        let removed = records.remove(at: index)
        if persist() {
            removeAudio(for: removed)
        } else {
            records.insert(removed, at: index)
        }
    }

    public func deleteAll() {
        loadIfNeeded()
        let removed = records
        records.removeAll()
        if persist() {
            removed.forEach(removeAudio)
        } else {
            records = removed
        }
    }

    /// Bytes of retained audio, so the settings screen can show what history actually costs.
    public func audioBytes() -> Int64 {
        loadIfNeeded()
        return records.compactMap(\.audioFileName).reduce(into: Int64(0)) { total, name in
            guard let url = safeAudioURL(named: name) else { return }
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int64
            total += size ?? 0
        }
    }

    public func audioURL(for record: DictationRecord) -> URL? {
        guard let name = record.audioFileName else { return nil }
        guard let url = safeAudioURL(named: name) else { return nil }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Loads the recording for a retry.
    public func audioFile(for record: DictationRecord) throws -> AudioFile {
        guard let url = audioURL(for: record) else { throw StoreError.audioMissing(record.id) }
        return try AudioFile(contentsOf: url)
    }

    // MARK: - Private

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        var indexReadable = true

        if FileManager.default.fileExists(atPath: indexURL.path) {
            do {
                let data = try Data(contentsOf: indexURL)
                records = try JSONDecoder.history.decode([DictationRecord].self, from: data)
            } catch {
                indexReadable = false
                log.error(
                    "history index is unreadable; leaving it untouched",
                    ["type": String(describing: type(of: error))])
            }
        }
        if indexReadable { normalizeInFlightPlaceholders() }
        if indexReadable { removeOrphanedAudio() }
        applyRetention()
    }

    /// A row still marked `transcribing` on disk means the app quit or crashed mid-flight — the
    /// transcription is not under way any more, so the placeholder becomes what it effectively
    /// is: cancelled. Left alone it would show as "ongoing" forever, and an in-flight placeholder
    /// must never be retried automatically.
    private func normalizeInFlightPlaceholders() {
        var changed = false
        for index in records.indices where records[index].status == .transcribing {
            records[index].status = .cancelled
            changed = true
        }
        if changed { _ = persist() }
    }

    private func applyRetention() {
        guard let maximumAge = retention.maximumAge else { return }
        guard maximumAge > 0 else {
            let removed = records
            records.removeAll()
            if persist() {
                removed.forEach(removeAudio)
            } else {
                records = removed
            }
            return
        }

        let cutoff = Date().addingTimeInterval(-maximumAge)
        let expired = records.filter { $0.createdAt < cutoff }
        guard !expired.isEmpty else { return }
        // Deleting the user's transcripts is worth a line, even when they asked for it: "where did
        // my history go" has a retention policy as its answer, and nothing else records the moment.
        let previous = records
        records.removeAll { $0.createdAt < cutoff }
        if persist() {
            expired.forEach(removeAudio)
            log.info(
                "retention pruned history",
                ["removed": "\(expired.count)", "policy": retention.rawValue])
        } else {
            records = previous
        }
    }

    private func removeAudio(for record: DictationRecord) {
        guard let name = record.audioFileName else { return }
        guard let url = safeAudioURL(named: name) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Completes a transaction interrupted after its index commit or before an insert commit.
    /// An unreadable index deliberately skips this: those files may be the only recoverable copy.
    private func removeOrphanedAudio() {
        let referenced = Set(records.compactMap(\.audioFileName))
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: audioDirectory, includingPropertiesForKeys: nil)
        else { return }

        var removed = 0
        for file in files {
            let name = file.lastPathComponent
            guard file.pathExtension.lowercased() == "wav",
                UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil,
                !referenced.contains(name)
            else { continue }
            do {
                try FileManager.default.removeItem(at: file)
                removed += 1
            } catch {
                log.warning(
                    "could not remove orphaned history audio",
                    ["type": String(describing: type(of: error))])
            }
        }
        if removed > 0 { log.info("removed orphaned history audio", ["files": "\(removed)"]) }
    }

    /// A persisted record is data, not permission to inspect or delete outside History/audio.
    private func safeAudioURL(named name: String) -> URL? {
        guard !name.isEmpty, !name.contains("/"), !name.contains("\\"),
            URL(fileURLWithPath: name).lastPathComponent == name
        else {
            log.warning("ignored an unsafe audio filename in history")
            return nil
        }
        return audioDirectory.appendingPathComponent(name)
    }

    @discardableResult
    private func persist() -> Bool {
        guard retention != .never else {
            do {
                if FileManager.default.fileExists(atPath: indexURL.path) {
                    try FileManager.default.removeItem(at: indexURL)
                }
                return true
            } catch {
                log.error(
                    "could not remove disabled history",
                    ["type": String(describing: type(of: error))])
                return false
            }
        }
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder.history.encode(records)
            try data.write(to: indexURL, options: .atomic)
            return true
        } catch {
            log.error(
                "could not persist history; the previous index is still intact",
                ["type": String(describing: type(of: error))])
            return false
        }
    }
}

extension JSONEncoder {
    static var history: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var history: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
