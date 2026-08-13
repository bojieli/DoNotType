import AVFoundation
import DoNotTypeCore
import SwiftUI
import UIKit

/// Settings: provider and key, fidelity, keyboard setup, permissions, and history retention.
///
/// The setup section is not decoration. iOS needs three separate opt-ins before the keyboard
/// works — microphone, adding the keyboard, and Full Access — and each is in a different place.
/// Left unexplained, the keyboard just looks broken.
struct SettingsView: View {
    @Bindable var model: DictationModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var microphoneGranted = false

    var body: some View {
        Form {
            setupSection
            providerSection
            dictationSection
            historySection
            promptSection
            aboutSection
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: refreshPermissions)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshPermissions() }
        }
    }

    // MARK: - Setup

    private var setupSection: some View {
        Section {
            SetupRow(
                title: "Microphone",
                detail: "Recording happens only while you are dictating.",
                isDone: microphoneGranted,
                action: requestMicrophone)

            SetupRow(
                title: "Add the DoNotType keyboard",
                detail: "Settings › General › Keyboard › Keyboards › Add New Keyboard.",
                isDone: nil,
                action: openSystemSettings)

            SetupRow(
                title: "Allow Full Access",
                detail: model.hasAppGroup
                    ? "Granted — the keyboard can read your transcripts."
                    : "Required: the shared container is the keyboard's only way to see "
                        + "transcripts. It does not grant the microphone.",
                isDone: model.hasAppGroup,
                action: openSystemSettings)
        } header: {
            Text("Setup")
        } footer: {
            Text(
                "iOS does not let a keyboard extension open a microphone, so this app records and "
                    + "the keyboard inserts what it produced."
            )
        }
    }

    // MARK: - Provider

    private var providerSection: some View {
        Section {
            Picker("Service", selection: $model.provider) {
                ForEach(ProviderKind.allCases, id: \.self) { kind in
                    Text(kind.rawValue.capitalized).tag(kind)
                }
            }
            .accessibilityIdentifier("provider")

            // Recognition backends give up screen grounding, which iOS never had, so the note here
            // says what they buy rather than what they cost.
            if let note = model.providerNote {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            SecureField("API key", text: $model.apiKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("api-key")

            TextField("Model", text: $model.model)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("model")

            LabeledContent("Key") { Text(model.keySource).foregroundStyle(.secondary) }

            Picker("Fallback", selection: $model.fallbackProvider) {
                Text("None").tag(ProviderKind?.none)
                ForEach(model.fallbackChoices, id: \.self) { kind in
                    Text(kind.rawValue.capitalized).tag(ProviderKind?.some(kind))
                }
            }
            .accessibilityIdentifier("fallback-provider")

            if model.fallbackProvider != nil {
                SecureField("Fallback API key", text: $model.fallbackAPIKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("fallback-api-key")

                LabeledContent("Start it after") {
                    HStack {
                        Slider(value: $model.fallbackAfterSeconds, in: 1...60, step: 1)
                        Text("\(Int(model.fallbackAfterSeconds))s")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let summary = model.fallbackSummary {
                Text(summary).font(.footnote).foregroundStyle(.secondary)
            }

            Button {
                Task { await model.checkConnection() }
            } label: {
                HStack {
                    Text("Test connection")
                    Spacer()
                    if model.isCheckingConnection {
                        ProgressView()
                    } else if let status = model.connectionStatus {
                        Text(status)
                            .font(.footnote)
                            .foregroundStyle(status.hasPrefix("✓") ? .green : .red)
                            .lineLimit(2)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
            .disabled(model.isCheckingConnection)
        } header: {
            Text("Provider")
        } footer: {
            Text(
                "Calls go straight to Google with your key. Nothing routes through a server of "
                    + "ours, and the key is stored in the Keychain."
            )
        }
    }

    private var dictationSection: some View {
        Section {
            Picker("Fidelity", selection: $model.fidelity) {
                Text("Raw — every um and false start").tag(Fidelity.raw)
                Text("Light — drop fillers, keep your words").tag(Fidelity.light)
                Text("Tidy — light, plus punctuation").tag(Fidelity.tidy)
            }
            .accessibilityIdentifier("fidelity")
        } header: {
            Text("Dictation")
        } footer: {
            Text("Even Tidy only changes typography. None of these reword you.")
        }
    }

    // MARK: - History

    private var historySection: some View {
        Section {
            Picker("Keep history", selection: $model.retention) {
                ForEach(RetentionPolicy.allCases, id: \.self) { policy in
                    Text(policy.label).tag(policy)
                }
            }
            .accessibilityIdentifier("retention")
            Toggle("Keep audio", isOn: $model.keepAudio)
                .accessibilityIdentifier("keep-audio")

            LabeledContent("Stored audio") {
                Text(
                    ByteCountFormatter.string(
                        fromByteCount: model.audioBytes, countStyle: .file)
                )
                .foregroundStyle(.secondary)
            }

            if model.retryableCount > 0 {
                Button("Retry \(model.retryableCount) failed") {
                    Task { await model.retryAll() }
                }
            }
        } header: {
            Text("History")
        } footer: {
            Text(
                "Failed dictations always keep their audio until they succeed, whatever this is "
                    + "set to — otherwise Retry could not work."
            )
        }
    }

    /// The contract, editable in place — same reasoning as macOS, and the same warning.
    private var promptSection: some View {
        Section {
            NavigationLink {
                PromptEditorView(model: model)
            } label: {
                LabeledContent("Transcription prompt") {
                    Text(model.isPromptCustom ? "edited" : "default")
                        .foregroundStyle(model.isPromptCustom ? .orange : .secondary)
                }
            }
            .accessibilityIdentifier("open-prompt")
        } header: {
            Text("Prompt")
        } footer: {
            Text(
                "Editing the contract invalidates the measured numbers in the project's changelog, "
                    + "which describe the shipped text."
            )
        }
    }

    private var aboutSection: some View {
        Section("About") {
            Text(
                "Screen grounding is macOS and Android only. Nothing in the iOS sandbox lets one "
                    + "app read another app's content."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Permissions

    private func refreshPermissions() {
        microphoneGranted = AVAudioApplication.shared.recordPermission == .granted
    }

    private func requestMicrophone() {
        if AVAudioApplication.shared.recordPermission == .undetermined {
            AVAudioApplication.requestRecordPermission { granted in
                Task { @MainActor in microphoneGranted = granted }
            }
        } else {
            openSystemSettings()
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

private struct SetupRow: View {
    let title: String
    let detail: String
    /// `nil` when the app genuinely cannot tell — iOS exposes no way to ask whether a keyboard
    /// has been added, so claiming either answer would be a guess.
    let isDone: Bool?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol)
                    .foregroundStyle(isDone == true ? .green : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(.primary)
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var symbol: String {
        // Spelled with explicit optional patterns. `true` / `false` / `nil` is exhaustive to
        // Swift 6.2 and not to 6.0, and the older compiler is the one contributors have.
        switch isDone {
        case .some(true): "checkmark.circle.fill"
        case .some(false): "circle"
        case .none: "questionmark.circle"
        }
    }
}

/// Full history with per-item retry.
struct HistoryView: View {
    @Bindable var model: DictationModel

    private var stats: PerformanceStats { .compute(from: model.allRecords) }

    /// Hidden until there is something worth reporting — two samples are not a median.
    @ViewBuilder private var statsSummary: some View {
        Group {
            LabeledContent("Typical wait") {
                Text(PerformanceStats.formatDuration(stats.medianLatency)).monospacedDigit()
            }
            LabeledContent("Slowest 5%") {
                Text(PerformanceStats.formatDuration(stats.p95Latency)).monospacedDigit()
            }
            if let rate = stats.successRate {
                LabeledContent("Succeeded") {
                    Text("\(Int(rate * 100))% of \(stats.total)")
                        .monospacedDigit()
                        .foregroundStyle(rate < 0.95 ? .orange : .secondary)
                }
            }
            LabeledContent("Words dictated") {
                Text(PerformanceStats.formatCount(stats.words)).monospacedDigit()
            }
        }
    }

    var body: some View {
        List {
            Section {
                Picker("Show", selection: $model.query.status) {
                    ForEach(HistoryQuery.StatusFilter.allCases, id: \.self) { status in
                        Text(status.label).tag(status)
                    }
                }
                .pickerStyle(.segmented)
            }

            if model.retryableCount > 0 {
                Section {
                    Button("Retry \(model.retryableCount) failed") {
                        Task { await model.retryAll() }
                    }
                }
            }

            // A compact version of the desktop Stats tab. On a phone the numbers that matter are
            // "is it fast" and "is it working"; the per-model table is a desktop concern.
            if stats.completed >= 3 {
                Section("Performance") { statsSummary }
            }

            ForEach(model.records) { record in
                HistoryRow(record: record, model: model)
            }
            .onDelete { offsets in
                let targets = offsets.map { model.records[$0] }
                Task { for record in targets { await model.delete(record) } }
            }

            if !model.records.isEmpty {
                Button("Delete all", role: .destructive) {
                    Task { await model.clearHistory() }
                }
            }
        }
        .navigationTitle("History")
        // Searching is the point of keeping history at all; a log you cannot search is storage.
        .searchable(text: $model.query.text, prompt: "Transcripts, errors, apps")
        .overlay {
            if model.records.isEmpty {
                ContentUnavailableView(
                    model.query.isEmpty ? "No dictations yet" : "No matches",
                    systemImage: model.query.isEmpty ? "waveform" : "magnifyingglass",
                    description: Text(
                        model.query.isEmpty
                            ? "Transcripts appear here, and failed ones can be retried."
                            : "Nothing in your history matches that filter."))
            }
        }
    }
}

private struct HistoryRow: View {
    let record: DictationRecord
    @Bindable var model: DictationModel

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint)

            VStack(alignment: .leading, spacing: 3) {
                Text(record.summary).lineLimit(3)
                HStack(spacing: 6) {
                    Text(record.createdAt, format: .dateTime.hour().minute())
                    // The wait, per dictation. "That one felt slow" should be checkable.
                    if let latency = record.latencySeconds {
                        Text("· \(PerformanceStats.formatDuration(latency))")
                            .monospacedDigit()
                            .foregroundStyle(latency > 8 ? Color.orange : Color.secondary)
                    }
                    if let chunks = record.chunkCount, chunks > 1 { Text("· \(chunks) parts") }
                    if record.retryCount > 0 { Text("· retried \(record.retryCount)×") }
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
            }

            Spacer()

            if model.retryingIDs.contains(record.id) {
                ProgressView()
            } else if record.canRetry {
                Button {
                    Task { await model.retry(record) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
            } else if record.status == .completed {
                Button {
                    UIPasteboard.general.string = record.text
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
            }
        }
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


/// Full-screen prompt editor. Validation happens on save, so a broken prompt is caught here rather
/// than in the middle of a dictation.
struct PromptEditorView: View {
    @Bindable var model: DictationModel

    var body: some View {
        VStack(spacing: 0) {
            TextEditor(text: $model.promptText)
                .accessibilityIdentifier("prompt-editor")
                .font(.system(.caption, design: .monospaced))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

            if let status = model.promptStatus {
                Divider()
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
        }
        .navigationTitle("Prompt")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") { model.savePrompt() }
            }
            ToolbarItem(placement: .topBarLeading) {
                Button("Default") { model.restoreDefaultPrompt() }
                    .disabled(!model.isPromptCustom)
            }
        }
    }
}
