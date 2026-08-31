import AppKit
import DoNotTypeCore
import SwiftUI
import UniformTypeIdentifiers

/// The settings window: providers and keys, the hotkey, grounding, and the history with retry.
struct SettingsView: View {
    /// The nine panels, in the three groups the sidebar draws them in.
    private enum Pane: Hashable {
        case general, grounding, dictionary, prompt
        case history, stats, logs
        case transfer, about
    }

    @Bindable var model: SettingsModel
    /// Owned by the window rather than the app: polling the log buffer is only worth doing while
    /// someone is looking at it.
    @State private var logs = LogViewerModel()

    /// Named rather than left to whichever panel happens to be listed first. All three callers of
    /// `openSettings` want the provider and key controls, and one of them is the menu item whose
    /// whole purpose is to say the key is wrong.
    ///
    /// The window is cached rather than released on close, so this outlives closing it: the
    /// sidebar comes back where it was left.
    @State private var pane: Pane = .general

    var body: some View {
        // This deliberately is not a NavigationSplitView. macOS may adapt a split view into a
        // single-column presentation even when its visibility binding says `.all`; Dictionary's
        // list was enough to trigger that path and leave the detail occupying the whole window.
        // Keeping the navigation in our own HStack makes its 180pt column a real part of the
        // layout rather than a system presentation preference that can be overridden.
        HStack(spacing: 0) {
            sidebar
                .frame(width: 180)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // A minimum rather than a fixed size, and it has to agree with the window's
        // `contentMinSize` in AppDelegate — the reasoning behind the number is there.
        .frame(minWidth: 880, minHeight: 520)
        .task {
            await model.refresh()
            // Only when the launch check never ran — the window opens before the permissions
            // walkthrough is finished, and a blank key panel there is exactly the confusion this
            // whole check exists to remove.
            if model.keyStatus == .unchecked { await model.checkConnection() }
        }
    }

    private var sidebar: some View {
        List(selection: selection) {
            Section("Dictation") {
                Label("General", systemImage: "gearshape").tag(Pane.general)
                Label("Grounding", systemImage: "text.viewfinder").tag(Pane.grounding)
                Label("Dictionary", systemImage: "character.book.closed")
                    .tag(Pane.dictionary)
                Label("Prompt", systemImage: "text.quote").tag(Pane.prompt)
            }
            Section("Activity") {
                Label("History", systemImage: "clock.arrow.circlepath").tag(Pane.history)
                Label("Stats", systemImage: "chart.bar").tag(Pane.stats)
                Label("Logs", systemImage: "list.bullet.rectangle").tag(Pane.logs)
            }
            Section("App") {
                Label("Transfer", systemImage: "arrow.left.arrow.right").tag(Pane.transfer)
                Label("About", systemImage: "info.circle").tag(Pane.about)
            }
        }
        .listStyle(.sidebar)
    }

    /// Nudged back rather than passed straight through. `List` reports nil when a click lands on
    /// empty sidebar space, and a settings window that blanks its right half because you missed a
    /// row by a few points is worse than one that keeps showing what it was showing.
    private var selection: Binding<Pane?> {
        Binding(get: { pane }, set: { if let new = $0 { pane = new } })
    }

    /// Unlike a `TabView`, this is rebuilt on every selection change — anything a panel must not
    /// lose across that lives on `SettingsModel`, not in the panel.
    @ViewBuilder
    private var detail: some View {
        switch pane {
        case .general: GeneralTab(model: model)
        case .grounding: GroundingTab(model: model)
        case .dictionary: DictionaryTab(model: model)
        case .prompt: PromptTab(model: model)
        case .history: HistoryTab(model: model)
        case .stats: StatsView(records: model.allRecords)
        case .logs: LogsTab(model: logs)
        case .transfer: SettingsTransferView(model: model)
        case .about: AboutView()
        }
    }
}

// MARK: - Dictionary

private struct DictionaryTab: View {
    @Bindable var model: SettingsModel

    /// Draft and filter live on the model. The settings window rebuilds a panel each time you
    /// navigate back to it, so held here the half-typed term would vanish and — worse — the filter
    /// would silently reset to the whole list while still looking like a filtered one.
    private var draft: String { model.dictionaryDraft }
    private var search: String { model.dictionarySearch }

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
                    TextField("New word, name, or phrase", text: $model.dictionaryDraft)
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

