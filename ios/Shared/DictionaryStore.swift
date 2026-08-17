import DoNotTypeCore
import Foundation

/// The app/keyboard shared personal dictionary, with manual and learned entries kept distinct.
public struct DictionaryStore: Sendable {
    public struct Snapshot: Codable, Sendable, Equatable {
        public var manual: [String]
        public var learned: [String]
        public var learnsFromEdits: Bool

        public init(manual: [String] = [], learned: [String] = [], learnsFromEdits: Bool = false) {
            self.manual = manual
            self.learned = learned
            self.learnsFromEdits = learnsFromEdits
        }

        public var all: [String] { PersonalDictionary.sanitized(manual + learned) }
    }

    private let directory: URL?
    private var fileURL: URL? { directory?.appendingPathComponent("dictionary.json") }

    public init(directory: URL? = TranscriptStore.containerURL) { self.directory = directory }

    public func load() -> Snapshot {
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
            let decoded = try? JSONDecoder().decode(Snapshot.self, from: data)
        else { return Snapshot() }
        return sanitized(decoded)
    }

    @discardableResult
    public func setLearning(_ enabled: Bool) throws -> Snapshot {
        try update { $0.learnsFromEdits = enabled }
    }

    @discardableResult
    public func add(_ raw: String) throws -> Snapshot {
        try update { snapshot in
            let combined = try PersonalDictionary.adding(raw, to: snapshot.all)
            guard let added = combined.last else { return }
            snapshot.manual.append(added)
        }
    }

    @discardableResult
    public func replace(_ original: String, with raw: String, learned: Bool) throws -> Snapshot {
        try update { snapshot in
            let all = snapshot.all
            let updated = try PersonalDictionary.replacing(original, with: raw, in: all)
            guard let oldIndex = all.firstIndex(of: original) else { return }
            let replacement = updated[oldIndex]
            if learned, let index = snapshot.learned.firstIndex(of: original) {
                snapshot.learned[index] = replacement
            } else if let index = snapshot.manual.firstIndex(of: original) {
                snapshot.manual[index] = replacement
            }
        }
    }

    @discardableResult
    public func remove(_ term: String, learned: Bool) throws -> Snapshot {
        try update { snapshot in
            if learned { snapshot.learned.removeAll { $0 == term } }
            else { snapshot.manual.removeAll { $0 == term } }
        }
    }

    @discardableResult
    public func importCSV(_ data: Data) throws -> (Snapshot, Int) {
        let imported = try PersonalDictionary.entries(fromCSV: data)
        let before = load()
        let merged = try PersonalDictionary.importing(imported, into: before.all)
        let seen = Set(before.all.map { $0.lowercased() })
        let additions = merged.filter { !seen.contains($0.lowercased()) }
        var snapshot = before
        snapshot.manual.append(contentsOf: additions)
        try write(sanitized(snapshot))
        return (sanitized(snapshot), additions.count)
    }

    /// Adds candidates selected by the shared spelling-only diff and returns only genuinely new terms.
    @discardableResult
    public func learn(_ candidates: [String]) throws -> (Snapshot, [String]) {
        var snapshot = load()
        var all = snapshot.all
        var added: [String] = []
        for raw in candidates {
            guard all.count < PersonalDictionary.maxTerms,
                let next = try? PersonalDictionary.adding(raw, to: all),
                let term = next.last
            else { continue }
            all = next
            snapshot.learned.append(term)
            added.append(term)
        }
        snapshot = sanitized(snapshot)
        if !added.isEmpty { try write(snapshot) }
        return (snapshot, added)
    }

    @discardableResult
    public func forgetLearned(_ terms: [String]) throws -> Snapshot {
        let removed = Set(terms.map { $0.lowercased() })
        return try update { snapshot in
            snapshot.learned.removeAll { removed.contains($0.lowercased()) }
        }
    }

    private func sanitized(_ raw: Snapshot) -> Snapshot {
        let manual = PersonalDictionary.sanitized(raw.manual)
        let manualKeys = Set(manual.map { $0.lowercased() })
        let learned = PersonalDictionary.sanitized(raw.learned)
            .filter { !manualKeys.contains($0.lowercased()) }
            .prefix(PersonalDictionary.maxTerms - manual.count)
        return Snapshot(
            manual: manual, learned: Array(learned), learnsFromEdits: raw.learnsFromEdits)
    }

    private func update(_ change: (inout Snapshot) throws -> Void) throws -> Snapshot {
        var snapshot = load()
        try change(&snapshot)
        snapshot = sanitized(snapshot)
        try write(snapshot)
        return snapshot
    }

    private func write(_ snapshot: Snapshot) throws {
        guard let fileURL else {
            throw CocoaError(.fileNoSuchFile, userInfo: [
                NSLocalizedDescriptionKey: "The shared keyboard container is unavailable."
            ])
        }
        let data = try JSONEncoder().encode(snapshot)
        try data.write(
            to: fileURL,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

/// A short-lived correction anchor that survives switching to another keyboard and back.
public struct CorrectionObservationStore: Sendable {
    public struct Pending: Codable, Sendable, Equatable {
        public var documentID: UUID
        public var prefix: String
        public var suffix: String
        public var inserted: String
        public var createdAt: Date

        public init(
            documentID: UUID, prefix: String, suffix: String, inserted: String,
            createdAt: Date = Date()
        ) {
            self.documentID = documentID
            self.prefix = prefix
            self.suffix = suffix
            self.inserted = inserted
            self.createdAt = createdAt
        }
    }

    private let directory: URL?
    private var fileURL: URL? { directory?.appendingPathComponent("pending-correction.json") }
    public init(directory: URL? = TranscriptStore.containerURL) { self.directory = directory }

    public func load() -> Pending? {
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
            let pending = try? JSONDecoder().decode(Pending.self, from: data),
            Date().timeIntervalSince(pending.createdAt) < 60
        else { return nil }
        return pending
    }

    public func save(_ pending: Pending) {
        guard let fileURL, let data = try? JSONEncoder().encode(pending) else { return }
        try? data.write(
            to: fileURL,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    public func clear() {
        guard let fileURL else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }
}
