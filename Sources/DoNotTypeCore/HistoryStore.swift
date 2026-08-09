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
    public func retryable() -> [DictationRecord] {
        loadIfNeeded()
        return records.filter(\.canRetry).sorted { $0.createdAt < $1.createdAt }
    }

    // MARK: - Mutation

    /// Stores a record, copying its audio into the history so the caller's temp file can go away.
    @discardableResult
    public func insert(_ record: DictationRecord, audio: Data?) -> DictationRecord {
        loadIfNeeded()
        var stored = record

        // Audio is kept whenever the entry might still need retrying, regardless of the
        // completed-audio setting: without it, "Retry" is a button that cannot work.
        let needsAudio = record.status.isRetryable || keepAudioForCompleted
        if let audio, needsAudio, retention != .never {
            let name = "\(record.id.uuidString).wav"
            try? FileManager.default.createDirectory(
                at: audioDirectory, withIntermediateDirectories: true)
            try? audio.write(to: audioDirectory.appendingPathComponent(name))
            stored.audioFileName = name
        } else {
            stored.audioFileName = nil
        }

        records.insert(stored, at: 0)
        persist()
        return stored
    }

    public func update(_ record: DictationRecord) {
        loadIfNeeded()
        guard let index = records.firstIndex(where: { $0.id == record.id }) else { return }
        var updated = record

        // A successful retry releases the audio unless the user asked to keep it.
        if updated.status == .completed, !keepAudioForCompleted,
            let name = updated.audioFileName
        {
            try? FileManager.default.removeItem(at: audioDirectory.appendingPathComponent(name))
            updated.audioFileName = nil
        }

        records[index] = updated
        persist()
    }

    public func delete(id: UUID) {
        loadIfNeeded()
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        removeAudio(for: records[index])
        records.remove(at: index)
        persist()
    }

    public func deleteAll() {
        loadIfNeeded()
        records.forEach(removeAudio)
        records.removeAll()
        persist()
    }

    /// Bytes of retained audio, so the settings screen can show what history actually costs.
    public func audioBytes() -> Int64 {
        loadIfNeeded()
        return records.compactMap(\.audioFileName).reduce(into: Int64(0)) { total, name in
            let url = audioDirectory.appendingPathComponent(name)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int64
            total += size ?? 0
        }
    }

    public func audioURL(for record: DictationRecord) -> URL? {
        guard let name = record.audioFileName else { return nil }
        let url = audioDirectory.appendingPathComponent(name)
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

        if let data = try? Data(contentsOf: indexURL),
            let decoded = try? JSONDecoder.history.decode([DictationRecord].self, from: data)
        {
            records = decoded
        }
        applyRetention()
    }

    private func applyRetention() {
        guard let maximumAge = retention.maximumAge else { return }
        guard maximumAge > 0 else {
            records.forEach(removeAudio)
            records.removeAll()
            persist()
            return
        }

        let cutoff = Date().addingTimeInterval(-maximumAge)
        let expired = records.filter { $0.createdAt < cutoff }
        guard !expired.isEmpty else { return }
        expired.forEach(removeAudio)
        records.removeAll { $0.createdAt < cutoff }
        persist()
    }

    private func removeAudio(for record: DictationRecord) {
        guard let name = record.audioFileName else { return }
        try? FileManager.default.removeItem(at: audioDirectory.appendingPathComponent(name))
    }

    private func persist() {
        guard retention != .never else {
            try? FileManager.default.removeItem(at: indexURL)
            return
        }
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder.history.encode(records) else { return }
        try? data.write(to: indexURL, options: .atomic)
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
