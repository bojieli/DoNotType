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

    private(set) var records: [DictationRecord] = []
    private(set) var audioBytes: Int64 = 0
    private(set) var retryingIDs: Set<UUID> = []
    private(set) var lastRetrySummary: String?

    /// Live connection check, so "it isn't working" has an answer in the UI.
    private(set) var connectionStatus: String?
    private(set) var isCheckingConnection = false

    let store: HistoryStore

    init(store: HistoryStore) {
        self.store = store
        let settings = Settings.shared
        provider = settings.provider
        apiKey = settings.apiKey ?? ""
        model = settings.model
        fidelity = settings.fidelity
        trigger = settings.trigger
        hotkeyMode = settings.hotkeyMode
        groundingEnabled = settings.groundingEnabled
        screenshotEnabled = settings.screenshotEnabled
        blockedBundleIDs = settings.blockedBundleIDs
        blockedURLPrefixes = settings.blockedURLPrefixes
        retention = settings.retention
        keepAudio = settings.keepAudio
    }

    var resolvedKeySource: String {
        if !apiKey.isEmpty { return "Keychain" }
        if ProcessInfo.processInfo.environment[provider.apiKeyEnvVar] != nil {
            return "environment (\(provider.apiKeyEnvVar))"
        }
        return "not set"
    }

    var retryableCount: Int { records.count(where: \.canRetry) }

    // MARK: - Actions

    func refresh() async {
        await reconfigureStore()
        records = await store.all()
        audioBytes = await store.audioBytes()
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
            let promptURL = Bundle.main.url(forResource: "PROMPT", withExtension: "md")
                ?? PromptBuilder.findPromptFile(),
            let instruction = try? PromptBuilder(contentsOf: promptURL)
                .systemInstruction(fidelity: fidelity)
        else { return nil }

        return RetryCoordinator(
            service: TranscriptionService(
                provider: provider, model: model, systemInstruction: instruction),
            store: store)
    }
}
