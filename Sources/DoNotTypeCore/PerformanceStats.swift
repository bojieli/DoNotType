import Foundation

/// What the app has actually cost you, computed from the history.
///
/// This exists because "is it fast?" and "is it working?" are questions the user is otherwise left
/// to answer by feel, and feel is unreliable — one bad dictation is remembered far more vividly
/// than fifty good ones. The numbers here are also the honest way to compare providers and models:
/// the docs' latency claims are not measured on your microphone, your network or your speech.
///
/// Median and p95 rather than a mean. A mean latency is dragged upwards by the one dictation that
/// hit a retry storm, which makes the typical case look worse than it is; p95 is the separate and
/// more useful question of how bad the bad ones get.
public struct PerformanceStats: Sendable, Equatable {
    public var total: Int = 0
    public var completed: Int = 0
    public var failed: Int = 0
    public var pending: Int = 0
    /// Dictations that needed at least one retry — the honest measure of network trouble.
    public var retried: Int = 0

    public var medianLatency: Double?
    public var p95Latency: Double?
    public var medianRequest: Double?

    /// Total seconds of speech transcribed.
    public var spokenSeconds: Double = 0
    /// Total words delivered.
    public var words: Int = 0
    public var audioTokens: Int = 0
    public var promptTokens: Int = 0
    public var completionTokens: Int = 0

    public var successRate: Double? {
        total == 0 ? nil : Double(completed) / Double(total)
    }

    /// Wait per second of speech. Below 1.0 means transcription finishes faster than it took to
    /// say — the number that decides whether dictation feels immediate or laborious.
    public var realTimeFactor: Double? {
        guard let medianLatency, spokenSeconds > 0, completed > 0 else { return nil }
        let meanSpoken = spokenSeconds / Double(completed)
        return meanSpoken > 0 ? medianLatency / meanSpoken : nil
    }

    /// Speaking rate. Useful mostly as a sanity check: a wildly low figure usually means the model
    /// is dropping the ends of recordings rather than that the user talks slowly.
    public var wordsPerMinute: Double? {
        guard spokenSeconds > 60 else { return nil }
        return Double(words) / (spokenSeconds / 60)
    }

    /// Typing time saved, at a generous 40 wpm for the kind of prose people dictate.
    ///
    /// An estimate, and labelled as one wherever it is shown. It is here because "you have
    /// dictated 12,000 words" means nothing to most people and "about five hours of typing" means
    /// something to everyone.
    public var estimatedTypingMinutesSaved: Double {
        Double(words) / 40
    }

    public init() {}

    public static func compute(from records: [DictationRecord]) -> PerformanceStats {
        var stats = PerformanceStats()
        stats.total = records.count

        var latencies: [Double] = []
        var requests: [Double] = []

        for record in records {
            switch record.status {
            case .completed: stats.completed += 1
            case .failed: stats.failed += 1
            case .pending: stats.pending += 1
            }
            if record.retryCount > 0 { stats.retried += 1 }

            // Timings only come from successes. A failure's latency measures how long an error
            // took to arrive, which is a different quantity and would poison the median.
            guard record.status == .completed else { continue }

            if let latency = record.latencySeconds, latency > 0 { latencies.append(latency) }
            if let request = record.requestSeconds, request > 0 { requests.append(request) }
            stats.spokenSeconds += record.durationSeconds
            stats.words += record.deliveredText.split(whereSeparator: \.isWhitespace).count
            stats.audioTokens += record.usage?.audioTokens ?? 0
            stats.promptTokens += record.usage?.promptTokens ?? 0
            stats.completionTokens += record.usage?.completionTokens ?? 0
        }

        stats.medianLatency = percentile(latencies, 0.5)
        stats.p95Latency = percentile(latencies, 0.95)
        stats.medianRequest = percentile(requests, 0.5)
        return stats
    }

    /// Nearest-rank percentile. No interpolation: with the handful of samples a new user has,
    /// interpolating invents precision that is not there.
    static func percentile(_ values: [Double], _ fraction: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = Int((fraction * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank - 1, 0), sorted.count - 1)]
    }
}

/// Per-model figures, so switching model shows its effect rather than being taken on faith.
public struct ModelPerformance: Sendable, Equatable, Identifiable {
    public var provider: String
    public var model: String
    public var stats: PerformanceStats

    public var id: String { "\(provider)/\(model)" }
    public var label: String { "\(provider) · \(model)" }

    /// Grouped newest-model-first by sample count, since a model tried twice is noise next to one
    /// used for a month.
    public static func breakdown(from records: [DictationRecord]) -> [ModelPerformance] {
        Dictionary(grouping: records) { "\($0.provider)\u{1}\($0.model)" }
            .map { key, group in
                let parts = key.split(separator: "\u{1}", omittingEmptySubsequences: false)
                return ModelPerformance(
                    provider: String(parts.first ?? ""),
                    model: String(parts.count > 1 ? parts[1] : ""),
                    stats: .compute(from: group))
            }
            .sorted { ($0.stats.total, $1.label) > ($1.stats.total, $0.label) }
    }
}

extension PerformanceStats {
    /// Short human forms. Kept beside the numbers so every surface phrases them identically.
    public static func formatDuration(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite else { return "—" }
        if seconds < 1 { return String(format: "%.0f ms", seconds * 1_000) }
        if seconds < 60 { return String(format: "%.1f s", seconds) }
        let minutes = Int(seconds) / 60
        if minutes < 60 { return "\(minutes)m \(Int(seconds) % 60)s" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    public static func formatCount(_ value: Int) -> String {
        value >= 10_000
            ? String(format: "%.1fk", Double(value) / 1_000)
            : value.formatted(.number.grouping(.automatic))
    }
}
