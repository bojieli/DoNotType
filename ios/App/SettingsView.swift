import AVFoundation
import DoNotTypeCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Settings: provider and key, fidelity, keyboard setup, permissions, and history retention.
///
/// The setup section is not decoration. iOS needs three separate opt-ins before the keyboard
/// works — microphone, adding the keyboard, and Full Access — and each is in a different place.
/// Left unexplained, the keyboard just looks broken.
struct SettingsView: View {
    @Bindable var model: DictationModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var microphoneGranted = false
    /// Created here rather than at launch: polling the log buffer is only worth doing while
    /// somebody is looking at it.
    @State private var logs = LogViewerModel()

    var body: some View {
        Form {
            transferSection
            setupSection
            providerSection
            dictationSection
            dictionarySection
            historySection
            promptSection
            logsSection
            aboutSection
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    SettingsTransferView(model: model, startsScanning: true)
                } label: {
                    Image(systemName: "qrcode.viewfinder")
                }
                .accessibilityLabel("Scan settings QR code")
                .accessibilityIdentifier("scan-settings-qr")
            }
        }
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
                detail: "After keyboard dictation, the input session stays warm for up to five "
                    + "minutes so later presses do not switch apps.",
                isDone: microphoneGranted,
                action: requestMicrophone)

            SetupRow(
                title: "Add the DoNotType keyboard",
                detail: "Settings › General › Keyboard › Keyboards › Add New Keyboard.",
                isDone: nil,
                action: openSystemSettings)

            SetupRow(
                title: "Allow Full Access",
                detail: "Required for keyboard voice commands and transcript insertion. iOS does "
                    + "not let this app verify the switch.",
                isDone: nil,
                action: openSystemSettings)
        } header: {
            Text("Setup")
        } footer: {
            Text(
                "The first cold press briefly opens this app to start capture. Later presses use "
                    + "the warm session while the keyboard inserts the result."
            )
        }
    }

    // MARK: - Provider

    private var providerSection: some View {
        Section {
            Picker("Service", selection: $model.provider) {
                ForEach(ProviderKind.pickerOrder, id: \.self) { kind in
                    Text(kind.pickerLabel).tag(kind)
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

            TextField(
                "API endpoint", text: $model.endpoint,
                prompt: Text(model.provider.defaultEndpoint)
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
            .accessibilityIdentifier("endpoint")

            LabeledContent("Key") { Text(model.keySource).foregroundStyle(.secondary) }

            Picker("Fallback", selection: $model.fallbackProvider) {
                Text("None").tag(ProviderKind?.none)
                ForEach(model.fallbackChoices, id: \.self) { kind in
                    Text(kind.pickerLabel).tag(ProviderKind?.some(kind))
                }
            }
            .accessibilityIdentifier("fallback-provider")

            if model.fallbackProvider != nil {
                TextField("Fallback model", text: $model.fallbackModel)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                TextField("Fallback endpoint", text: $model.fallbackEndpoint)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)

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
            .disabled(model.isCheckingConnection || !model.hasAPIKey)
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

    private var dictionarySection: some View {
        Section {
            NavigationLink {
                DictionaryView(model: model)
            } label: {
                LabeledContent("Personal dictionary") {
                    Text("(model.personalDictionaryTerms.count) entries")
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("open-dictionary")
        } footer: {
            Text(
                "Names, jargon and preferred capitalisation. Manual and learned entries stay "
                    + "on device and are visible and removable."
            )
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
                    Text(
                        model.customParts.isEmpty
                            ? "default" : "\(model.customParts.count) edited")
                        .foregroundStyle(model.customParts.isEmpty ? Color.secondary : Color.orange)
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

    /// The only way to see what the app is doing on a device with no Console and no shell.
    private var logsSection: some View {
        Section {
            NavigationLink {
                LogsView(model: logs)
            } label: {
                LabeledContent("Logs") {
                    Text(logs.recordingLevel.name).foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("open-logs")
        } header: {
            Text("Diagnostics")
        } footer: {
            Text(
                "Every request, retry and failure, with a share button. Transcripts are left out "
                    + "unless you turn them on there."
            )
        }
    }

    private var transferSection: some View {
        Section {
            NavigationLink {
                SettingsTransferView(model: model)
            } label: {
                Label("Import, export, or edit settings", systemImage: "arrow.left.arrow.right")
            }
            .accessibilityIdentifier("open-settings-transfer")
        } header: {
            Text("Move settings")
        } footer: {
            Text("Scan a QR code with the button above, or open this page for QR images and JSON files.")
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

/// The first launch is a setup flow rather than a dictation button that cannot work yet.
///
/// Import is first because an existing user can configure the provider in one scan. The three iOS
/// permissions follow in the order a new user encounters them; the API key remains editable here
/// because transcription cannot start without it.
struct InitialSetupView: View {
    @Bindable var model: DictationModel
    let onComplete: () -> Void

    @State private var microphoneGranted = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        SettingsTransferView(model: model, startsScanning: true)
                    } label: {
                        Label("Scan settings QR code", systemImage: "qrcode.viewfinder")
                    }
                    .accessibilityIdentifier("setup-scan-settings-qr")

                    NavigationLink {
                        SettingsTransferView(model: model)
                    } label: {
                        Label("Import QR image or JSON", systemImage: "square.and.arrow.down")
                    }
                    .accessibilityIdentifier("setup-import-settings")
                } header: {
                    Text("Already use DoNotType?")
                } footer: {
                    Text("An imported profile can fill in the provider, model, and API key below.")
                }

                Section {
                    Picker("Service", selection: $model.provider) {
                        ForEach(ProviderKind.pickerOrder, id: \.self) { kind in
                            Text(kind.pickerLabel).tag(kind)
                        }
                    }

                    SecureField("API key", text: $model.apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("setup-api-key")

                    TextField("Model", text: $model.model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Button("Test connection") {
                        Task { await model.checkConnection() }
                    }
                    .disabled(!model.hasAPIKey || model.isCheckingConnection)

                    if let status = model.connectionStatus {
                        Text(status)
                            .font(.footnote)
                            .foregroundStyle(status.hasPrefix("✓") ? .green : .red)
                    }
                } header: {
                    Text("1. Configure transcription")
                } footer: {
                    Text("The key is stored in Keychain and sent only to the selected provider.")
                }

                Section {
                    SetupRow(
                        title: "Allow microphone access",
                        detail: "Required to record dictation in this app.",
                        isDone: microphoneGranted,
                        action: requestMicrophone)

                    SetupRow(
                        title: "Add the DoNotType keyboard",
                        detail: "Settings › General › Keyboard › Keyboards › Add New Keyboard.",
                        isDone: nil,
                        action: openSystemSettings)

                    SetupRow(
                        title: "Allow Full Access",
                        detail: "Required for keyboard voice commands and transcript insertion. "
                            + "iOS does not let the app verify this switch.",
                        isDone: nil,
                        action: openSystemSettings)
                } header: {
                    Text("2. Enable dictation")
                } footer: {
                    Text("iOS makes microphone access and keyboard access separate choices.")
                }
            }
            .navigationTitle("Set up DoNotType")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Finish Setup", action: onComplete)
                        .disabled(!model.hasAPIKey)
                        .accessibilityIdentifier("finish-initial-setup")
                }
            }
            .interactiveDismissDisabled()
            .onAppear(perform: refreshPermissions)
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { refreshPermissions() }
            }
        }
    }

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

struct DictionaryView: View {
    @Bindable var model: DictationModel
    @State private var newTerm = ""
    @State private var importing = false
    @State private var editing: Entry?
    @State private var editedTerm = ""

    private struct Entry: Identifiable {
        let term: String
        let learned: Bool
        var id: String { "\(learned)-\(term)" }
    }

    var body: some View {
        List {
            Section {
                Toggle("Learn corrections after insertion", isOn: $model.learnDictionaryFromEdits)
            } footer: {
                Text(
                    "Optional. For one minute after insertion, the keyboard checks only the same "
                        + "document. Secure fields, additions, deletions, numbers and ordinary "
                        + "rewrites are ignored. If you switch keyboards to make the correction, "
                        + "return to DoNotType so it can observe the result."
                )
            }

            Section("Add") {
                TextField("Word or phrase", text: $newTerm)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Add entry") {
                    model.addDictionaryTerm(newTerm)
                    if model.dictionaryStatus?.hasPrefix("Added") == true { newTerm = "" }
                }
                Button("Import CSV…") { importing = true }
            }

            if !model.dictionaryTerms.isEmpty {
                Section("Added by you") {
                    ForEach(model.dictionaryTerms, id: \.self) { term in row(term, learned: false) }
                }
            }

            if !model.learnedDictionaryTerms.isEmpty {
                Section("Learned from edits") {
                    ForEach(model.learnedDictionaryTerms, id: \.self) { term in row(term, learned: true) }
                }
            }

            Section {
                Text(
                    "\(model.personalDictionaryTerms.count) of \(PersonalDictionary.maxTerms) entries"
                )
                .foregroundStyle(.secondary)
                if let status = model.dictionaryStatus { Text(status).font(.footnote) }
            } footer: {
                Text(
                    "Model backends receive a strongly delimited spelling reference. Speech "
                        + "recognizers receive only number-free entries through their hint channel."
                )
            }
        }
        .navigationTitle("Dictionary")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { model.refreshDictionary() }
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: [.commaSeparatedText, .plainText]
        ) { result in
            if case .success(let url) = result { model.importDictionary(from: url) }
        }
        .sheet(item: $editing) { entry in
            NavigationStack {
                Form {
                    TextField("Spelling", text: $editedTerm)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                .navigationTitle("Edit entry")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { editing = nil }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            model.replaceDictionaryTerm(
                                entry.term, with: editedTerm, learned: entry.learned)
                            editing = nil
                        }
                    }
                }
            }
        }
    }

    private func row(_ term: String, learned: Bool) -> some View {
        HStack {
            Button(term) {
                editedTerm = term
                editing = Entry(term: term, learned: learned)
            }
            .foregroundStyle(.primary)
            Spacer()
            Button(role: .destructive) {
                model.deleteDictionaryTerm(term, learned: learned)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
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


/// Full-screen prompt editor, one part at a time. Validation happens on save, so a broken part is
/// caught here rather than in the middle of a dictation.
///
/// A picker rather than one buffer for everything, for the same reason as the other platforms: the
/// contract is twelve separate instructions, and holding them in a single scrolling box is how the
/// shipped text and the documentation about it ended up together with a marker convention as the
/// only thing telling them apart.
struct PromptEditorView: View {
    @Bindable var model: DictationModel

    var body: some View {
        VStack(spacing: 0) {
            Picker("Part", selection: $model.selectedPart) {
                ForEach(PromptPart.allCases, id: \.self) { part in
                    Text("\(part.group) · \(part.label)").tag(part)
                }
            }
            .accessibilityIdentifier("prompt-part")
            .padding(.horizontal, 10)

            Divider()

            TextEditor(text: $model.promptText)
                .accessibilityIdentifier("prompt-editor")
                .font(.system(.caption, design: .monospaced))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

            Divider()
            Text(
                model.promptStatus
                    ?? "\(model.selectedPart.relativePath) — sent in full: everything here reaches "
                    + "the model.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .navigationTitle("Prompt")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") { model.savePrompt() }
            }
            // Restores the selected part alone. The others keep whatever they are, which is the
            // point of per-part overrides.
            ToolbarItem(placement: .topBarLeading) {
                Button("Default") { model.restoreDefaultPrompt() }
                    .disabled(!model.isPromptCustom)
            }
        }
    }
}
