import Foundation

/// The bridge between the app and the keyboard.
///
/// iOS forbids the obvious architecture. A keyboard extension cannot open an audio session — "Allow
/// Full Access" grants network and a shared container, not the microphone — so the app records and
/// transcribes, and the keyboard only inserts what the app already produced. Everything here exists
/// because of that one restriction.
///
/// The App Group container is the only channel; a Darwin notification wakes the keyboard so a
/// transcript appears without the user having to switch back and forth.
public struct TranscriptStore: Sendable {
    /// Must match the App Group in both targets' entitlements.
    public static let appGroup = "group.app.donottype"

    /// Posted when the app writes a transcript. Darwin notifications carry no payload, which is
    /// fine — it is a hint to re-read the container, not a message.
    public static let didUpdateNotification = "app.donottype.transcripts.didUpdate"

    public struct Entry: Codable, Sendable, Identifiable, Equatable {
        public let id: UUID
        public let text: String
        public let createdAt: Date
        /// True once the keyboard has inserted it, so the list can show what is still unused.
        public var inserted: Bool

        public init(id: UUID = UUID(), text: String, createdAt: Date = Date(), inserted: Bool = false) {
            self.id = id
            self.text = text
            self.createdAt = createdAt
            self.inserted = inserted
        }
    }

    private static let fileName = "transcripts.json"
    private static let limit = 25

    /// Where the transcripts file lives. Defaults to the App Group container, which is the only
    /// place the app and the keyboard can both reach; a test passes a temporary directory instead,
    /// because a unit test has no App Group and would otherwise be asserting against `nil` and
    /// passing for the wrong reason.
    private let directory: URL?

    public init(directory: URL? = TranscriptStore.containerURL) {
        self.directory = directory
    }

    public static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }

    private var fileURL: URL? {
        directory?.appendingPathComponent(Self.fileName)
    }

    public func load() -> [Entry] {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    /// Prepends a transcript and notifies the keyboard.
    @discardableResult
    public func append(_ text: String) -> Entry? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let entry = Entry(text: trimmed)
        var entries = load()
        entries.insert(entry, at: 0)

        // Reports the write, rather than returning the entry whatever happened. Without a shared
        // container -- no Full Access, or an entitlement that did not survive a signing change --
        // there is nowhere to put this, and saying so beats handing back an entry that was never
        // stored and letting the app believe the keyboard has it.
        guard write(Array(entries.prefix(Self.limit))) else { return nil }
        Self.postDidUpdate()
        return entry
    }

    public func markInserted(_ id: UUID) {
        var entries = load()
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].inserted = true
        write(entries)
    }

    public func clear() {
        write([])
        Self.postDidUpdate()
    }

    @discardableResult
    private func write(_ entries: [Entry]) -> Bool {
        guard let url = fileURL, let data = try? JSONEncoder().encode(entries) else { return false }
        // .completeUntilFirstUserAuthentication so the keyboard can still read after a reboot the
        // user has not yet unlocked into.
        do {
            try data.write(
                to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch {
            return false
        }
    }

    // MARK: - Darwin notifications

    public static func postDidUpdate() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(didUpdateNotification as CFString),
            nil, nil, true)
    }

    /// Calls `handler` on the main queue whenever the app stores a new transcript.
    public static func observeUpdates(_ handler: @escaping @Sendable () -> Void) {
        final class Box: @unchecked Sendable {
            let handler: @Sendable () -> Void
            init(_ handler: @escaping @Sendable () -> Void) { self.handler = handler }
        }
        let box = Box(handler)

        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passRetained(box).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                let box = Unmanaged<Box>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async { box.handler() }
            },
            didUpdateNotification as CFString,
            nil,
            .deliverImmediately)
    }
}
