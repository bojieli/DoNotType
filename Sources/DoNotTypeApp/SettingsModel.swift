import DoNotTypeCore
import Foundation
import Observation

/// Observable façade over `Settings` and `HistoryStore` for the settings window.
///
/// `Settings` is backed by `UserDefaults` computed properties, which SwiftUI cannot observe, so the
/// window binds to this instead and writes through.
@MainActor
@Observable
final class SettingsModel {
    // MARK: - Provider

    var provider: ProviderKind {
        didSet {
            Settings.shared.provider = provider
            apiKey = Settings.shared.apiKey ?? ""
            model = Settings.shared.model
            textModel = Settings.shared.textModel ?? ""
            endpoint = Settings.shared.endpoint
            scheduleKeyCheck()
        }
    }

    var apiKey: String {
        didSet {
            Settings.shared.apiKey = apiKey
            scheduleKeyCheck()
        }
    }

    /// A URL to post to instead of the backend's own, for a compatible service somebody else runs.
    /// Empty means the built-in one.
    var endpoint: String {
        didSet {
            Settings.shared.endpoint = endpoint
            scheduleKeyCheck()
        }
    }

    /// Re-checked like the key, because a model this account cannot use fails identically to a bad
    /// key — at the end of a dictation, with a 404.
    var model: String {
        didSet {
            Settings.shared.model = model
            scheduleKeyCheck()
        }
    }

    /// Only shown for a backend that rewrites on a different model than it transcribes with —
    /// xAI, so far. Empty everywhere else, where one model does both.
    var textModel: String {
        didSet {
            let trimmed = textModel.trimmed
            Settings.shared.textModel = trimmed.isEmpty ? nil : trimmed
        }
    }

    var fidelity: Fidelity {
        didSet { Settings.shared.fidelity = fidelity }
    }

    var keytermBiasing: Bool {
        didSet { Settings.shared.keytermBiasing = keytermBiasing }
    }

    /// Backend started alongside the primary when it has not answered in time. Nil disables it.
    var fallbackProvider: ProviderKind? {
        didSet {
            Settings.shared.fallbackProvider = fallbackProvider
            fallbackAPIKey = fallbackProvider.map { Settings.shared.resolvedAPIKey(for: $0) ?? "" }
                ?? ""
            fallbackModel = fallbackProvider.map { Settings.shared.model(for: $0) } ?? ""
            fallbackEndpoint = fallbackProvider.map { Settings.shared.endpoint(for: $0) } ?? ""
            fallbackConnectionStatus = nil
        }
    }

    /// The fallback's own key. Stored under its provider, so choosing it here does not disturb the
    /// primary's credentials and switching back and forth loses nothing.
    var fallbackAPIKey: String = "" {
        didSet {
            // Writing back the value just loaded on a provider switch is a no-op, so this needs no
            // guard beyond having somewhere to store it.
            guard let kind = fallbackProvider else { return }
            Keychain.write(fallbackAPIKey, account: kind.rawValue)
        }
    }

    /// The fallback's model.
    ///
    /// Stored per backend, exactly like the primary's, and it always was — what was missing was
    /// any way to set it. The only route to the fallback's model used to be selecting that backend
    /// as the *primary*, typing the model, and switching back, which is not a thing anybody would
    /// guess. A fallback silently running a backend's default model is the kind of setting that
    /// looks configured and is not.
    var fallbackModel: String = "" {
        didSet {
            guard let kind = fallbackProvider, !fallbackModel.trimmed.isEmpty else { return }
            Settings.shared.setModel(fallbackModel, for: kind)
        }
    }

    /// The fallback's endpoint override. Empty means the backend's own.
    var fallbackEndpoint: String = "" {
        didSet {
            guard let kind = fallbackProvider else { return }
            Settings.shared.setEndpoint(fallbackEndpoint, for: kind)
        }
    }

    /// How long the primary gets alone before the fallback starts. The accuracy/latency dial.
    var fallbackAfterSeconds: Double {
        didSet { Settings.shared.fallbackAfterSeconds = fallbackAfterSeconds }
    }

    /// Backends that can serve as a fallback: anything except the current primary, recommended
    /// ones first.
    ///
    /// The natural pairing is the two recommended backends against each other — the whole reason
    /// to hedge is that one is accurate and slow and the other is fast and screen-blind — so
    /// whichever of them is not the primary should be the first entry here.
    var fallbackChoices: [ProviderKind] {
        ProviderKind.pickerOrder.filter { $0 != provider }
    }

    /// What the pairing will actually do, in one line, using the numbers behind it.
    var fallbackSummary: String? {
        guard let kind = fallbackProvider else { return nil }
        let seconds = Int(fallbackAfterSeconds.rounded())
        return "If \(provider.displayName) has not answered in \(seconds)s, "
            + "\(kind.rawValue) starts alongside it and whichever finishes first is used. "
            + "History records which one actually served each dictation."
    }

