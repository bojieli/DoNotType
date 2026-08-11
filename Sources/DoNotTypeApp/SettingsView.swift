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
            StatsView(records: model.allRecords)
                .tabItem { Label("Stats", systemImage: "chart.bar") }
            PromptTab(model: model)
                .tabItem { Label("Prompt", systemImage: "text.quote") }
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
                        // Selectable, unclipped, and copyable in one click. A failure here is the
                        // one message a user most needs to read in full and most likely wants to
                        // paste into a search or an issue; truncating it to two lines defeated the
                        // entire purpose of showing it.
                        Text(status)
                            .font(.callout)
                            .foregroundStyle(status.hasPrefix("✓") ? .green : .red)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        if !status.hasPrefix("✓") {
                            Button {
                                Diagnostics.copyToPasteboard(status)
                                model.note("Error copied")
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.borderless)
                            .help("Copy the full error")
                        }
                    }
                }

                HStack {
                    Button("Copy diagnostics") {
                        Diagnostics.copyToPasteboard(
                            Diagnostics.report(model: model, history: model.allRecords))
                        model.note("Diagnostics copied")
                    }
                    .help(
                        "Version, model, key fingerprint, permissions and recent failures — "
                            + "everything needed to explain a problem, with no secrets in it.")

                    Button("Reveal logs") { Diagnostics.revealLogs() }
                        .help("Opens Console filtered to this app")

                    if let note = model.transientNote {
                        Text(note).font(.callout).foregroundStyle(.secondary)
                    }
                }

                Text(
                    "Calls go straight to the provider with your key. Nothing routes through a "
                        + "server of ours."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            Section("Audio") {
                Picker("Microphone", selection: $model.microphoneUID) {
                    Text("System default").tag(String?.none)
                    ForEach(model.availableMicrophones) { device in
                        Text(device.name).tag(AudioDevices.uid(of: device.id))
                    }
                }
                LabeledContent("In use") {
                    Text(model.activeMicrophoneName).foregroundStyle(.secondary)
                }
                Toggle("Play a sound when recording starts and stops", isOn: $model.interactionSounds)
                Text(
                    "Pinning a device matters when a headset connects mid-session and macOS "
                        + "switches the default underneath you. If the chosen one disappears, "
                        + "dictation keeps working on whatever is there."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            Section("System") {
                Toggle("Launch at login", isOn: $model.launchAtLogin)
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

                Picker("Second key", selection: $model.secondaryTrigger) {
                    Text("None").tag(HotkeyMonitor.Trigger?.none)
                    ForEach(HotkeyMonitor.Trigger.allCases, id: \.self) { trigger in
                        Text(trigger.label).tag(HotkeyMonitor.Trigger?.some(trigger))
                    }
                }
                if model.secondaryTrigger != nil {
                    Picker("Second key writes", selection: $model.secondaryStyle) {
                        ForEach(RewriteStyle.allCases.filter(\.isRewrite), id: \.self) { style in
                            Text(style.label).tag(style)
                        }
                    }
                }
                Text(
                    model.secondaryTrigger == nil
                        ? "Optionally bind a second key to a rewrite, for when you want an email "
                            + "rather than a transcript. Your main key always stays verbatim."
                        : "\(model.trigger.label) transcribes verbatim; "
                            + "\(model.secondaryTrigger!.label) rewrites. The verbatim transcript "
                            + "is stored either way, so you can always see what you actually said."
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

            Section("Shortcuts") {
                LabeledContent("Undo last insertion") { Text("⌘⇧Z").monospaced() }
                LabeledContent("Revert a rewrite to what you said") { Text("⌘⌥Z").monospaced() }
                LabeledContent("Paste last transcript again") { Text("⌘⌃V").monospaced() }
                Text(
                    "Undo works for a minute after inserting, then expires — deleting characters "
                        + "from a field you have since moved away from would destroy unrelated text."
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

                Picker("Check numbers", selection: $model.numberCheck) {
                    ForEach(NumberCheckPolicy.allCases, id: \.self) { policy in
                        Text(policy.label).tag(policy)
                    }
                }
                .disabled(!model.groundingEnabled)

                // The trade is stated rather than implied, because it is the whole reason this is
                // a choice and not a fixed behaviour.
                Text(
                    "Every measured grounding regression has been a number, never a word — a "
                        + "value on screen overriding the one you said. A second transcription "
                        + "that never sees the screen supplies the digits, at the cost of one "
                        + "extra request."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)

                Text(model.numberCheck.detail)
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
    @State private var inspecting: DictationRecord?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            searchBar
            Divider()

            if model.records.isEmpty {
                ContentUnavailableView(
                    model.query.isEmpty ? "No dictations yet" : "No matches",
                    systemImage: model.query.isEmpty ? "waveform" : "magnifyingglass",
                    description: Text(
                        model.query.isEmpty
                            ? "Transcripts appear here, and failed ones can be retried."
                            : "Nothing in your history matches that filter."))
            } else {
                List(model.records, selection: $selection) { record in
                    HistoryRow(record: record, model: model) { inspecting = record }
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

    /// Searching is the point of keeping history at all — a log you cannot search is disk usage.
    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search transcripts, errors and apps", text: $model.query.text)
                .textFieldStyle(.plain)
            if !model.query.text.isEmpty {
                Button {
                    model.query.text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }

            Picker("", selection: $model.query.status) {
                ForEach(HistoryQuery.StatusFilter.allCases, id: \.self) { status in
                    Text(status.label).tag(status)
                }
            }
            .labelsHidden()
            .frame(width: 130)

            if !model.knownApps.isEmpty {
                Picker("", selection: $model.query.appName) {
                    Text("Any app").tag(String?.none)
                    ForEach(model.knownApps, id: \.self) { app in
                        Text(app).tag(String?.some(app))
                    }
                }
                .labelsHidden()
                .frame(width: 140)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
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

            Text(
                model.records.count == model.allRecords.count
                    ? "\(model.allRecords.count) · \(ByteCountFormatter.string(fromByteCount: model.audioBytes, countStyle: .file))"
                    : "\(model.records.count) of \(model.allRecords.count)")
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
    var onInspect: () -> Void

    /// Splits the wait into its parts, so a slow dictation can be blamed on the right thing.
    private var timingBreakdown: String {
        var lines: [String] = []
        if let total = record.latencySeconds {
            lines.append("Total wait: \(PerformanceStats.formatDuration(total))")
        }
        if let request = record.requestSeconds {
            lines.append("Transcription: \(PerformanceStats.formatDuration(request))")
        }
        if let rewrite = record.rewriteSeconds {
            lines.append("Rewrite: \(PerformanceStats.formatDuration(rewrite))")
        }
        if record.durationSeconds > 0 {
            lines.append("Spoken: \(PerformanceStats.formatDuration(record.durationSeconds))")
        }
        if let audio = record.usage?.audioTokens {
            lines.append("Audio tokens: \(audio)")
        }
        return lines.joined(separator: "\n")
    }

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
                    // How long the user waited. Shown per row rather than only in aggregate,
                    // because "that one felt slow" is a claim you should be able to check.
                    if let latency = record.latencySeconds {
                        Text("· \(PerformanceStats.formatDuration(latency))")
                            .monospacedDigit()
                            .foregroundStyle(latency > 8 ? Color.orange : Color.secondary)
                            .help(timingBreakdown)
                    }
                    if let chunks = record.chunkCount, chunks > 1 { Text("· \(chunks) parts") }
                    if record.retryCount > 0 { Text("· retried \(record.retryCount)×") }
                    if let style = record.style { Text("· \(style.rawValue)") }
                    if record.context != nil { Text("· grounded") }
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
            }

            Spacer()

            // The point of keeping the context is being able to look at it. If an app reads your
            // screen, you should be able to read what it read.
            Button(action: onInspect) {
                Image(systemName: "eye")
            }
            .buttonStyle(.borderless)
            .help("Show exactly what was sent")

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

            // A failed row's summary *is* its error, and it is the thing worth pasting into an
            // issue. Copying the truncated label off the screen is not an option, so give it a
            // button of its own.
            if record.status != .completed, let message = record.errorMessage {
                Button {
                    Diagnostics.copyToPasteboard(
                        "\(record.createdAt.ISO8601Format()) [\(record.status.rawValue)] "
                            + "\(record.provider)/\(record.model): \(message)")
                } label: {
                    Image(systemName: "exclamationmark.bubble")
                }
                .buttonStyle(.borderless)
                .help("Copy the full error")
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


// MARK: - Prompt

/// The prompt, editable in place.
///
/// Exposed because this is open-source software whose entire behaviour is a prompt; making it
/// readable but not editable would be an odd line to draw. The warning is not boilerplate — the
/// measured numbers in the changelog describe the shipped text and stop applying the moment it is
/// edited, which is what `dnt-eval --prompt` is for.
private struct PromptTab: View {
    @Bindable var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(
                    model.isPromptCustom ? "Using your edited prompt" : "Using the shipped prompt",
                    systemImage: model.isPromptCustom ? "pencil.circle.fill" : "checkmark.seal")
                    .foregroundStyle(model.isPromptCustom ? .orange : .secondary)
                    .font(.callout)
                Spacer()
                Button("Restore default") { model.restoreDefaultPrompt() }
                    .disabled(!model.isPromptCustom)
                Button("Save") { model.savePrompt() }
                    .keyboardShortcut("s", modifiers: .command)
            }
            .padding(10)

            Divider()

            TextEditor(text: $model.promptText)
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let status = model.promptStatus {
                Divider()
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