                TextField("Search dictionary", text: $model.dictionarySearch)
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
        if model.addDictionaryTerm(draft) { model.dictionaryDraft = "" }
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

    /// Which field holds the caret. Optional so that *nothing* is a value this can hold, which is
    /// what the panel opens on — see `defaultFocus` at the bottom of the form.
    private enum Field: Hashable { case key }

    /// The window opens itself when there is no key, so the caret starts where the fix is.
    @FocusState private var focus: Field?

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
                    .autocorrectionDisabled()
                modelProblem(model.modelProblem)
                // Shown only where transcription and rewriting are genuinely different models,
                // rather than as a second field that repeats the first one everywhere else.
                if model.provider.defaultTextModel != nil {
                    TextField("Rewrite model", text: $model.textModel)
                        .autocorrectionDisabled()
                    modelProblem(model.textModelProblem)
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
                    .focused($focus, equals: .key)
                    // Not `initial: true`. This panel is rebuilt every time the sidebar returns to
                    // it, and an initial fire would re-steal the caret on each visit — the intent
                    // is the window opening on a missing key, not every look at General.
                    .onChange(of: model.keyStatus) {
                        if model.keyStatus == .missing { focus = .key }
                    }
                    .task {
                        if !model.hasFocusedEmptyKeyField, model.keyStatus == .missing {
                            model.hasFocusedEmptyKeyField = true
                            focus = .key
                        }
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

                // Shown only once the endpoint field points somewhere unmeasured, because that is
                // the only configuration it is about — and it sits with the other notes rather
                // than under the field itself, so the section keeps fields above and explanations
                // below. Orange for the same reason as the warning above it: what it predicts is
                // a lost dictation, not a trade-off.
                if let audioNote = model.endpointAudioNote {
                    Label(audioNote, systemImage: "waveform.badge.exclamationmark")
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
                    modelProblem(model.fallbackModelProblem)

                    TextField(
                        "Second provider endpoint", text: $model.fallbackEndpoint,
                        prompt: Text(fallbackKind.defaultEndpoint)
                    )
                    .autocorrectionDisabled()

                    SecureField("Second provider API key", text: $model.fallbackAPIKey)
                        .textContentType(.password)

                    // The second backend has its own endpoint field and its own test button, so
                    // it can be pointed at a text-only relay entirely independently of the first.
                    // A fallback only ever runs when the primary is already slow, which is the
                    // worst moment to discover the audio went nowhere.
                    if let audioNote = model.fallbackEndpointAudioNote {
                        Label(audioNote, systemImage: "waveform.badge.exclamationmark")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }

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

            // "Recording", not "Dictation": everything here is about how a recording starts,
            // stops, cancels and submits, whichever of the three keys began it. What the words then
            // become is the next section's question, and merging the two is what made Fidelity sit
            // among the hot keys pointing at typography settings four screens away.
            Section("Recording") {
                LabeledContent("Hot key") {
                    HotkeyRecorder(
                        value: Binding(
                            get: { Optional(model.trigger) },
                            set: { if let value = $0 { model.trigger = value } }),
                        canClear: false,
                        conflictingValues: [model.rewriteTrigger, model.translateTrigger],
                        setCaptureActive: model.setHotkeyCaptureActive)
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
                Picker("Finish with Return", selection: $model.finishAndSendAction) {
                    Text("Insert only").tag(FinishAndSendAction.disabled)
                    Text("Insert + Return").tag(FinishAndSendAction.returnKey)
                    Text("Insert + ⌘ Return").tag(FinishAndSendAction.modifiedReturn)
                }
                Text(dictationHelp)
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            TranscriptStyleSection(model: model)

            TranslationSection(model: model)

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
        // Nothing, deliberately. Left to itself AppKit hands the caret to the first text field in
        // the window, which is Model — so opening Settings and typing put arbitrary text into the
        // model ID, and the field saves as you type. `.userInitiated` because the value being
        // asked for here is "no default", which the automatic evaluation would otherwise treat as
        // no preference at all and fall back to that same first field. A missing key still takes
        // the caret, from the `.task` on the key field above: that is a placement with a reason,
        // and this one never had one.
        .defaultFocus($focus, nil, priority: .userInitiated)
    }

    /// The sentence under a Model field when what is in it could not be a model ID.
    ///
    /// Orange rather than red, and phrased as what the field takes rather than as a rejection:
    /// nothing has been lost at this point. The previous value is still stored and still running
    /// dictations — see `SettingsModel.model` — and this says why the box in front of you has not
    /// replaced it.
    @ViewBuilder
    private func modelProblem(_ message: String?) -> some View {
        if let message {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var dictationHelp: String {
        let cancel = model.cancelShortcut == .escape
            ? "Escape cancels recording or transcription only while one is active; at all other "
                + "times it belongs to the app you are using."
            : "No key is intercepted to cancel an active dictation."
        let submit = switch model.finishAndSendAction {
        case .disabled: " It will not submit the text."
        case .returnKey: " DoNotType then sends Return."
        case .modifiedReturn: " DoNotType then sends ⌘ Return."
        }
        return "A quick tap starts recording and a second tap ends it; holding the key past a "
            + "moment records only while held. " + cancel
            + " Press Return while recording to stop and insert the transcript." + submit
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
                    draft: $model.blockedBundleIDDraft,
                    placeholder: "com.example.app",
                    caption: "Bundle identifiers. Checked before anything is captured.")
            }

            Section("Never read these pages") {
                ListEditor(
                    items: $model.blockedURLPrefixes,
                    draft: $model.blockedURLPrefixDraft,
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
    /// Bound rather than held: the panel is rebuilt whenever the settings window navigates back to
    /// it, which would drop whatever was half-typed. Each blocklist owns its own draft on the model.
    @Binding var draft: String
    let placeholder: String
    let caption: String

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
                    "Failed dictations always keep their audio until they succeed, so Retry works."
                        + " Keeping it for the ones that succeeded is what lets you redo a"
                        + " transcription or save the recording.")

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

            // One circular arrow per row, doing the thing that row needs. On a failed dictation
            // that is Retry — the words never reached a cursor, so they are typed. On a completed
            // one it is a redo: the words arrived and arrived wrong, and re-running the
            // transcription is the only fix that does not mean saying it all again.
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
            } else if record.canRedo {
                Button {
                    Task { await model.redo(record) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Redo the transcription")
            }

            if record.status == .completed {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(record.text, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy transcript")
            }

            // The recording is the evidence behind the row: it is what a wrong transcript should
            // be judged against, and the one thing here that cannot be reconstructed. Offered
            // wherever it still exists.
            if record.canRedo {
                Button {
                    Task { await model.saveAudio(record) }
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .buttonStyle(.borderless)
                .help("Save the original audio")
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


// MARK: - Hot-key recorder

/// A settings control that records the next physical shortcut instead of asking the user to
/// translate it into a dropdown choice. Modifier-only keys are committed when released, which
/// leaves time to turn Command into Command+Space (or any other chord) before capture completes.
private struct HotkeyRecorder: View {
    @Binding var value: HotkeyMonitor.Trigger?
    let canClear: Bool
    /// Every key already bound to another mode. A list rather than one value because there are
    /// three of them now, and a recorder that only knew about one would happily let Translate
    /// steal the key Rewrite is using.
    let conflictingValues: [HotkeyMonitor.Trigger?]
    let setCaptureActive: (Bool) -> Bool

    @State private var isCapturing = false
    @State private var eventMonitor: Any?
    @State private var pressedModifierKeys: Set<CGKeyCode> = []
    @State private var modifierCandidate: CGKeyCode?
    @State private var peakModifiers: CGEventFlags = []
    @State private var attemptedKeyChord = false
    @State private var issue: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 6) {
                Button(action: toggleCapture) {
                    HStack(spacing: 7) {
                        if isCapturing {
                            Image(systemName: "keyboard.badge.ellipsis")
                            Text("Press shortcut…")
                        } else {
                            Image(systemName: "keyboard")
                            Text(value?.label ?? "Not set")
                                .monospaced()
                        }
                    }
                    .frame(minWidth: 150, minHeight: 24)
                    .padding(.horizontal, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .controlBackgroundColor)))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(
                            issue == nil
                                ? (isCapturing ? Color.accentColor : Color.secondary.opacity(0.45))
                                : Color.red,
                            lineWidth: isCapturing || issue != nil ? 1.5 : 1)
                }
                .accessibilityLabel(isCapturing ? "Recording hot key" : "Hot key")
                .accessibilityValue(value?.label ?? "Not set")
                .help(
                    isCapturing
                        ? "Press a key combination. Press Escape to cancel."
                        : "Click, then press the key combination you want to use.")

                if canClear, value != nil, !isCapturing {
                    Button {
                        issue = nil
                        value = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear hot key")
                    .help("Remove this optional hot key")
                }
            }

            if let issue {
                Text(issue)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if isCapturing {
                Text("Press Escape to cancel")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onDisappear { stopCapture() }
    }

    private func toggleCapture() {
        if isCapturing {
            stopCapture()
            return
        }
        guard setCaptureActive(true) else {
            issue = "Finish the active dictation or other shortcut first."
            return
        }

        issue = nil
        isCapturing = true
        pressedModifierKeys = []
        modifierCandidate = nil
        peakModifiers = []
        attemptedKeyChord = false
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .flagsChanged]
        ) { event in
            handle(event)
        }
    }

    private func stopCapture() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        pressedModifierKeys = []
        modifierCandidate = nil
        peakModifiers = []
        attemptedKeyChord = false
        if isCapturing {
            isCapturing = false
            _ = setCaptureActive(false)
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .keyDown:
            let modifiers = Self.cgModifiers(event.modifierFlags)
            if event.keyCode == 53, modifiers.isEmpty {  // Escape cancels capture.
                stopCapture()
                return nil
            }
            if (event.keyCode == 51 || event.keyCode == 117), modifiers.isEmpty {
                if canClear {
                    stopCapture()
                    value = nil
                } else {
                    issue = "The primary hot key cannot be empty."
                }
                return nil
            }

            // If validation rejects this chord, releasing its modifier must not silently replace
            // it with that modifier alone. Wait until all held modifiers are released, then let
            // the user make another attempt.
            attemptedKeyChord = true
            let trigger = HotkeyMonitor.Trigger(
                keyCode: event.keyCode,
                modifiers: modifiers,
                keyLabel: Self.keyLabel(for: event))
            accept(trigger)
            return nil

        case .flagsChanged:
            let keyCode = event.keyCode
            guard let flag = HotkeyMonitor.Trigger.modifierFlag(for: keyCode),
                let label = HotkeyMonitor.Trigger.modifierLabel(for: keyCode)
            else { return event }

            if pressedModifierKeys.contains(keyCode) {
                pressedModifierKeys.remove(keyCode)
                if attemptedKeyChord {
                    if pressedModifierKeys.isEmpty {
                        attemptedKeyChord = false
                        modifierCandidate = nil
                        peakModifiers = []
                    }
                    return event
                }
                guard let candidate = modifierCandidate,
                    let candidateLabel = HotkeyMonitor.Trigger.modifierLabel(for: candidate)
                else { return event }
                let trigger = HotkeyMonitor.Trigger(
                    keyCode: candidate,
                    modifiers: peakModifiers,
                    keyLabel: candidate == keyCode ? label : candidateLabel)
                accept(trigger)
            } else {
                pressedModifierKeys.insert(keyCode)
                modifierCandidate = keyCode
                peakModifiers.formUnion(Self.cgModifiers(event.modifierFlags))
                peakModifiers.formUnion(flag)
            }
            // Modifier state still reaches AppKit, preventing a swallowed key-down from leaving
            // the settings window thinking Command or Option is held after capture ends.
            return event

        default:
            return event
        }
    }

    private func accept(_ trigger: HotkeyMonitor.Trigger) {
        if trigger.isReserved {
            issue = "Return and Escape are reserved for finishing or cancelling a dictation."
            return
        }
        guard trigger.isSafeForGlobalUse else {
            issue = "Add ⌘, ⌥, or ⌃, or use a modifier or function key by itself."
            return
        }
        guard !conflictingValues.contains(trigger) else {
            issue = "This hot key is already used by another dictation action."
            return
        }
        stopCapture()
        value = trigger
    }

    private static func cgModifiers(_ flags: NSEvent.ModifierFlags) -> CGEventFlags {
        var result: CGEventFlags = []
        if flags.contains(.command) { result.insert(.maskCommand) }
        if flags.contains(.shift) { result.insert(.maskShift) }
        if flags.contains(.control) { result.insert(.maskControl) }
        if flags.contains(.option) { result.insert(.maskAlternate) }
        if flags.contains(.function) { result.insert(.maskSecondaryFn) }
        return result
    }

    private static func keyLabel(for event: NSEvent) -> String {
        let namedKeys: [CGKeyCode: String] = [
            36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Esc", 71: "Clear",
            76: "Enter", 114: "Help", 115: "Home", 116: "Page Up", 117: "Forward Delete",
            119: "End", 121: "Page Down", 123: "←", 124: "→", 125: "↓", 126: "↑",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7",
            100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13",
            107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19",
            90: "F20",
        ]
        if let named = namedKeys[event.keyCode] { return named }
        if let characters = event.charactersIgnoringModifiers?.trimmed, !characters.isEmpty {
            return characters.uppercased()
        }
        return "Key \(event.keyCode)"
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
/// Everything that decides what a finished transcript looks like, in one place.
///
/// This was four separate sections — Fidelity up with the hot keys, then Typography, then a style
/// dropdown, then a preview — and the split was the problem rather than the labels. Each part had
/// to end by pointing at another ("Fidelity above is the separate dial for…"), which is what a
/// grouping does when it is wrong. They are one question: *how do my words get written down*, asked
/// in four steps — which words survive, what shape they take, what is guaranteed regardless, and
/// what that combination actually produces.
///
/// The last step is the one that makes the rest usable. Every control above it is a *cause* and
/// what somebody needs is the *effect*; no label closes that gap, and the one that read
/// `Chat — short lines, light punctuation` was describing its effect accurately while being read as
/// a mood.
private struct TranscriptStyleSection: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Section("How your transcript is written") {
            Text("Nothing here may add, remove or reword anything you said.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Subheading("Which of your words survive")
            Picker("Fidelity", selection: $model.fidelity) {
                Text("Raw — every um and false start").tag(Fidelity.raw)
                Text("Light — drop fillers, keep your words").tag(Fidelity.light)
                Text("Tidy — light, plus punctuation").tag(Fidelity.tidy)
            }
            Text("Even Tidy only changes punctuation. None of these make you sound more formal.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Subheading("What shape they take")
            // Buttons rather than a picker: pressing one is not choosing a mode, it fills a field
            // you may then edit. A picker would show a selection that stops being true the moment
            // somebody types.
            LabeledContent("Write it like this") {
                HStack(spacing: 8) {
                    ForEach(DictationPreset.allCases, id: \.self) { preset in
                        Button(preset.label) { model.applyPreset(preset) }
                            .help(preset.shape)
                    }
                    Button("Clear") { model.dictationExample = "" }
                        .disabled(model.dictationExample.isEmpty)
                }
            }
            TextField(
                "Empty — however the model would write it",
                text: $model.dictationExample, axis: .vertical
            )
            .lineLimit(4...12)
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("dictation-example")
            Text(
                "Describe how you want your transcripts written, or paste a sentence written that "
                    + "way — a preset button fills this in and you can edit it. Layout only: line "
                    + "breaks, punctuation, how long the lines are. Empty sends nothing extra, "
                    + "which is the default. Trimmed to \(Typography.maxSampleCharacters) "
                    + "characters."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)

            Subheading("What holds regardless")
            Picker("Chinese and Latin", selection: $model.typographySpacing) {
                ForEach(TypographySpacing.allCases, id: \.self) { spacing in
                    Text(spacing.label).tag(spacing)
                }
            }
            Text("Applied on this Mac after the transcript comes back — a guarantee.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Picker("Chinese script", selection: $model.chineseScript) {
                ForEach(ChineseScript.allCases, id: \.self) { script in
                    Text(script.label).tag(script)
                }
            }
            Text("Asked of the model on every request — a request, not a guarantee.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Subheading("What all of that actually produces")
            PreviewControls(model: model)
        }
    }
}

/// A labelled step inside a section, so one heading can hold four without the reader losing which
/// question each control is answering.
private struct Subheading: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 4)
    }
}

/// The preview: two buttons, two panes, and a sentence about what each will cost.
private struct PreviewControls: View {
    @Bindable var model: SettingsModel

    var body: some View {
        HStack(spacing: 8) {
            Button(model.isRecordingClip ? "Stop and transcribe" : "Record a clip") {
                Task { await model.toggleClipPreview() }
            }
            .disabled(model.isPreviewing)

            Button("Try it on your last dictation") {
                Task { await model.runStoredPreview() }
            }
            .disabled(model.isPreviewing || model.isRecordingClip || !model.canPreviewStored)

            if model.preview != nil {
                Button("Clear") { model.clearPreview() }
                    .disabled(model.isPreviewing || model.isRecordingClip)
            }
            if model.isPreviewing { ProgressView().controlSize(.small) }
        }

        if let preview = model.preview {
            // Side by side, because the question is always comparative. A single "after" pane would
            // need the reader to remember what they used to get, which is exactly the thing nobody
            // can do reliably about their own dictation.
            HStack(alignment: .top, spacing: 12) {
                if preview.baseline != .none {
                    PreviewPane(title: preview.baseline.label, text: preview.before)
                }
                PreviewPane(title: StylePreview.styledLabel, text: preview.after)
            }
            Text("\(preview.source). Nothing in History was changed.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }

        if let problem = model.previewProblem {
            Label(problem, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        } else if model.isRecordingClip {
            Text("Recording. Say a sentence or two, then press Stop.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else {
            Text(
                StylePreview.costNote(for: model.clipBaseline)
                    + (model.canPreviewStored
                        ? " Or send your most recent kept recording again — one request."
                        : " " + StylePreview.noStoredRecording)
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }
}

/// One half of the comparison. Selectable, because the difference is often one character.
private struct PreviewPane: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                Text(text.isEmpty ? "—" : text)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxHeight: 160)
            .padding(8)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Its own section, under Typography and above Rewrite, because it is the setting that
/// *replaces* a rewrite rather than another shade of one.
///
/// A key of its own, on the same reasoning as Rewrite's. A target language used to be enough on
/// its own to change what every key delivered — the main one included — which made it the one
/// setting in the product that could take verbatim away without being asked twice. It is now what
/// the translate key writes in, and nothing at all until that key is bound.
private struct TranslationSection: View {
    @Bindable var model: SettingsModel

    var body: some View {
        let availability = model.translateAvailability

        Section("Translation") {
            LabeledContent("Translate hot key") {
                HotkeyRecorder(
                    value: $model.translateTrigger,
                    canClear: true,
                    conflictingValues: [model.trigger, model.rewriteTrigger],
                    setCaptureActive: model.setHotkeyCaptureActive)
            }

            LabeledContent("Translate to") {
                TextField("Not set — nothing to translate into", text: $model.translateTo)
                    .textFieldStyle(.roundedBorder)
            }
            if !TranslationTarget.suggestions.isEmpty {
                Picker("Common languages", selection: $model.translateTo) {
                    Text("Not set").tag("")
                    ForEach(TranslationTarget.suggestions, id: \.self) { language in
                        Text(language).tag(language)
                    }
                }
            }
            if let problem = TranslationTarget.validationMessage(model.translateTo) {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Only once a key is bound. Before that this section is an offer, and an offer that
            // opens with a warning about a language nobody has asked for yet reads as a fault.
            if model.translateTrigger != nil, let reason = availability.reason {
                Label(reason, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if model.translateTrigger == nil {
                Text(
                    "Optional. Bind a third key and holding it dictates and then writes the same "
                        + "thing in your target language. Your main key stays verbatim and your "
                        + "rewrite key stays a rewrite — which key you hold decides, before you "
                        + "speak."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            } else {
                Text(
                    "\(model.translateTrigger!.label) dictates and then writes it in "
                        + "\(model.translateTo). The verbatim transcript is still produced "
                        + "first, still stored, and still one ⌘⌥Z away. The field is free text, "
                        + "like Model: the model is the authority on which languages it can write."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
    }
}

private struct RewriteSection: View {
    @Bindable var model: SettingsModel

    var body: some View {
        let availability = model.rewriteAvailability

        Section("Rewrite") {
            LabeledContent("Rewrite hot key") {
                HotkeyRecorder(
                    value: $model.rewriteTrigger,
                    canClear: true,
                    conflictingValues: [model.trigger, model.translateTrigger],
                    setCaptureActive: model.setHotkeyCaptureActive)
            }
            .disabled(!availability.isAvailable)

            Picker("It produces", selection: $model.rewriteStyle) {
                ForEach(RewriteStyle.allCases.filter(\.isRewrite), id: \.self) { style in
                    Text(style.label).tag(style)
                }
            }
            .disabled(!availability.isAvailable || model.rewriteTrigger == nil)

            if model.rewriteStyle == .custom {
                LabeledContent("Your style") {
                    TextField(
                        "Describe it, or paste a sentence written the way you want yours",
                        text: $model.customRewriteStyle, axis: .vertical
                    )
                    .lineLimit(3...8)
                    .textFieldStyle(.roundedBorder)
                }
                .disabled(!availability.isAvailable)
                Text("Leaving this empty means no rewrite: you get the transcript as it is.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if let reason = availability.reason {
                Label(reason, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if model.rewriteTrigger == nil {
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
                        + "\(model.rewriteTrigger!.label) rewrites. Which key you hold decides, "
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
