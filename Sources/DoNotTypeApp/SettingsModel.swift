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
        }
    }

    var apiKey: String {
        didSet { Settings.shared.apiKey = apiKey }
    }

    var model: String {
        didSet { Settings.shared.model = model }
    }

    var fidelity: Fidelity {
        didSet { Settings.shared.fidelity = fidelity }
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

    var secondaryTrigger: HotkeyMonitor.Trigger? {
        didSet {
            Settings.shared.secondaryTrigger = secondaryTrigger
            onHotkeyChange?()
        }
    }

    var secondaryStyle: RewriteStyle {
        didSet { Settings.shared.secondaryStyle = secondaryStyle }
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

    var numberCheck: NumberCheckPolicy {
        didSet { Settings.shared.numberCheck = numberCheck }
    }

    var blockedBundleIDs: [String] {
        didSet { Settings.shared.blockedBundleIDs = blockedBundleIDs }
    }

    var blockedURLPrefixes: [String] {
        didSet { Settings.shared.blockedURLPrefixes = blockedURLPrefixes }
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

    /// The prompt actually in force. Editable, because an open-source app whose entire behaviour
    /// is a prompt should not make that prompt read-only.
    var promptText: String = ""
    private(set) var promptStatus: String?
    private(set) var isPromptCustom = false

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

    /// Live connection check, so "it isn't working" has an answer in the UI.
    private(set) var connectionStatus: String?
    private(set) var isCheckingConnection = false

    let store: HistoryStore
    let prompts: PromptStore

    init(store: HistoryStore) {
        self.store = store
        self.prompts = PromptStore(directory: HistoryStore.defaultDirectory())
        let settings = Settings.shared
        provider = settings.provider
        apiKey = settings.apiKey ?? ""
        model = settings.model
        fidelity = settings.fidelity
        trigger = settings.trigger
        hotkeyMode = settings.hotkeyMode
        secondaryTrigger = settings.secondaryTrigger
        secondaryStyle = settings.secondaryStyle
        microphoneUID = settings.microphoneUID
        interactionSounds = settings.interactionSounds
        launchAtLogin = LaunchAtLogin.isEnabled
        groundingEnabled = settings.groundingEnabled
        screenshotEnabled = settings.screenshotEnabled
        numberCheck = settings.numberCheck
        blockedBundleIDs = settings.blockedBundleIDs
        blockedURLPrefixes = settings.blockedURLPrefixes
        retention = settings.retention
        keepAudio = settings.keepAudio
        loadPrompt()
    }

    // MARK: - Prompt editing

    static func bundledPromptURL() -> URL? {
        Bundle.main.url(forResource: "PROMPT", withExtension: "md") ?? PromptBuilder.findPromptFile()
    }

    func loadPrompt() {
        guard let defaultURL = Self.bundledPromptURL() else {
            promptStatus = "Could not locate the bundled PROMPT.md."
            return
        }
        promptText = (try? prompts.activeTemplate(default: defaultURL)) ?? ""
        isPromptCustom = prompts.hasCustomPrompt
        promptStatus = nil
    }

    /// Validated before saving. A prompt that cannot build would surface as a mid-dictation
    /// failure rather than an error at the moment of editing.
    func savePrompt() {
        do {
            try prompts.save(promptText)
            isPromptCustom = true
            promptStatus = "Saved. The measured numbers in the changelog no longer apply to this "
                + "prompt — re-run `dnt-eval suite --prompt` to measure your own."
        } catch {
            promptStatus = error.localizedDescription
        }
    }

    func restoreDefaultPrompt() {
        do {
            try prompts.restoreDefault()
            loadPrompt()
            promptStatus = "Restored the shipped prompt."
        } catch {
            promptStatus = error.localizedDescription
        }
    }

    var resolvedKeySource: String {
        if !apiKey.isEmpty { return "Keychain" }
        if ProcessInfo.processInfo.environment[provider.apiKeyEnvVar] != nil {
            return "environment (\(provider.apiKeyEnvVar))"
        }
        return "not set"
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

    func checkConnection() async {
        isCheckingConnection = true
        connectionStatus = nil
        defer { isCheckingConnection = false }

        guard let key = Settings.shared.resolvedAPIKey(), !key.isEmpty else {
            connectionStatus = "No API key set."
            return
        }
        do {
            let provider = try ProviderFactory.make(
                self.provider, environment: [self.provider.apiKeyEnvVar: key])
            _ = try await provider.transcribe(
                TranscriptionRequest(
                    model: model,
                    systemInstruction: "You are a transcription engine.",
                    parts: [.text("Pretend the audio said: ok. Transcribe it.")]))
            connectionStatus = "✓ \(self.provider.rawValue) reachable, key accepted"
        } catch {
            connectionStatus = "✗ \(error.localizedDescription)"
        }
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
            let provider = try? ProviderFactory.make(
                provider, environment: [provider.apiKeyEnvVar: key]),
            let promptURL = Self.bundledPromptURL(),
            let instruction = try? prompts.builder(default: promptURL)
                .systemInstruction(fidelity: fidelity)
        else { return nil }

        return RetryCoordinator(
            service: TranscriptionService(
                provider: provider, model: model, systemInstruction: instruction),
            store: store)
    }
}
