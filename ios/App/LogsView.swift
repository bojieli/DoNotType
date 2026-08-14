import DoNotTypeCore
import SwiftUI
import UIKit

/// The log, on a phone.
///
/// This matters more here than on the desktop, not less. A Mac user with a problem can open
/// Console or `tail` a file; on iOS there is no shell, no Console, and no way to reach a file
/// inside the app's container without plugging the phone into Xcode. Without this screen, "it
/// stopped working" has no evidence attached to it at all.
///
/// Same facility as every other platform: levels, filtering, and a share sheet instead of a Finder
/// reveal — because on iOS the way a log gets into a bug report is by being shared.
@MainActor
@Observable
final class LogViewerModel {
    var minimumLevel: LogLevel = .trace
    var search = ""
    var isFollowing = true
    private(set) var events: [LogEvent] = []

    var recordingLevel: LogLevel {
        didSet {
            UserDefaults.standard.set(recordingLevel.name, forKey: "logLevel")
            LogRouter.shared.setLevel(recordingLevel)
        }
    }

    var includesContent: Bool {
        didSet {
            UserDefaults.standard.set(includesContent, forKey: "logContent")
            LogRouter.shared.setIncludesContent(includesContent)
        }
    }

    private var lastSeen: UInt64 = 0

    init() {
        recordingLevel = AppLogging.storedLevel
        includesContent = UserDefaults.standard.bool(forKey: "logContent")
    }

    var logFileURL: URL? { LogRouter.shared.fileURL }

    func refresh(force: Bool = false) {
        let count = LogRouter.shared.emittedCount
        guard force || isFollowing else { return }
        guard force || count != lastSeen else { return }
        lastSeen = count
        events = LogRouter.shared.recent(
            limit: 800, minimumLevel: minimumLevel, containing: search)
    }

    func clear() {
        LogRouter.shared.clearBuffer()
        events = []
    }

    /// The whole buffer as text, for the share sheet. Already redacted by the router.
    var shareableText: String {
        events.map { $0.render() }.joined(separator: "\n")
    }

    func copyAll() {
        UIPasteboard.general.string = shareableText
    }
}

struct LogsView: View {
    @Bindable var model: LogViewerModel

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            list
        }
        .navigationTitle("Logs")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: model.shareableText) {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityIdentifier("share-log")
            }
        }
        .task {
            while !Task.isCancelled {
                model.refresh()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        .onAppear { model.refresh(force: true) }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            Picker("Record", selection: $model.recordingLevel) {
                ForEach(LogLevel.allCases, id: \.self) { level in
                    Text(label(for: level)).tag(level)
                }
            }
            .accessibilityIdentifier("log-level")

            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter", text: $model.search)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: model.search) { model.refresh(force: true) }
                Toggle("Follow", isOn: $model.isFollowing).labelsHidden()
                Button("Clear") { model.clear() }
            }

            Toggle("Include transcripts", isOn: $model.includesContent)
                .font(.footnote)

            if model.includesContent {
                Label(
                    "The log now contains what you said. Turn this off before sharing it.",
                    systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private var list: some View {
        if model.events.isEmpty {
            ContentUnavailableView(
                "Nothing logged yet",
                systemImage: "doc.text.magnifyingglass",
                description: Text(
                    "Events appear as you dictate. Set Record to Debug to see every request, the "
                        + "backend that answered and each retry."))
        } else {
            List(model.events) { event in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(event.level.name.uppercased())
                            .foregroundStyle(tint(event.level))
                        Text(event.category).foregroundStyle(.secondary)
                    }
                    .font(.caption2)

                    Text(event.message).font(.caption)
                    if !event.fields.isEmpty {
                        Text(
                            event.fields.keys.sorted()
                                .map { "\($0)=\(event.fields[$0]!)" }
                                .joined(separator: "  ")
                        )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                }
                .textSelection(.enabled)
            }
            .listStyle(.plain)
        }
    }

    private func tint(_ level: LogLevel) -> Color {
        switch level {
        case .error: .red
        case .warning: .orange
        case .info: .primary
        default: .secondary
        }
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

/// Where logging is configured for the iOS app.
///
/// The file lives in the App Group container beside the history, so it survives a relaunch and can
/// be shared out. Nothing writes to stderr, because nobody is reading it on a phone.
enum AppLogging {
    static var storedLevel: LogLevel {
        LogLevel(name: UserDefaults.standard.string(forKey: "logLevel") ?? "") ?? .info
    }

    static func start(directory: URL) {
        var configuration = LogRouter.Configuration.app(
            logDirectory: directory.appendingPathComponent("Logs", isDirectory: true))
        configuration.level = storedLevel
        configuration.includesContent = UserDefaults.standard.bool(forKey: "logContent")
        let resolved = LogRouter.shared.bootstrap(configuration)

        // Registered before the first request, so a key cannot reach the log by any route —
        // including a provider echoing it back inside an error body.
        for kind in ProviderKind.allCases {
            if let key = KeychainStore.read(account: kind.rawValue), !key.isEmpty {
                LogRouter.shared.redact(secret: key)
            }
        }

        Log("app").info(
            "started",
            [
                "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
                    ?? "dev",
                "level": resolved.level.name,
                "log": resolved.fileURL?.lastPathComponent ?? "none",
            ])
    }
}
