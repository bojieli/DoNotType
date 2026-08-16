import AppKit
import DoNotTypeCore
import Observation
import SwiftUI

/// The log, in the app.
///
/// The app already logged; what it did not have was anywhere to *read* the log. "Reveal logs"
/// opened Console and left the user to know the subsystem string, which is a fine instruction for
/// the person who wrote the app and useless for anyone else — the same failure `Diagnostics` was
/// built to fix for errors, still unfixed for everything leading up to one.
///
/// This is the last few thousand events, filterable, with the level control next to them so turning
/// detail up does not mean quitting the app and relaunching it from a terminal.
@MainActor
@Observable
final class LogViewerModel {
    var minimumLevel: LogLevel = .trace
    var search = ""
    var isFollowing = true
    private(set) var events: [LogEvent] = []

    /// Set from `Settings`, and applied to the running process the moment it changes.
    var recordingLevel: LogLevel {
        didSet { Settings.shared.logLevel = recordingLevel }
    }

    var includesContent: Bool {
        didSet { Settings.shared.logContent = includesContent }
    }

    private var lastSeen: UInt64 = 0

    init() {
        recordingLevel = Settings.shared.logLevel
        includesContent = Settings.shared.logContent
    }

    var logFileURL: URL? { LogRouter.shared.fileURL }

    /// Polled rather than pushed. A sink calling back into SwiftUI would have to hop actors on every
    /// line — including lines emitted from inside an audio callback — and a log viewer that adds
    /// latency to the thing it is observing is not worth having.
    func refresh(force: Bool = false) {
        let count = LogRouter.shared.emittedCount
        guard force || isFollowing else { return }
        guard force || count != lastSeen else { return }
        lastSeen = count
        events = LogRouter.shared.recent(
            limit: 1_000, minimumLevel: minimumLevel, containing: search)
    }

    func clear() {
        LogRouter.shared.clearBuffer()
        events = []
    }

    func copyAll() {
        Diagnostics.copyToPasteboard(events.map { $0.render() }.joined(separator: "\n"))
    }

    func revealFile() {
        guard let logFileURL else { return }
        LogRouter.shared.flush()
        NSWorkspace.shared.activateFileViewerSelecting([logFileURL])
    }
}

struct LogsTab: View {
    @Bindable var model: LogViewerModel

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            list
            Divider()
            footer
        }
        // 400 ms is below the point where a log feels laggy and far above the point where redrawing
        // it costs anything.
        .task {
            while !Task.isCancelled {
                model.refresh()
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
        .onAppear { model.refresh(force: true) }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Picker("Record", selection: $model.recordingLevel) {
                    ForEach(LogLevel.allCases, id: \.self) { level in
                        Text(label(for: level)).tag(level)
                    }
                }
                .frame(width: 260)
                .help("How much the app writes to its log file, now and after a restart")

                Spacer()

                Toggle("Follow", isOn: $model.isFollowing)
                Button("Clear") { model.clear() }
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter by message, category or field", text: $model.search)
                    .textFieldStyle(.plain)
                    .onChange(of: model.search) { model.refresh(force: true) }

                Picker("", selection: $model.minimumLevel) {
                    Text("All").tag(LogLevel.trace)
                    Text("Debug+").tag(LogLevel.debug)
                    Text("Info+").tag(LogLevel.info)
                    Text("Warnings+").tag(LogLevel.warning)
                    Text("Errors").tag(LogLevel.error)
                }
                .labelsHidden()
                .frame(width: 130)
                .onChange(of: model.minimumLevel) { model.refresh(force: true) }
            }
        }
        .padding(10)
    }

    @ViewBuilder
    private var list: some View {
        if model.events.isEmpty {
            ContentUnavailableView(
                "Nothing logged yet",
                systemImage: "doc.text.magnifyingglass",
                description: Text(
                    "Events appear here as you dictate. Set Record to Debug to see each request, "
                        + "the grounding route and every retry."))
        } else {
            ScrollViewReader { proxy in
                List {
                    // Enumerated so each row can see the one above it, which is what decides
                    // whether the date needs saying again.
                    ForEach(Array(model.events.enumerated()), id: \.element.id) { index, event in
                        if event.startsANewDay(after: index > 0 ? model.events[index - 1] : nil) {
                            DayHeading(date: event.timestamp)
                        }
                        LogRow(event: event).id(event.id)
                    }
                }
                .listStyle(.plain)
                .font(.system(.caption, design: .monospaced))
                .onChange(of: model.events.last?.id) {
                    guard model.isFollowing, let last = model.events.last?.id else { return }
                    withAnimation(.none) { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            if model.includesContent {
                Label("Transcripts are being written to the log", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            } else {
                Text(model.logFileURL?.path ?? "No log file")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            Spacer()

            Toggle("Include transcripts", isOn: $model.includesContent)
                .toggleStyle(.checkbox)
                .help(
                    "Writes what you said, and the screen text sent with it, into the log file. "
                        + "Off by default — a log is the thing most likely to end up in a bug "
                        + "report.")
            Button("Copy") { model.copyAll() }
            Button("Reveal") { model.revealFile() }
                .disabled(model.logFileURL == nil)
        }
        .padding(8)
    }

    private func label(for level: LogLevel) -> String {
        switch level {
        case .trace: "Everything (trace)"
        case .debug: "Requests and decisions (debug)"
        case .info: "Normal (info)"
        case .warning: "Warnings only"
        case .error: "Errors only"
        case .off: "Nothing"
        }
    }
}

/// The date, said once, above the first row belonging to it.
///
/// The viewer buffers the last thousand events and this app is not relaunched daily, so the list
/// spans days — and a row reading `12:04:31.512` with no date is the same defect the log *file*
/// had. A heading costs one line per day; a date column would cost eleven characters per row.
private struct DayHeading: View {
    let date: Date

    var body: some View {
        Text(LogClock.day(date))
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 6)
            .listRowSeparator(.hidden)
    }
}

private struct LogRow: View {
    let event: LogEvent

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            // When it happened, which is half of what anyone opens a log for — the other half
            // being what happened, and neither answers on its own.
            //
            // `minWidth` with `fixedSize`, not a fixed width: `12:04:31.512` is twelve characters
            // and 84pt did not fit them at every text size, so the column that says *when* was the
            // one being cut. The minimum keeps the columns lined up in the ordinary case; the
            // fixed size means a larger font widens the column instead of losing the milliseconds.
            // A truncated timestamp is a wrong timestamp — 12:04:31.5 and 12:04:31.512 are not the
            // same fact, and the log is read to order events.
            Text(LogClock.timeOfDay(event.timestamp))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: 96, alignment: .leading)
                .help(LogClock.day(event.timestamp))
            Text(event.level.name.uppercased())
                .foregroundStyle(tint)
                .frame(width: 46, alignment: .leading)
            Text(event.category)
                .foregroundStyle(.secondary)
                .frame(width: 78, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.message)
                if !event.fields.isEmpty {
                    Text(
                        event.fields.keys.sorted()
                            .map { "\($0)=\(event.fields[$0]!)" }
                            .joined(separator: "  ")
                    )
                    .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .textSelection(.enabled)
        .padding(.vertical, 1)
    }

    private var tint: Color {
        switch event.level {
        case .error: .red
        case .warning: .orange
        case .info: .primary
        case .debug, .trace, .off: .secondary
        }
    }
}
