import DoNotTypeCore
import SwiftUI
import UniformTypeIdentifiers

/// The settings window: providers and keys, the hotkey, grounding, and the history with retry.
struct SettingsView: View {
    @Bindable var model: SettingsModel
    /// Owned by the window rather than the app: polling the log buffer is only worth doing while
    /// someone is looking at it.
    @State private var logs = LogViewerModel()

    var body: some View {
        TabView {
            GeneralTab(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
            GroundingTab(model: model)
                .tabItem { Label("Grounding", systemImage: "text.viewfinder") }
            DictionaryTab(model: model)
                .tabItem { Label("Dictionary", systemImage: "character.book.closed") }
            HistoryTab(model: model)
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
            StatsView(records: model.allRecords)
                .tabItem { Label("Stats", systemImage: "chart.bar") }
            PromptTab(model: model)
                .tabItem { Label("Prompt", systemImage: "text.quote") }
            LogsTab(model: logs)
                .tabItem { Label("Logs", systemImage: "list.bullet.rectangle") }
        }
        // A minimum rather than a fixed size: pinning the content to an exact width left the
        // window unable to grow past the point where the tab bar fits, which is what hid it.
        .frame(minWidth: 780, minHeight: 500)
        .task {
            await model.refresh()
            // Only when the launch check never ran — the window opens before the permissions
            // walkthrough is finished, and a blank key panel there is exactly the confusion this
            // whole check exists to remove.
            if model.keyStatus == .unchecked { await model.checkConnection() }
        }
    }
}

// MARK: - Dictionary

private struct DictionaryTab: View {
    @Bindable var model: SettingsModel

    @State private var draft = ""
    @State private var search = ""
    @State private var isImporting = false
    @State private var editing: SettingsModel.DictionaryEntry?

    private var filtered: [SettingsModel.DictionaryEntry] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.dictionaryEntries }
        return model.dictionaryEntries.filter {
            $0.term.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    TextField("New word, name, or phrase", text: $draft)
                        .onSubmit(add)
                    Button("Add", action: add)
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Import CSV…") { isImporting = true }
                }

                Toggle("Learn spellings from my corrections", isOn: $model.learnDictionaryFromEdits)
                Text(
                    "Optional. For up to 60 seconds after insertion, DoNotType briefly reads the "
                        + "focused field to detect spelling corrections inside the text it added; "
                        + "surrounding text is discarded. Number changes, added or deleted words, "
                        + "and ordinary rewording are ignored."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                TextField("Search dictionary", text: $search)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(20)

            Divider()

            if filtered.isEmpty {
                ContentUnavailableView(
                    search.isEmpty ? "No dictionary entries" : "No matching entries",
                    systemImage: search.isEmpty ? "character.book.closed" : "magnifyingglass",
                    description: Text(
                        search.isEmpty
                            ? "Add a spelling, import a one-column CSV, or enable learning."
                            : "Try a different search."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filtered) { entry in
                    HStack(spacing: 12) {
                        Text(entry.term)
                            .textSelection(.enabled)
                        Spacer()
                        Label(
                            entry.source == .learned ? "Learned" : "Manual",
                            systemImage: entry.source == .learned ? "sparkles" : "person.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button { editing = entry } label: {
                            Image(systemName: "pencil")
                        }
                        .buttonStyle(.borderless)
                        .help("Edit \(entry.term)")
                        Button { model.removeDictionaryEntry(entry) } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove \(entry.term)")
                    }
                }
                .listStyle(.inset)
            }

            Divider()
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("\(model.dictionaryCount) of \(PersonalDictionary.maxTerms) entries")
                    Spacer()
                    if let status = model.dictionaryStatus {
                        Text(status)
                            .foregroundStyle(model.dictionaryStatusIsError ? .red : .secondary)
                    }
                }
                .font(.footnote)

                Text(routingNote)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(
                    "Stored only on this Mac. CSV import accepts UTF-8 with one entry per row "
                        + "and ignores duplicates."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            .padding(16)
        }
        .fileImporter(
            isPresented: $isImporting, allowedContentTypes: [.commaSeparatedText, .plainText]
        ) { result in
            if case .success(let url) = result { model.importDictionary(from: url) }
        }
        .sheet(item: $editing) { entry in
            DictionaryEditSheet(entry: entry, model: model)
        }
    }

    private var routingNote: String {
        switch model.grounding {
        case .multimodal:
            "Model requests receive these entries as a spelling-only reference. An entry is not "
                + "evidence that it was spoken, and numbers still come from audio."
        case .keyterms:
            "This recognition service receives dictionary entries as keyterms. Entries containing "
                + "digits are withheld because its keyterm channel cannot be told that numbers "
                + "must come from audio."
        case .none:
            "The selected recognition service has no spelling-hint channel, so dictionary entries "
                + "are stored but cannot affect its transcripts."
        }
    }