    /// What the selected backend can do with the screen, for the UI to state plainly instead of
    /// leaving grounding controls that quietly do nothing.
    var grounding: GroundingSupport {
        guard let provider = try? ProviderFactory.make(self.provider, apiKey: "placeholder")
        else { return .multimodal }
        return provider.grounding(forModel: model)
    }

    /// What is actually configured, in the order the question is asked: the model that runs the
    /// request, then who serves it.
    ///
    /// The provider alone is not an answer — OpenRouter serves hundreds of models — and this line
    /// is the one place the pair is stated, including the second model where there is one.
    var configurationSummary: String {
        let base = provider.label(forModel: model)
        guard provider.defaultTextModel != nil, !textModel.trimmed.isEmpty else { return base }
        return "\(base) · rewrites on \(textModel)"
    }

    /// What the selected backend is recommended for, or nil for the four that are not.
    ///
    /// Shown above `groundingSummary` rather than instead of it: this line says what the choice
    /// buys, that one says what it costs, and xAI is the case where both are worth reading.
    var recommendationNote: String? { provider.recommendationNote }

    /// One line under the provider picker explaining what selecting it gives up.
    var groundingSummary: String? {
        // Not a capability difference — the gateway forwards audio correctly — but a measured
        // quality one, and the picker is where someone chooses between two entries that look
        // identical.
        if provider == .openrouter {
            return "Routes through a gateway. The same Gemini model measures worse this way than "
                + "it does from Google directly — 2 to 5 regressions per suite run against 1 — "
                + "so prefer the Google provider unless you need a model Google does not serve."
        }
        guard provider.isSpeechRecognition else { return nil }

        let shared =
            provider.supportsTextGeneration
            ? "Transcription only — this service cannot read your screen. Rewrites run on "
                + "\(textModel), a chat model reached with the same key, in a second request."
            : "Transcription only — this service cannot read your screen, and rewriting is "
                + "unavailable."
        switch provider {
        case .mistral:
            return shared + " It has no spelling-hint channel either, and it is the one that "
                + "handles Mandarin and English together without being told which is coming."
        case .deepgram:
            return shared + " It also cannot transcribe Chinese under any autodetecting setting — "
                + "it returned nothing for 44 of 68 Mandarin clips on the dictation corpus. Set "
                + "DNT_DEEPGRAM_LANGUAGE=zh if you dictate in Chinese."
        default:
            return shared
        }
    }

    /// A hard warning rather than a description: the difference between "this backend is a
    /// trade-off" and "this backend will silently lose your dictations".
    ///
    /// Deepgram returned an empty transcript for 48 of 100 clips of the maintainer's own speech.
    /// That surfaces as a failed dictation with a retry button rather than as wrong words, which
    /// is the good version of the failure — but a user who does not know why should be told
    /// before they lose an afternoon to it, not after.
    var providerWarning: String? {
        guard provider == .deepgram else { return nil }
        return "Deepgram cannot transcribe Chinese with autodetection. If you dictate in Chinese, "
            + "choose another service or set DNT_DEEPGRAM_LANGUAGE=zh."
    }

    // MARK: - Hotkey

    var trigger: HotkeyMonitor.Trigger {
        didSet {
            Settings.shared.trigger = trigger
            onHotkeyChange?()
        }
    }

    var hotkeyMode: HotkeyMonitor.Mode {
        didSet {
            Settings.shared.hotkeyMode = hotkeyMode
            onHotkeyChange?()
        }
    }

    var cancelShortcut: CancelShortcut {
        didSet {
            Settings.shared.cancelShortcut = cancelShortcut
            onHotkeyChange?()
        }
    }

    var finishAndSendAction: FinishAndSendAction {
        didSet {
            Settings.shared.finishAndSendAction = finishAndSendAction
            onHotkeyChange?()
        }
    }

    var secondaryTrigger: HotkeyMonitor.Trigger? {
        didSet {
            Settings.shared.secondaryTrigger = secondaryTrigger
            onHotkeyChange?()
        }
    }

    var secondaryStyle: RewriteStyle {
        didSet { Settings.shared.secondaryStyle = secondaryStyle }
    }

    /// Whether a rewrite can run at all, and what to say when it cannot.
    ///
    /// Read from the same rule every client uses, rather than asked locally — this window used to
    /// not ask at all, and offered the binding whatever was configured.
    var rewriteAvailability: RewriteAvailability {
        RewriteAvailability.resolve(provider: provider) { kind in
            !(Settings.shared.resolvedAPIKey(for: kind) ?? "").isEmpty
        }
    }

    var microphoneUID: String? {
        didSet { Settings.shared.microphoneUID = microphoneUID }
    }

