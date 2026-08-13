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

    var keytermBiasing: Bool {
        didSet { Settings.shared.keytermBiasing = keytermBiasing }
    }

    /// What the selected backend can do with the screen, for the UI to state plainly instead of
    /// leaving grounding controls that quietly do nothing.
    var grounding: GroundingSupport {
        guard let provider = try? ProviderFactory.make(
            self.provider, environment: [self.provider.apiKeyEnvVar: "placeholder"])
        else { return .multimodal }
        return provider.grounding(forModel: model)
    }

    /// One line under the provider picker explaining what selecting it gives up.
    var groundingSummary: String? {
        guard provider.isSpeechRecognition else { return nil }

        let shared = "Transcription only — this service cannot read your screen, and rewriting is "
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
        keytermBiasing = settings.keytermBiasing
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

    /// A short-lived confirmation, so a button that silently succeeds still says so.
    var transientNote: String?

    func note(_ message: String) {
        transientNote = message
        Task {
            try? await Task.sleep(for: .seconds(2))
            if transientNote == message { transientNote = nil }
        }
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

            // A recognition backend rejects a text-only request by design, so probing one with
            // the text round trip would report a working key as broken. It gets a fraction of a
            // second of silence instead — enough to exercise auth, the URL and the response
            // shape, which is all this button claims to check.
            let parts: [InputPart] =
                provider.grounding(forModel: model) == .multimodal
                ? [.text("Pretend the audio said: ok. Transcribe it.")]
                : [.audio(data: Self.silentProbeWAV, mimeType: "audio/wav")]

            _ = try await provider.transcribe(
                TranscriptionRequest(
                    model: model,
                    systemInstruction: "You are a transcription engine.",
                    parts: parts))
            connectionStatus = "✓ \(self.provider.rawValue) reachable, key accepted"
        } catch ProviderError.emptyOutput {
            // Silence transcribes to nothing, which is the correct answer and proves the round
            // trip worked. Only the recognition path can reach this, since the text probe always
            // produces output.
            connectionStatus = "✓ \(self.provider.rawValue) reachable, key accepted"
        } catch {
            connectionStatus = "✗ \(error.localizedDescription)"
        }
    }

    /// A quarter-second of 16 kHz mono silence, built rather than shipped as a fixture so the
    /// bundle does not carry a resource used by one button.
    private static let silentProbeWAV: Data = {
        let sampleRate = 16_000
        let samples = sampleRate / 4
        let dataBytes = samples * 2

        var wav = Data()
        func append(_ string: String) { wav.append(Data(string.utf8)) }
        func append(u32 value: UInt32) { withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) } }
        func append(u16 value: UInt16) { withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) } }

        append("RIFF")
        append(u32: UInt32(36 + dataBytes))
        append("WAVEfmt ")
        append(u32: 16)                                  // PCM header length
        append(u16: 1)                                   // PCM
        append(u16: 1)                                   // mono
        append(u32: UInt32(sampleRate))
        append(u32: UInt32(sampleRate * 2))              // byte rate
        append(u16: 2)                                   // block align
        append(u16: 16)                                  // bits per sample
        append("data")
        append(u32: UInt32(dataBytes))
        wav.append(Data(repeating: 0, count: dataBytes))
        return wav
    }()

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
                provider: provider, model: model, systemInstruction: instruction,
                fidelity: fidelity, keytermBiasing: keytermBiasing),
            store: store)
    }
}