    private func add() {
        if model.addDictionaryTerm(draft) { draft = "" }
    }
}

private struct DictionaryEditSheet: View {
    let entry: SettingsModel.DictionaryEntry
    @Bindable var model: SettingsModel

    @Environment(\.dismiss) private var dismiss
    @State private var draft: String

    init(entry: SettingsModel.DictionaryEntry, model: SettingsModel) {
        self.entry = entry
        self.model = model
        _draft = State(initialValue: entry.term)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit dictionary entry").font(.headline)
            TextField("Word, name, or phrase", text: $draft)
                .onSubmit(save)
            if let status = model.dictionaryStatus, model.dictionaryStatusIsError {
                Text(status).font(.footnote).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func save() {
        if model.updateDictionaryEntry(entry, to: draft) { dismiss() }
    }
}

// MARK: - General

private struct GeneralTab: View {
    @Bindable var model: SettingsModel
    /// The window opens itself when there is no key, so the caret starts where the fix is.
    @FocusState private var keyFieldFocused: Bool

    var body: some View {
        Form {
            // Provider and model are two settings because they are two things: the provider is
            // who serves the request, the model is what runs it, and one provider serves many
            // models. "In use" states the combination, which is the thing neither field says.
            Section("Provider and model") {
                // Recommended entries first and labelled as such. Six equally weighted backends
                // asked the user to have read the evaluation before they could pick one; two of
                // them differ on a single axis a user can actually answer for themselves, and the
                // other four are still here for the narrower questions they answer.
                Picker("Provider", selection: $model.provider) {
                    ForEach(ProviderKind.pickerOrder, id: \.self) { kind in
                        Text(kind.pickerLabel).tag(kind)
                    }
                }
                TextField("Model", text: $model.model)
                // Shown only where transcription and rewriting are genuinely different models,
                // rather than as a second field that repeats the first one everywhere else.
                if model.provider.defaultTextModel != nil {
                    TextField("Rewrite model", text: $model.textModel)
                }
                // No `.textContentType(.password)`: it makes macOS offer saved website logins in
                // a panel that lands directly on top of the explanation below — which is the one
                // thing worth reading at the moment the field is empty. A provider key is not a
                // credential any password manager has, so the panel costs the instructions and
                // offers nothing back. `SecureField` masks the value regardless.
                // Empty means the backend's own URL, which is what the placeholder shows. Every
                // backend takes one, because "I want to use a third-party service that speaks this
                // API" is not a wish specific to any of them — and until now it was reachable only
                // for the self-hosted entry, and only through an environment variable that an app
                // opened from Finder never sees.
                TextField("API endpoint", text: $model.endpoint, prompt: Text(model.provider.defaultEndpoint))
                    .autocorrectionDisabled()

                SecureField("API key", text: $model.apiKey)
                    .focused($keyFieldFocused)
                    .onChange(of: model.keyStatus, initial: true) {
                        if model.keyStatus == .missing { keyFieldFocused = true }
                    }

                // The paragraph that answers "but I did set it". A key exported in ~/.zshrc is
                // real in every terminal and invisible to an app opened from Finder, which looks
                // exactly like the app losing it.
                if let explanation = model.missingKeyExplanation {
                    Label(explanation, systemImage: "key.slash")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // What the choice buys, for the two entries there is a recommendation for. Shown
                // before the cost below it, because a user reading this has just been told two
                // options are recommended and the next question is which.
                if let recommendation = model.recommendationNote {
                    Label(recommendation, systemImage: "star")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Stated here rather than left to be discovered: picking a recognition service
                // silently disables screen grounding, one rung of the fidelity ladder and the
                // rewrite key, and none of those controls would otherwise say so.
                if let summary = model.groundingSummary {
                    Label(summary, systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Louder than the summary above, because this one predicts lost dictations rather
                // than describing a trade-off.
                if let warning = model.providerWarning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }


                LabeledContent("In use") {
                    Text(model.configurationSummary).foregroundStyle(.secondary)
                }

                LabeledContent("Key source") {
                    Text(model.resolvedKeySource).foregroundStyle(.secondary)
                }

                // In this section, because it checks *this* backend. It used to live under the
                // Fallback heading while testing the primary, so a tick here said nothing at all
                // about the second backend a user had just configured.
                connectionCheck(
                    title: "Test \(model.provider.displayName)",
                    isChecking: model.isCheckingConnection,
                    status: model.connectionStatus,
                    run: { await model.checkConnection() })
            }

            // A second backend, for a primary whose latency has a tail. Its own section because it
            // has its own key: the pairing only works if both are configured, and burying the
            // second key under the first one's field is how people end up with a fallback that
            // silently never fires.
            Section("Fallback") {
                Picker("Second provider", selection: $model.fallbackProvider) {
                    Text("None").tag(ProviderKind?.none)
                    ForEach(model.fallbackChoices, id: \.self) { kind in
                        Text(kind.pickerLabel).tag(ProviderKind?.some(kind))
                    }
                }

                if let fallbackKind = model.fallbackProvider {
                    // The fallback has always had its own model — stored per backend, like the
                    // primary's — and no way to set it. Reaching it meant selecting this backend
                    // as the primary, typing the model, and switching back. So a fallback ran its
                    // backend's default model while the panel showed nothing about it.
                    TextField(
                        "Second provider model", text: $model.fallbackModel,
                        prompt: Text(fallbackKind.defaultModel)
                    )
                    .autocorrectionDisabled()

                    TextField(
                        "Second provider endpoint", text: $model.fallbackEndpoint,
                        prompt: Text(fallbackKind.defaultEndpoint)
                    )
                    .autocorrectionDisabled()

                    SecureField("Second provider API key", text: $model.fallbackAPIKey)
                        .textContentType(.password)

                    LabeledContent("Start it after") {
                        HStack {
                            Slider(value: $model.fallbackAfterSeconds, in: 1...60, step: 1)
                            Text("\(Int(model.fallbackAfterSeconds))s")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 40, alignment: .trailing)
                        }
                    }
                }

                if let summary = model.fallbackSummary {
                    Text(summary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(
                        "Off. Worth turning on when the primary is accurate but its latency has a "
                            + "tail — the first-party Gemini API answered one three-second clip in "
                            + "5 s and the next in 61 s. The fallback bounds that wait; it does "
                            + "not improve a transcript the primary would have got right."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                if let fallbackKind = model.fallbackProvider {
                    // Its own button, checking its own key, model and endpoint. Until now there
                    // was no way to find out whether the second backend worked except to wait for
                    // the primary to stall and see what came back.
                    connectionCheck(
                        title: "Test \(fallbackKind.displayName)",
                        isChecking: model.isCheckingFallbackConnection,
                        status: model.fallbackConnectionStatus,
                        run: { await model.checkFallbackConnection() })
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

                    Button("Reveal log file") { Diagnostics.revealLogs() }
                        .help("Shows the log file in Finder. The Logs tab reads it in place.")

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
                Picker("Cancel shortcut", selection: $model.cancelShortcut) {
                    ForEach(CancelShortcut.allCases, id: \.self) { shortcut in
                        Text(shortcut.label).tag(shortcut)
                    }
                }
                Text(
                    "A quick tap starts recording and a second tap ends it; holding the key past "
                        + "a moment records only while held. "
                        + (model.cancelShortcut == .escape
                            ? "Escape cancels recording or transcription only while one is active; "
                                + "at all other times it belongs to the app you are using."
                            : "No key is intercepted to cancel an active dictation.")
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

            RewriteSection(model: model)

            Section("Shortcuts") {
                LabeledContent("Undo last insertion") { Text("⌘⇧Z").monospaced() }
                LabeledContent("Revert a rewrite to what you said") { Text("⌘⌥Z").monospaced() }
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

    /// One backend's "does this actually work?" button, with room for the answer.
    ///
    /// Shared by the two backends rather than written twice, because the thing that went wrong
    /// here was one control standing for two things: the button tested the primary while sitting
    /// under the Fallback heading, so a user with a dead second key got a green tick and lost every
    /// dictation the fallback served. Two buttons, each naming the backend it checked.
    @ViewBuilder
    private func connectionCheck(
        title: String,
        isChecking: Bool,
        status: String?,
        run: @escaping () async -> Void
    ) -> some View {
        HStack {
            Button(title) { Task { await run() } }
                .disabled(isChecking)

            if isChecking {
                ProgressView().controlSize(.small)
            } else if let status {
                // Selectable, unclipped, and copyable in one click. A failure here is the one
                // message a user most needs to read in full and most likely wants to paste into a
                // search or an issue; truncating it to two lines defeated the entire purpose of
                // showing it.
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
                    "Screen text is sent as-is — no extracted vocabulary and no previous "
                        + "transcripts. The separate personal dictionary is under its own tab. "
                        + "Context may correct spelling, never the words you said."
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
        // The row's eye button sets `inspecting` and this is what reads it. Without this modifier
        // the button was inert: state changed, nothing appeared, and the one feature that proves
        // what this app sends to a server could not be opened on the platform it shipped on first.
        .sheet(item: $inspecting) { record in
            ContextInspectorView(record: record)
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
                    // The detail, not the label. What is on screen is one sentence chosen to be
                    // readable; what somebody pastes into an issue has to be the whole failure,
                    // including the status and the response body exactly as it arrived.
                    Diagnostics.copyToPasteboard(
                        "\(record.createdAt.ISO8601Format()) [\(record.status.rawValue)] "
                            + "\(record.provider)/\(record.model): \(message)"
                            + (record.errorDetail.map { "\n\n\($0)" } ?? ""))
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


// MARK: - Rewrite

/// The rewrite, as its own named section.
///
/// It used to be two unlabelled rows — "Second key" and "Second key writes" — inside Dictation,
/// which named the mechanism and never the feature. Somebody looking for rewriting had no reason
/// to read a row about keys, and on a fresh install nothing is bound, so the word "rewrite"
/// appeared nowhere in the window at all. A heading is the cheapest fix there is.
///
/// Shown even when it cannot run, greyed out with the reason. Hiding it is what made the feature
/// look absent rather than unavailable, and "why is this off" is answerable while "where is it"
/// is not.
private struct RewriteSection: View {
    @Bindable var model: SettingsModel

    var body: some View {
        let availability = model.rewriteAvailability

        Section("Rewrite") {
            Picker("Second key", selection: $model.secondaryTrigger) {
                Text("None — always verbatim").tag(HotkeyMonitor.Trigger?.none)
                ForEach(HotkeyMonitor.Trigger.allCases, id: \.self) { trigger in
                    Text(trigger.label).tag(HotkeyMonitor.Trigger?.some(trigger))
                }
            }
            .disabled(!availability.isAvailable)

            Picker("It produces", selection: $model.secondaryStyle) {
                ForEach(RewriteStyle.allCases.filter(\.isRewrite), id: \.self) { style in
                    Text(style.label).tag(style)
                }
            }
            .disabled(!availability.isAvailable || model.secondaryTrigger == nil)

            if let reason = availability.reason {
                Label(reason, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if model.secondaryTrigger == nil {
                Text(
                    "Optional. Bind a second key and holding it dictates and then rewrites — for "
                        + "when you want an email rather than a transcript. Your main key always "
                        + "stays verbatim."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            } else {
                Text(
                    "\(model.trigger.label) transcribes verbatim; "
                        + "\(model.secondaryTrigger!.label) rewrites. Which key you hold decides, "
                        + "before you speak — there is no mode to leave switched on. The verbatim "
                        + "transcript is stored either way, so you can always see what you "
                        + "actually said."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            Text("Summaries are not offered here — see the Files tab, which transcribes a "
                + "recording you already have and can summarise it.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Prompt

/// The prompt, editable one part at a time.
///
/// Exposed because this is open-source software whose entire behaviour is a prompt; making it
/// readable but not editable would be an odd line to draw. One box per file rather than one box for
/// everything, because the contract is twelve separate instructions — and a single buffer holding
/// all of them is how the shipped text and the documentation about it came to live in the same
/// place, with a marker convention as the only thing telling them apart.
///
/// The warning is not boilerplate: the measured numbers in the changelog describe the shipped text
/// and stop applying to whichever part is edited, which is what `dnt-eval --prompt` is for.
private struct PromptTab: View {
    @Bindable var model: SettingsModel

    private var groups: [(name: String, parts: [PromptPart])] {
        var order: [String] = []
        var byGroup: [String: [PromptPart]] = [:]
        for part in PromptPart.allCases {
            if byGroup[part.group] == nil { order.append(part.group) }
            byGroup[part.group, default: []].append(part)
        }
        return order.map { ($0, byGroup[$0] ?? []) }
    }

    var body: some View {
        HSplitView {
            List(selection: $model.selectedPart) {
                ForEach(groups, id: \.name) { group in
                    Section(group.name) {
                        ForEach(group.parts, id: \.self) { part in
                            HStack(spacing: 6) {
                                Text(part.label)
                                Spacer()
                                if model.customParts.contains(part) {
                                    Image(systemName: "pencil.circle.fill")
                                        .foregroundStyle(.orange)
                                        .help("Edited — the shipped version is one button away")
                                }
                            }
                            .tag(part)
                        }
                    }
                }
            }
            .frame(minWidth: 170, idealWidth: 190, maxWidth: 260)

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.selectedPart.relativePath)
                            .font(.system(.callout, design: .monospaced))
                        Text(model.selectedPart.summaryLine)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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

                Divider()

                HStack(alignment: .top) {
                    Text(
                        model.promptStatus
                            ?? "Sent in full — everything in this box reaches the model.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !model.customParts.isEmpty {
                        Button("Restore all \(model.customParts.count)") {
                            model.restoreAllPrompts()
                        }
                        .font(.footnote)
                    }
                }
                .padding(10)
            }
            .frame(minWidth: 360)
        }
    }
}
