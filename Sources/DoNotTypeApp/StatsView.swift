import DoNotTypeCore
import SwiftUI

/// What the app has actually done and how long it took.
///
/// Two audiences, one screen. A user wants to know whether it is working and whether it is fast;
/// a contributor changing the prompt or swapping models needs a before-and-after that is not a
/// feeling. The per-model table answers the second — the effect of switching model is otherwise
/// taken entirely on faith.
struct StatsView: View {
    let records: [DictationRecord]

    private var stats: PerformanceStats { .compute(from: records) }
    private var byModel: [ModelPerformance] { ModelPerformance.breakdown(from: records) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if records.isEmpty {
                    ContentUnavailableView(
                        "Nothing measured yet", systemImage: "chart.bar",
                        description: Text("Timings appear here after your first dictation."))
                        .padding(.top, 40)
                } else {
                    latency
                    volume
                    reliability
                    if byModel.count > 1 { models }
                    footnote
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Sections

    private var latency: some View {
        Group {
            header("Speed", note: "Measured from when you stop speaking to text on screen.")
            HStack(spacing: 12) {
                Tile(
                    title: "Typical wait", value: PerformanceStats.formatDuration(stats.medianLatency),
                    caption: "median")
                Tile(
                    title: "Slowest 5%", value: PerformanceStats.formatDuration(stats.p95Latency),
                    caption: "p95",
                    tint: (stats.p95Latency ?? 0) > 15 ? .orange : nil)
                Tile(
                    title: "Model time",
                    value: PerformanceStats.formatDuration(stats.medianRequest),
                    caption: "median request")
                if let factor = stats.realTimeFactor {
                    Tile(
                        title: "Wait per second spoken",
                        value: String(format: "%.2f×", factor),
                        caption: factor < 1 ? "faster than real time" : "slower than real time",
                        tint: factor < 1 ? .green : .orange)
                }
            }
        }
    }

    private var volume: some View {
        Group {
            header("Volume", note: nil)
            HStack(spacing: 12) {
                Tile(
                    title: "Dictations", value: PerformanceStats.formatCount(stats.completed),
                    caption: "completed")
                Tile(
                    title: "Words", value: PerformanceStats.formatCount(stats.words),
                    caption: "delivered")
                Tile(
                    title: "Speech",
                    value: PerformanceStats.formatDuration(stats.spokenSeconds),
                    caption: "transcribed")
                if stats.audioTokens > 0 {
                    Tile(
                        title: "Audio tokens",
                        value: PerformanceStats.formatCount(stats.audioTokens),
                        caption: "billed")
                }
            }
            if stats.words > 200 {
                Text(
                    "Roughly \(PerformanceStats.formatDuration(stats.estimatedTypingMinutesSaved * 60)) of typing, at 40 wpm — an estimate."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var reliability: some View {
        Group {
            header("Reliability", note: nil)
            HStack(spacing: 12) {
                Tile(
                    title: "Success rate",
                    value: stats.successRate.map { String(format: "%.0f%%", $0 * 100) } ?? "—",
                    caption: "\(stats.completed) of \(stats.total)",
                    tint: (stats.successRate ?? 1) < 0.95 ? .orange : .green)
                Tile(
                    title: "Needed a retry", value: "\(stats.retried)",
                    caption: "usually the network",
                    tint: stats.retried > 0 ? .orange : nil)
                Tile(
                    title: "Waiting to send", value: "\(stats.pending)",
                    caption: "queued offline",
                    tint: stats.pending > 0 ? .orange : nil)
                Tile(title: "Failed", value: "\(stats.failed)", caption: "retryable from history",
                    tint: stats.failed > 0 ? .orange : nil)
            }
        }
    }

    private var models: some View {
        Group {
            header(
                "By model",
                note: "The effect of switching model, on your microphone and your network.")
            VStack(spacing: 0) {
                ForEach(byModel) { entry in
                    HStack {
                        Text(entry.label)
                            .font(.system(.callout, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.head)
                        Spacer()
                        Text("\(entry.stats.total)×")
                            .foregroundStyle(.secondary)
                            .frame(width: 50, alignment: .trailing)
                        Text(PerformanceStats.formatDuration(entry.stats.medianLatency))
                            .monospacedDigit()
                            .frame(width: 70, alignment: .trailing)
                        Text(
                            entry.stats.successRate.map { String(format: "%.0f%%", $0 * 100) } ?? "—"
                        )
                        .monospacedDigit()
                        .foregroundStyle((entry.stats.successRate ?? 1) < 0.95 ? .orange : .secondary)
                        .frame(width: 50, alignment: .trailing)
                    }
                    .font(.callout)
                    .padding(.vertical, 5)
                    if entry.id != byModel.last?.id { Divider() }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))

            HStack {
                Spacer()
                Text("uses").frame(width: 50, alignment: .trailing)
                Text("median").frame(width: 70, alignment: .trailing)
                Text("ok").frame(width: 50, alignment: .trailing)
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
    }

    private var footnote: some View {
        Text(
            "Computed from the dictations still in your history — deleting history resets these numbers, and a short retention window means they only ever describe the recent past."
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func header(_ title: String, note: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline)
            if let note {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.top, 4)
    }
}

private struct Tile: View {
    let title: String
    let value: String
    var caption: String? = nil
    var tint: Color? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(value)
                .font(.system(.title2, design: .rounded).weight(.medium))
                .foregroundStyle(tint ?? .primary)
                .monospacedDigit()
            if let caption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }
}
