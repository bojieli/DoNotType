import DoNotTypeCore
import SwiftUI

/// The settings window: providers and keys, the hotkey, grounding, and the history with retry.
struct SettingsView: View {
    @Bindable var model: SettingsModel

    var body: some View {
        TabView {
            GeneralTab(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
            GroundingTab(model: model)
                .tabItem { Label("Grounding", systemImage: "text.viewfinder") }
            HistoryTab(model: model)
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
        }
        .frame(width: 620, height: 520)
        .task { await model.refresh() }
    }
}

// MARK: - General

private struct GeneralTab: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            Section("Provider") {
                Picker("Service", selection: $model.provider) {
                    ForEach(ProviderKind.allCases, id: \.self) { kind in
                        Text(kind.rawValue.capitalized).tag(kind)
                    }
                }
                TextField("Model", text: $model.model)
                SecureField("API key", text: $model.apiKey)
                    .textContentType(.password)

                LabeledContent("Key source") {
                    Text(model.resolvedKeySource).foregroundStyle(.secondary)
                }

                HStack {
                    Button("Test connection") {
                        Task { await model.checkConnection() }
                    }
                    .disabled(model.isCheckingConnection)

                    if model.isCheckingConnection {
                        ProgressView().controlSize(.small)
                    } else if let status = model.connectionStatus {
                        Text(status)
                            .font(.callout)
                            .foregroundStyle(status.hasPrefix("✓") ? .green : .red)
                            .lineLimit(2)
                    }
                }

                Text(
                    "Calls go straight to the provider with your key. Nothing routes through a "
                        + "server of ours."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            Section("Dictation") {
                Picker("Key", selection: $model.trigger) {
                    ForEach(HotkeyMonitor.Trigger.allCases, id: \.self) { trigger in
                        Text(trigger.label).tag(trigger)
                    }
                }
                Picker("Behaviour", selection: $model.hotkeyMode) {
                    ForEach(HotkeyMonitor.Mode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                Text(
                    model.hotkeyMode == .automatic
                        ? "A quick tap starts recording and a second tap ends it; holding the key "
                            + "past a moment records only while held. Escape cancels."
                        : "Escape cancels a recording without inserting anything."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)

                Picker("Fidelity", selection: $model.fidelity) {
                    Text("Raw — every um and false start").tag(Fidelity.raw)
                    Text("Light — drop fillers, keep your words").tag(Fidelity.light)
                    Text("Tidy — light, plus punctuation").tag(Fidelity.tidy)
                }
                Text(
                    "Even Tidy only changes typography. None of these reword you or make you "
                        + "sound more formal."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Grounding

private struct GroundingTab: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            Section("Screen context") {
                Toggle("Ground transcription in screen text", isOn: $model.groundingEnabled)
                Toggle("Capture the window when text is unavailable", isOn: $model.screenshotEnabled)
                    .disabled(!model.groundingEnabled)

                Text(
                    "Screen text is sent as-is — no vocabulary list, no dictionary, no previous "
                        + "transcripts. It may correct spelling, never the words you said."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            Section("Never read these apps") {
                ListEditor(
                    items: $model.blockedBundleIDs,
                    placeholder: "com.example.app",
                    caption: "Bundle identifiers. Checked before anything is captured.")
            }

            Section("Never read these pages") {
                ListEditor(
                    items: $model.blockedURLPrefixes,
                    placeholder: "https://example.com/private",
                    caption: "URL prefixes, re-checked once the page address is known.")
            }
        }
        .formStyle(.grouped)
    }
}

/// A minimal add/remove list. Used for both blocklists.
private struct ListEditor: View {
    @Binding var items: [String]
    let placeholder: String
    let caption: String

    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(items, id: \.self) { item in
                HStack {
                    Text(item).font(.system(.callout, design: .monospaced))
                    Spacer()
                    Button {
                        items.removeAll { $0 == item }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }
            HStack {
                TextField(placeholder, text: $draft)
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text(caption).font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func add() {
        let value = draft.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, !items.contains(value) else { return }
        items.append(value)
        draft = ""
    }
}

// MARK: - History

private struct HistoryTab: View {
    @Bindable var model: SettingsModel
    @State private var selection: DictationRecord.ID?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()

            if model.records.isEmpty {
                ContentUnavailableView(
                    "No dictations yet",
                    systemImage: "waveform",
                    description: Text("Transcripts appear here, and failed ones can be retried."))
            } else {
                List(model.records, selection: $selection) { record in
                    HistoryRow(record: record, model: model)
                }
                .listStyle(.inset)
            }

            if let summary = model.lastRetrySummary {
                Divider()
                Text(summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var toolbar: some View {
        HStack {
            Picker("Keep", selection: $model.retention) {
                ForEach(RetentionPolicy.allCases, id: \.self) { policy in
                    Text(policy.label).tag(policy)
                }
            }
            .frame(width: 210)

            Toggle("Keep audio", isOn: $model.keepAudio)
                .help(
                    "Failed dictations always keep their audio until they succeed, so Retry works.")

            Spacer()

            if model.retryableCount > 0 {
                Button {
                    Task { await model.retryAll() }
                } label: {
                    Label("Retry \(model.retryableCount)", systemImage: "arrow.clockwise")
                }
            }

            Text(ByteCountFormatter.string(fromByteCount: model.audioBytes, countStyle: .file))
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Delete all", role: .destructive) {
                Task { await model.deleteAll() }
            }
            .disabled(model.records.isEmpty)
        }
        .padding(10)
    }
}

private struct HistoryRow: View {
    let record: DictationRecord
    @Bindable var model: SettingsModel

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 3) {
                Text(record.summary)
                    .lineLimit(2)
                    .foregroundStyle(record.status == .completed ? .primary : .secondary)

                HStack(spacing: 6) {
                    Text(record.createdAt, format: .dateTime.hour().minute())
                    if let app = record.appName { Text("· \(app)") }
                    if record.retryCount > 0 { Text("· retried \(record.retryCount)×") }
                    if record.context != nil { Text("· grounded") }
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
            }

            Spacer()

            if model.retryingIDs.contains(record.id) {
                ProgressView().controlSize(.small)
            } else if record.canRetry {
                Button {
                    Task { await model.retry(record) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Retry this dictation")
            } else if record.status == .completed {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(record.text, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy transcript")
            }

            Button {
                Task { await model.delete(record) }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 3)
    }

    private var icon: String {
        switch record.status {
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .pending: "clock.fill"
        }
    }

    private var tint: Color {
        switch record.status {
        case .completed: .green
        case .failed: .red
        case .pending: .orange
        }
    }
}
