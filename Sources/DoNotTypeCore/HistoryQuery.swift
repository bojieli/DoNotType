import Foundation

/// Filtering and search over stored dictations.
///
/// Lives in the core rather than in each platform's list view so that "find that thing I dictated
/// last Tuesday" behaves identically everywhere, and so the matching rules can be tested without a
/// UI. Search is the point of keeping history at all — a log you cannot search is just disk usage.
public struct HistoryQuery: Sendable, Equatable {
    public enum StatusFilter: String, CaseIterable, Sendable {
        case all
        case completed
        case needsAttention

        public var label: String {
            switch self {
            case .all: "All"
            case .completed: "Completed"
            case .needsAttention: "Needs retry"
            }
        }
    }

    public var text: String = ""
    public var status: StatusFilter = .all
    /// Restrict to dictations made in one app.
    public var appName: String?
    public var since: Date?

    public init(
        text: String = "", status: StatusFilter = .all, appName: String? = nil, since: Date? = nil
    ) {
        self.text = text
        self.status = status
        self.appName = appName
        self.since = since
    }

    public var isEmpty: Bool {
        text.trimmed.isEmpty && status == .all && appName == nil && since == nil
    }

    /// Applies the filters, newest first.
    ///
    /// Matching is diacritic- and case-insensitive so searching "cafe" finds "café", and it
    /// searches the error text as well as the transcript — when you are looking for a failure,
    /// the message is the thing you remember.
    public func apply(to records: [DictationRecord]) -> [DictationRecord] {
        let needle = text.trimmed
        return records
            .filter { record in
                switch status {
                case .all: true
                case .completed: record.status == .completed
                case .needsAttention: record.status != .completed
                }
            }
            .filter { record in
                guard let appName else { return true }
                return record.appName == appName
            }
            .filter { record in
                guard let since else { return true }
                return record.createdAt >= since
            }
            .filter { record in
                guard !needle.isEmpty else { return true }
                return Self.matches(record: record, needle: needle)
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    static func matches(record: DictationRecord, needle: String) -> Bool {
        let haystacks = [
            record.text,
            record.errorMessage ?? "",
            record.appName ?? "",
            record.windowTitle ?? "",
        ]
        return haystacks.contains { $0.containsLoosely(needle) }
    }

    /// Apps that appear in the history, for populating a filter control.
    public static func appNames(in records: [DictationRecord]) -> [String] {
        Array(Set(records.compactMap(\.appName).filter { !$0.isEmpty })).sorted()
    }
}

extension String {
    /// Case- and diacritic-insensitive substring match.
    func containsLoosely(_ needle: String) -> Bool {
        guard !needle.isEmpty else { return true }
        return range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}

extension HistoryStore {
    /// Convenience so callers do not have to load and filter in two steps.
    public func search(_ query: HistoryQuery) -> [DictationRecord] {
        query.apply(to: all())
    }
}