    var interactionSounds: Bool {
        didSet { Settings.shared.interactionSounds = interactionSounds }
    }

    var launchAtLogin: Bool {
        didSet { LaunchAtLogin.set(launchAtLogin) }
    }

    /// Re-read each time settings open: devices come and go while the app is running.
    var availableMicrophones: [AudioDevices.Device] { AudioDevices.inputs() }

    /// What is actually in use, which may not be what was chosen if the device was unplugged.
    var activeMicrophoneName: String {
        if let uid = microphoneUID, let id = AudioDevices.resolve(preferredUID: uid),
            let name = AudioDevices.name(of: id)
        {
            return name
        }
        let fallback = AudioDevices.name(of: AudioDevices.defaultInputID()) ?? "system default"
        return microphoneUID == nil ? "\(fallback) (system default)" : "\(fallback) — chosen device unavailable"
    }

    var onHotkeyChange: (() -> Void)?

    // MARK: - Grounding

    var groundingEnabled: Bool {
        didSet { Settings.shared.groundingEnabled = groundingEnabled }
    }

    var screenshotEnabled: Bool {
        didSet { Settings.shared.screenshotEnabled = screenshotEnabled }
    }

    var blockedBundleIDs: [String] {
        didSet { Settings.shared.blockedBundleIDs = blockedBundleIDs }
    }

    var blockedURLPrefixes: [String] {
        didSet { Settings.shared.blockedURLPrefixes = blockedURLPrefixes }
    }

    // MARK: - Dictionary

    enum DictionarySource: String, Sendable {
        case manual
        case learned
    }

    struct DictionaryEntry: Identifiable, Equatable, Sendable {
        let term: String
        let source: DictionarySource

        var id: String { "\(source.rawValue):\(term.lowercased())" }
    }

    var learnDictionaryFromEdits: Bool {
        didSet { Settings.shared.learnDictionaryFromEdits = learnDictionaryFromEdits }
    }
    private(set) var dictionaryTerms: [String]
    private(set) var learnedDictionaryTerms: [String]
    private(set) var dictionaryStatus: String?
    private(set) var dictionaryStatusIsError = false

    var dictionaryEntries: [DictionaryEntry] {
        dictionaryTerms.map { DictionaryEntry(term: $0, source: .manual) }
            + learnedDictionaryTerms.map { DictionaryEntry(term: $0, source: .learned) }
    }

    var dictionaryCount: Int { dictionaryEntries.count }

    /// Re-read after the background correction watcher learns something while Settings is open.
    func refreshDictionary() {
        dictionaryTerms = Settings.shared.dictionaryTerms
        learnedDictionaryTerms = Settings.shared.learnedDictionaryTerms
    }

    func addDictionaryTerm(_ raw: String) -> Bool {
        do {
            let all = try PersonalDictionary.adding(
                raw, to: dictionaryTerms + learnedDictionaryTerms)
            guard let term = all.last else { return false }
            dictionaryTerms.append(term)
            Settings.shared.dictionaryTerms = dictionaryTerms
            setDictionaryStatus("Added “\(term)”.")
            return true
        } catch {
            setDictionaryStatus(error.localizedDescription, isError: true)
            return false
        }
    }

    func updateDictionaryEntry(_ entry: DictionaryEntry, to raw: String) -> Bool {
        do {
            let all = dictionaryTerms + learnedDictionaryTerms
            let updated = try PersonalDictionary.replacing(entry.term, with: raw, in: all)
            guard let index = all.firstIndex(of: entry.term) else { return false }
            let term = updated[index]
            switch entry.source {
            case .manual:
                guard let sourceIndex = dictionaryTerms.firstIndex(of: entry.term) else {
                    return false
                }
                dictionaryTerms[sourceIndex] = term
                Settings.shared.dictionaryTerms = dictionaryTerms
            case .learned:
                guard let sourceIndex = learnedDictionaryTerms.firstIndex(of: entry.term) else {
                    return false
                }
                learnedDictionaryTerms[sourceIndex] = term
                Settings.shared.learnedDictionaryTerms = learnedDictionaryTerms
            }
            setDictionaryStatus("Updated “\(term)”.")
            return true
        } catch {
            setDictionaryStatus(error.localizedDescription, isError: true)
            return false
        }
    }

    func removeDictionaryEntry(_ entry: DictionaryEntry) {
        switch entry.source {
        case .manual:
            dictionaryTerms.removeAll { $0 == entry.term }
            Settings.shared.dictionaryTerms = dictionaryTerms
        case .learned:
            learnedDictionaryTerms.removeAll { $0 == entry.term }
            Settings.shared.learnedDictionaryTerms = learnedDictionaryTerms
        }
        setDictionaryStatus("Removed “\(entry.term)”.")
    }

    func importDictionary(from url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            if let bytes = values.fileSize, bytes > 5 * 1_024 * 1_024 {
                setDictionaryStatus("The CSV file is larger than 5 MB.", isError: true)
                return
            }
            let imported = try PersonalDictionary.entries(fromCSV: Data(contentsOf: url))
            let before = dictionaryTerms + learnedDictionaryTerms
            let merged = try PersonalDictionary.importing(imported, into: before)
            let keys = Set(before.map { $0.lowercased() })
            let added = merged.filter { !keys.contains($0.lowercased()) }
            dictionaryTerms.append(contentsOf: added)
            Settings.shared.dictionaryTerms = dictionaryTerms
            setDictionaryStatus(
                added.isEmpty
                    ? "No new entries in \(url.lastPathComponent)."
                    : "Imported \(added.count) entr\(added.count == 1 ? "y" : "ies").")
        } catch {
            setDictionaryStatus(error.localizedDescription, isError: true)
        }
    }

    private func setDictionaryStatus(_ value: String, isError: Bool = false) {
        dictionaryStatus = value
        dictionaryStatusIsError = isError
    }

    // MARK: - History

    var retention: RetentionPolicy {
        didSet {
            Settings.shared.retention = retention
            Task { await reconfigureStore() }
        }
    }

    var keepAudio: Bool {
        didSet {
            Settings.shared.keepAudio = keepAudio
            Task { await reconfigureStore() }
        }
    }

    // MARK: - Prompt

    /// Which part the editor is showing. One file at a time, because the contract is twelve
    /// separate instructions and editing them in one scrolling buffer was how the shipped text and
    /// the documentation about it ended up in the same box.
    var selectedPart: PromptPart = .system {
        didSet { if selectedPart != oldValue { loadPrompt() } }
    }

    /// The selected part's text. Editable, because an open-source app whose entire behaviour is a
    /// prompt should not make that prompt read-only.
    var promptText: String = ""
    private(set) var promptStatus: String?
    private(set) var customParts: Set<PromptPart> = []

    /// Whether the *selected* part is the user's rather than the shipped one.
    var isPromptCustom: Bool { customParts.contains(selectedPart) }

    // MARK: - History

    var query = HistoryQuery() {
        didSet { if query != oldValue { applyQuery() } }
    }

    private(set) var allRecords: [DictationRecord] = []
    private(set) var records: [DictationRecord] = []
    private(set) var knownApps: [String] = []
    private(set) var audioBytes: Int64 = 0
    private(set) var retryingIDs: Set<UUID> = []
    private(set) var lastRetrySummary: String?

    /// What is known about the key, checked at launch and after every edit rather than at the end
    /// of a dictation. See `APIKeyStatus`.
    private(set) var keyStatus: APIKeyStatus = .unchecked
    private var keyCheckTask: Task<Void, Never>?

    /// Fires whenever `keyStatus` settles, so the menu bar can say so without an open window.
    var onKeyStatusChange: (() -> Void)?

    /// Live connection check, so "it isn't working" has an answer in the UI.
    ///
    /// This one is the *primary*'s, and always was. The button used to sit under the Fallback
    /// heading, which made it read as testing the fallback — so a user with a broken second key
    /// could press it, see a tick, and still lose every dictation the fallback served. There is a
    /// button per backend now, and each says which one it checked.
    var connectionStatus: String? {
        keyStatus.summary(provider: provider, latency: connectionLatency)
    }
    var isCheckingConnection: Bool { keyStatus == .checking }
    private var connectionLatency: Duration?

    /// The fallback's own check, which nothing was previously able to run.
    private(set) var fallbackConnectionStatus: String?
    private(set) var isCheckingFallbackConnection = false
    private var fallbackCheckTask: Task<Void, Never>?

    /// Probes the fallback backend with its own key, model and endpoint.
    func checkFallbackConnection() async {
        fallbackCheckTask?.cancel()
        let task = Task { await performFallbackCheck() }
        fallbackCheckTask = task
        await task.value
    }

    private func performFallbackCheck() async {
        guard let kind = fallbackProvider else {
            fallbackConnectionStatus = nil
            return
        }
        isCheckingFallbackConnection = true
        defer { isCheckingFallbackConnection = false }

        let key = Settings.shared.resolvedAPIKey(for: kind) ?? ""
        guard !key.isEmpty else {
            fallbackConnectionStatus = "✗ No API key set for \(kind.displayName)."
            return
        }
        guard let client = try? Settings.shared.makeProvider(kind, apiKey: key) else {
            fallbackConnectionStatus = "✗ Could not configure \(kind.displayName)."
            return
        }

        let model = Settings.shared.model(for: kind)
        let clock = ContinuousClock()
        let started = clock.now
        let outcome = await ProviderProbe.check(client, model: model)
        let latency = started.duration(to: clock.now)
        let status: APIKeyStatus
        switch outcome {
        case .accepted: status = .valid
        case .rejected(let message): status = .rejected(message)
        case .inconclusive(let message): status = .unverified(message)
        }
        guard !Task.isCancelled else { return }
        fallbackConnectionStatus = status.summary(provider: kind, latency: latency)
    }

    let store: HistoryStore
    let prompts: PromptStore

    init(store: HistoryStore) {
        self.store = store
        self.prompts = PromptStore(directory: HistoryStore.defaultDirectory())
        let settings = Settings.shared
        provider = settings.provider
        apiKey = settings.apiKey ?? ""
        model = settings.model
        textModel = settings.textModel ?? ""
        endpoint = settings.endpoint
        fidelity = settings.fidelity
        keytermBiasing = settings.keytermBiasing
        fallbackProvider = settings.fallbackProvider
        fallbackAfterSeconds = settings.fallbackAfterSeconds
        fallbackAPIKey = settings.fallbackProvider
            .map { settings.resolvedAPIKey(for: $0) ?? "" } ?? ""
        fallbackModel = settings.fallbackProvider.map { settings.model(for: $0) } ?? ""
        fallbackEndpoint = settings.fallbackProvider.map { settings.endpoint(for: $0) } ?? ""
        trigger = settings.trigger
        hotkeyMode = settings.hotkeyMode
        cancelShortcut = settings.cancelShortcut
        finishAndSendAction = settings.finishAndSendAction
        secondaryTrigger = settings.secondaryTrigger
        secondaryStyle = settings.secondaryStyle
        microphoneUID = settings.microphoneUID
        interactionSounds = settings.interactionSounds
        launchAtLogin = LaunchAtLogin.isEnabled
        groundingEnabled = settings.groundingEnabled
        screenshotEnabled = settings.screenshotEnabled
        blockedBundleIDs = settings.blockedBundleIDs
        blockedURLPrefixes = settings.blockedURLPrefixes
        learnDictionaryFromEdits = settings.learnDictionaryFromEdits
        dictionaryTerms = settings.dictionaryTerms
        learnedDictionaryTerms = settings.learnedDictionaryTerms
        retention = settings.retention
        keepAudio = settings.keepAudio
        loadPrompt()
        // Before the first dictation, not when the window opens: this model is built at launch and
        // the controller reads the same store.
        migrateLegacyPromptIfNeeded()
    }

    // MARK: - Settings transfer

    func settingsTransferDocument() -> SettingsTransferDocument {
        let settings = Settings.shared
        let providers = Dictionary(uniqueKeysWithValues: ProviderKind.allCases.map { kind in
            (
                kind.rawValue,
                SettingsTransferDocument.Provider(
                    model: settings.model(for: kind),
                    textModel: settings.textModel(for: kind),
                    endpoint: settings.endpoint(for: kind).trimmed.isEmpty
                        ? nil : settings.endpoint(for: kind).trimmed,
                    apiKey: settings.storedAPIKey(for: kind))
            )
        })
        return SettingsTransferDocument(
            selectedProvider: settings.provider.rawValue,
            providers: providers,
            fidelity: settings.fidelity.rawValue,
            fallback: settings.fallbackProvider.map {
                .init(provider: $0.rawValue, afterSeconds: settings.fallbackAfterSeconds)
            },
            retention: settings.retention.rawValue,
            keepAudio: settings.keepAudio,
            dictionary: .init(
                manual: settings.dictionaryTerms,
                learned: settings.learnedDictionaryTerms,
                learnsFromEdits: settings.learnDictionaryFromEdits),
            desktop: .init(
                trigger: settings.trigger.rawValue,
                hotkeyMode: settings.hotkeyMode.rawValue,
                cancelShortcut: settings.cancelShortcut.rawValue,
                finishAndSendAction: settings.finishAndSendAction.rawValue,
                secondaryTrigger: settings.secondaryTrigger?.rawValue,
                secondaryStyle: settings.secondaryStyle.rawValue,
                interactionSounds: settings.interactionSounds,
                launchAtLogin: LaunchAtLogin.isEnabled,
                groundingEnabled: settings.groundingEnabled,
                screenshotEnabled: settings.screenshotEnabled,
                keytermBiasing: settings.keytermBiasing,
                blockedBundleIDs: settings.blockedBundleIDs,
                blockedURLPrefixes: settings.blockedURLPrefixes,
                logLevel: settings.logLevel.name,
                logContent: settings.logContent,
                fileMode: settings.fileMode.rawValue))
    }

    /// Replaces portable preferences after validating every enum reference up front. Validation
    /// before the first write prevents a malformed hand-edited document from half-applying.
    func importSettingsTransfer(_ document: SettingsTransferDocument) async throws {
        try document.validate()
        guard let selected = ProviderKind(persistedValue: document.selectedProvider) else {
            throw SettingsTransferApplyError.unsupportedValue(
                field: "selectedProvider", value: document.selectedProvider)
        }
        let importedProviders: [(ProviderKind, SettingsTransferDocument.Provider)] = document
            .providers.compactMap { raw, value in
                guard let kind = ProviderKind(persistedValue: raw) else { return nil }
                return (kind, value)
            }
        guard let importedFidelity = Fidelity(rawValue: document.fidelity) else {
            throw SettingsTransferApplyError.unsupportedValue(
                field: "fidelity", value: document.fidelity)
        }
        guard let importedRetention = RetentionPolicy(rawValue: document.retention) else {
            throw SettingsTransferApplyError.unsupportedValue(
                field: "retention", value: document.retention)
        }
        let importedFallback: ProviderKind? = try document.fallback.map { fallback in
            guard let kind = ProviderKind(persistedValue: fallback.provider) else {
                throw SettingsTransferApplyError.unsupportedValue(
                    field: "fallback.provider", value: fallback.provider)
            }
            return kind
        }

        var desktopValues: (
            HotkeyMonitor.Trigger, HotkeyMonitor.Mode, CancelShortcut, FinishAndSendAction,
            HotkeyMonitor.Trigger?, RewriteStyle, LogLevel, TranscriptMode
        )?
        if let desktop = document.desktop {
            guard let trigger = HotkeyMonitor.Trigger(rawValue: desktop.trigger) else {
                throw SettingsTransferApplyError.unsupportedValue(
                    field: "desktop.trigger", value: desktop.trigger)
            }
            guard let mode = HotkeyMonitor.Mode(rawValue: desktop.hotkeyMode) else {
                throw SettingsTransferApplyError.unsupportedValue(
                    field: "desktop.hotkeyMode", value: desktop.hotkeyMode)
            }
            guard let cancel = CancelShortcut(rawValue: desktop.cancelShortcut) else {
                throw SettingsTransferApplyError.unsupportedValue(
                    field: "desktop.cancelShortcut", value: desktop.cancelShortcut)
            }
            guard let finish = FinishAndSendAction(rawValue: desktop.finishAndSendAction) else {
                throw SettingsTransferApplyError.unsupportedValue(
                    field: "desktop.finishAndSendAction", value: desktop.finishAndSendAction)
            }
            let secondaryTrigger: HotkeyMonitor.Trigger? = try desktop.secondaryTrigger.map { raw in
                guard let value = HotkeyMonitor.Trigger(rawValue: raw) else {
                    throw SettingsTransferApplyError.unsupportedValue(
                        field: "desktop.secondaryTrigger", value: raw)
                }
                return value
            }
            guard let secondaryStyle = RewriteStyle(rawValue: desktop.secondaryStyle) else {
                throw SettingsTransferApplyError.unsupportedValue(
                    field: "desktop.secondaryStyle", value: desktop.secondaryStyle)
            }
            guard let logLevel = LogLevel(name: desktop.logLevel) else {
                throw SettingsTransferApplyError.unsupportedValue(
                    field: "desktop.logLevel", value: desktop.logLevel)
            }
            guard let fileMode = TranscriptMode(rawValue: desktop.fileMode) else {
                throw SettingsTransferApplyError.unsupportedValue(
                    field: "desktop.fileMode", value: desktop.fileMode)
            }
            desktopValues = (
                trigger, mode, cancel, finish, secondaryTrigger, secondaryStyle, logLevel, fileMode)
        }

        let settings = Settings.shared
        for (kind, imported) in importedProviders {
            settings.setModel(
                imported.model.trimmed.isEmpty ? kind.defaultModel : imported.model, for: kind)
            settings.setTextModel(imported.textModel, for: kind)
            settings.setEndpoint(imported.endpoint ?? "", for: kind)
            settings.setAPIKey(imported.apiKey, for: kind)
        }
        settings.provider = selected
        settings.fidelity = importedFidelity
        settings.fallbackProvider = importedFallback
        settings.fallbackAfterSeconds = document.fallback?.afterSeconds ?? 8
        settings.retention = importedRetention
        settings.keepAudio = document.keepAudio
        settings.dictionaryTerms = document.dictionary.manual
        settings.learnedDictionaryTerms = document.dictionary.learned
        settings.learnDictionaryFromEdits = document.dictionary.learnsFromEdits

        if let desktop = document.desktop, let values = desktopValues {
            settings.trigger = values.0
            settings.hotkeyMode = values.1
            settings.cancelShortcut = values.2
            settings.finishAndSendAction = values.3
            settings.secondaryTrigger = values.4
            settings.secondaryStyle = values.5
            settings.interactionSounds = desktop.interactionSounds
            LaunchAtLogin.set(desktop.launchAtLogin)
            settings.groundingEnabled = desktop.groundingEnabled
            settings.screenshotEnabled = desktop.screenshotEnabled
            settings.keytermBiasing = desktop.keytermBiasing
            settings.blockedBundleIDs = desktop.blockedBundleIDs
            settings.blockedURLPrefixes = desktop.blockedURLPrefixes
            settings.logLevel = values.6
            settings.logContent = desktop.logContent
            settings.fileMode = values.7
        }

        reloadTransferredSettings()
        onHotkeyChange?()
        await reconfigureStore()
        scheduleKeyCheck()
    }

    private func reloadTransferredSettings() {
        let settings = Settings.shared
        provider = settings.provider
        apiKey = settings.apiKey ?? ""
        model = settings.model
        textModel = settings.textModel ?? ""
        endpoint = settings.endpoint
        fidelity = settings.fidelity
        keytermBiasing = settings.keytermBiasing
        fallbackProvider = settings.fallbackProvider
        fallbackAfterSeconds = settings.fallbackAfterSeconds
        fallbackAPIKey = settings.fallbackProvider
            .map { settings.storedAPIKey(for: $0) ?? "" } ?? ""
        fallbackModel = settings.fallbackProvider.map { settings.model(for: $0) } ?? ""
        fallbackEndpoint = settings.fallbackProvider.map { settings.endpoint(for: $0) } ?? ""
        trigger = settings.trigger
        hotkeyMode = settings.hotkeyMode
        cancelShortcut = settings.cancelShortcut
        finishAndSendAction = settings.finishAndSendAction
        secondaryTrigger = settings.secondaryTrigger
        secondaryStyle = settings.secondaryStyle
        interactionSounds = settings.interactionSounds
        launchAtLogin = LaunchAtLogin.isEnabled
        groundingEnabled = settings.groundingEnabled
        screenshotEnabled = settings.screenshotEnabled
        blockedBundleIDs = settings.blockedBundleIDs
        blockedURLPrefixes = settings.blockedURLPrefixes
        learnDictionaryFromEdits = settings.learnDictionaryFromEdits
        refreshDictionary()
        retention = settings.retention
        keepAudio = settings.keepAudio
    }

    // MARK: - Prompt editing

    static func bundledPromptURL() -> URL? {
        Bundle.main.url(forResource: "prompt", withExtension: nil)
            ?? PromptBuilder.findPromptDirectory()
    }

    func loadPrompt() {
        guard let bundled = Self.bundledPromptURL() else {
            promptStatus = "Could not locate the bundled prompt/ directory."
            return
        }
        customParts = Set(prompts.customParts)
        do {
            promptText = try prompts.source(bundled: bundled).editableText(for: selectedPart)
            promptStatus = nil
        } catch {
            promptText = ""
            promptStatus = error.localizedDescription
        }
    }

    /// Validated before saving. A part that cannot build would surface as a mid-dictation failure
    /// rather than an error at the moment of editing.
    func savePrompt() {
        do {
            try prompts.save(promptText, for: selectedPart)
            customParts.insert(selectedPart)
            promptStatus = "Saved \(selectedPart.relativePath). The measured numbers in the "
                + "changelog no longer describe this part — re-run `dnt-eval suite --prompt` to "
                + "measure your own."
        } catch {
            promptStatus = error.localizedDescription
        }
    }

    /// Restores the selected part only. The others keep whatever they are, which is the point of
    /// per-part overrides: editing one clause should not pin the whole contract.
    func restoreDefaultPrompt() {
        do {
            try prompts.restore(selectedPart)
            loadPrompt()
            promptStatus = "Restored the shipped \(selectedPart.relativePath)."
        } catch {
            promptStatus = error.localizedDescription
        }
    }

    func restoreAllPrompts() {
        do {
            try prompts.restoreAll()
            loadPrompt()
            promptStatus = "Restored every part to the shipped contract."
        } catch {
            promptStatus = error.localizedDescription
        }
    }

    /// Splits a pre-split `PROMPT.md` override into part files, once, at launch.
    func migrateLegacyPromptIfNeeded() {
        guard let bundled = Self.bundledPromptURL() else { return }
        guard let migration = try? prompts.migrateLegacyPrompt(bundled: bundled) else { return }
        loadPrompt()
        guard !migration.migrated.isEmpty else { return }
        promptStatus = "Your edited prompt was split into "
            + "\(migration.migrated.map(\.relativePath).joined(separator: ", "))"
            + ". The original is at \(migration.archivedAt.path)."
    }

    var resolvedKeySource: String {
        if !apiKey.isEmpty { return "Keychain" }
        if let name = Settings.environmentAPIKeyName(for: provider) {
            return "environment (\(name))"
        }
        return "not set"
    }

    /// Shown under the key field when there is nothing to use. See `APIKeyStatus.explanation`.
    var missingKeyExplanation: String? {
        keyStatus == .missing ? APIKeyStatus.explanation(for: provider) : nil
    }

    /// Counted over everything, not the filtered view — a queue you cannot see is still a queue.
    var retryableCount: Int { allRecords.count(where: \.canRetry) }

    // MARK: - Actions

    func refresh() async {
        await reconfigureStore()
        allRecords = await store.all()
        knownApps = HistoryQuery.appNames(in: allRecords)
        audioBytes = await store.audioBytes()
        applyQuery()
    }

    private func applyQuery() {
        records = query.apply(to: allRecords)
    }

    private func reconfigureStore() async {
        await store.configure(retention: retention, keepAudioForCompleted: keepAudio)
    }

    /// A short-lived confirmation, so a button that silently succeeds still says so.
    var transientNote: String?

    func note(_ message: String) {
        transientNote = message
        Task {
            try? await Task.sleep(for: .seconds(2))
            if transientNote == message { transientNote = nil }
        }
    }

    /// The "Test connection" button, and the launch check, and the after-every-edit check. One
    /// path, so the button and the automatic check can never disagree.
    func checkConnection() async {
        keyCheckTask?.cancel()
        let task = Task { await performKeyCheck() }
        keyCheckTask = task
        await task.value
    }

    /// Debounced, because `apiKey` is written on every keystroke and a key being pasted would
    /// otherwise mean one request per character.
    func scheduleKeyCheck(after delay: Duration = .milliseconds(800)) {
        keyCheckTask?.cancel()
        keyCheckTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.performKeyCheck()
        }
    }

    private func performKeyCheck() async {
        keyStatus = .checking
        connectionLatency = nil
        onKeyStatusChange?()

        guard let key = Settings.shared.resolvedAPIKey(), !key.isEmpty else {
            return settle(.missing)
        }
        guard
            let client = try? Settings.shared.makeProvider(provider, apiKey: key)
        else {
            return settle(.rejected("Could not configure \(provider.displayName)."))
        }

        let clock = ContinuousClock()
        let started = clock.now
        let outcome = await ProviderProbe.check(client, model: model)
        let latency = started.duration(to: clock.now)
        switch outcome {
        case .accepted: settle(.valid, latency: latency)
        case .rejected(let message): settle(.rejected(message), latency: latency)
        case .inconclusive(let message): settle(.unverified(message), latency: latency)
        }
    }

    /// Drops the result of a check that a newer one has already superseded — otherwise a slow
    /// probe of the old key lands after the new key has been checked and overwrites the truth.
    private func settle(_ status: APIKeyStatus, latency: Duration? = nil) {
        guard !Task.isCancelled else { return }
        keyStatus = status
        connectionLatency = latency
        onKeyStatusChange?()
    }

    func retry(_ record: DictationRecord) async {
        guard let coordinator = makeCoordinator() else {
            lastRetrySummary = "No API key set."
            return
        }
        retryingIDs.insert(record.id)
        defer { retryingIDs.remove(record.id) }

        switch await coordinator.retry(record) {
        case .success(let text):
            lastRetrySummary = "Transcribed: \(text.prefix(60))"
            await TextInjector.insert(text)
        case .failure(let error):
            lastRetrySummary = error.localizedDescription
        }
        await refresh()
    }

    func retryAll() async {
        guard let coordinator = makeCoordinator() else {
            lastRetrySummary = "No API key set."
            return
        }
        let pending = await store.retryable()
        retryingIDs = Set(pending.map(\.id))
        defer { retryingIDs.removeAll() }

        let outcome = await coordinator.retryAll()
        lastRetrySummary = outcome.isEmpty
            ? "Nothing to retry."
            : "\(outcome.succeeded.count) succeeded, \(outcome.failed.count) still failing."
        await refresh()
    }

    func delete(_ record: DictationRecord) async {
        await store.delete(id: record.id)
        await refresh()
    }

    func deleteAll() async {
        await store.deleteAll()
        await refresh()
    }

    private func makeCoordinator() -> RetryCoordinator? {
        guard let key = Settings.shared.resolvedAPIKey(), !key.isEmpty,
            let provider = try? Settings.shared.makeProvider(provider, apiKey: key),
            let promptURL = Self.bundledPromptURL(),
            let instruction = try? prompts.builder(bundled: promptURL)
                .systemInstruction(fidelity: fidelity)
        else { return nil }

        return RetryCoordinator(
            service: TranscriptionService(
                provider: provider, model: model, systemInstruction: instruction,
                fidelity: fidelity, keytermBiasing: keytermBiasing,
                personalDictionary: Settings.shared.personalDictionaryTerms),
            store: store)
    }
}
