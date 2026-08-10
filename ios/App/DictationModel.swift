import AVFoundation
import DoNotTypeCore
import Foundation
import SwiftUI
import UIKit

/// Records, transcribes, and hands the result to the keyboard through the App Group.
///
/// There is no screen grounding on iOS. Nothing in the sandbox lets one app read another app's
/// content, and unlike macOS accessibility or Android's `AccessibilityService` there is no
/// user-grantable escape hatch. iOS gets verbatim transcription without the grounding half.
///
/// History and retry are shared with macOS — the same `HistoryStore` and `RetryCoordinator` from
/// `DoNotTypeCore`, so a dictation that fails on a train is still there when the signal returns.
@MainActor
@Observable
final class DictationModel {
    enum State: Equatable {
        case idle
        case recording
        case transcribing
        case failed(String)
    }

    private(set) var state: State = .idle
    /// Filters applied to the history list. In the core so the rules match the other platforms.
    var query = HistoryQuery() {
        didSet { if query != oldValue { applyQuery() } }
    }

    private(set) var allRecords: [DictationRecord] = []
    private(set) var records: [DictationRecord] = []
    private(set) var level: Double = 0
    private(set) var retryingIDs: Set<UUID> = []
    private(set) var audioBytes: Int64 = 0
    private(set) var connectionStatus: String?
    private(set) var isCheckingConnection = false

    var apiKey: String {
        didSet { KeychainStore.write(apiKey, account: "gemini") }
    }
    var model: String {
        didSet { UserDefaults.standard.set(model, forKey: "model") }
    }
    var fidelity: Fidelity {
        didSet { UserDefaults.standard.set(fidelity.rawValue, forKey: "fidelity") }
    }
    var retention: RetentionPolicy {
        didSet {
            UserDefaults.standard.set(retention.rawValue, forKey: "retention")
            Task { await refresh() }
        }
    }
    var keepAudio: Bool {
        didSet {
            UserDefaults.standard.set(keepAudio, forKey: "keepAudio")
            Task { await refresh() }
        }
    }

    /// The prompt in force. Editable, for the same reason as on macOS.
    var promptText: String = ""
    private(set) var promptStatus: String?
    private(set) var isPromptCustom = false

    private let transcriptStore = TranscriptStore()
    private let prompts: PromptStore
    private let history: HistoryStore
    private var recorder: AVAudioRecorder?
    private var levelTimer: Timer?
    private var recordingURL: URL?

    init() {
        let defaults = UserDefaults.standard
        apiKey = KeychainStore.read(account: "gemini") ?? ""
        model = defaults.string(forKey: "model") ?? ProviderKind.gemini.defaultModel
        fidelity = Fidelity(rawValue: defaults.string(forKey: "fidelity") ?? "") ?? .default
        retention = RetentionPolicy(rawValue: defaults.string(forKey: "retention") ?? "")
            ?? .forever
        keepAudio = defaults.bool(forKey: "keepAudio")

        // Inside the App Group so the keyboard could read it too if that ever becomes useful.
        let directory = TranscriptStore.containerURL
            ?? HistoryStore.defaultDirectory()
        history = HistoryStore(directory: directory.appendingPathComponent("History"))
        prompts = PromptStore(directory: directory.appendingPathComponent("Prompt"))
        loadPrompt()
    }

    // MARK: - Prompt editing

    private static var bundledPromptURL: URL? {
        Bundle.main.url(forResource: "PROMPT", withExtension: "md")
    }

    func loadPrompt() {
        guard let defaultURL = Self.bundledPromptURL else {
            promptStatus = "PROMPT.md is missing from the app bundle."
            return
        }
        promptText = (try? prompts.activeTemplate(default: defaultURL)) ?? ""
        isPromptCustom = prompts.hasCustomPrompt
        promptStatus = nil
    }

    func savePrompt() {
        do {
            try prompts.save(promptText)
            isPromptCustom = true
            promptStatus = "Saved. The published measurements describe the shipped prompt and no "
                + "longer apply to this one."
        } catch {
            promptStatus = error.localizedDescription
        }
    }

    func restoreDefaultPrompt() {
        try? prompts.restoreDefault()
        loadPrompt()
        promptStatus = "Restored the shipped prompt."
    }

    var hasAppGroup: Bool { TranscriptStore.containerURL != nil }
    /// Counted over everything, not the filtered view — a queue you cannot see is still a queue.
    var retryableCount: Int { allRecords.count(where: \.canRetry) }

    var keySource: String {
        apiKey.isEmpty ? "not set" : "Keychain"
    }

    func refresh() async {
        await history.configure(retention: retention, keepAudioForCompleted: keepAudio)
        allRecords = await history.all()
        audioBytes = await history.audioBytes()
        applyQuery()
    }

    private func applyQuery() {
        records = query.apply(to: allRecords)
    }

    /// Drains anything that failed while offline. Called when the app becomes active.
    func retryPending() async {
        guard retryableCount > 0, let coordinator = makeCoordinator() else { return }
        _ = await coordinator.retryAll()
        await refresh()
    }

    // MARK: - Recording

    func toggleRecording() {
        switch state {
        case .recording: finishRecording()
        case .idle, .failed: Task { await beginRecording() }
        case .transcribing: break
        }
    }

    private func beginRecording() async {
        guard await requestMicrophone() else {
            state = .failed("Microphone access is required. Enable it in Settings › DoNotType.")
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker])
            try session.setActive(true)

            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("dnt-\(UUID().uuidString).wav")
            recordingURL = url

            // 16 kHz mono: the model downsamples to it regardless, so anything richer is upload
            // paid for and discarded.
            let recorder = try AVAudioRecorder(
                url: url,
                settings: [
                    AVFormatIDKey: Int(kAudioFormatLinearPCM),
                    AVSampleRateKey: 16_000,
                    AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                ])
            recorder.isMeteringEnabled = true
            recorder.record()
            self.recorder = recorder
            state = .recording
            startMetering()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func finishRecording() {
        levelTimer?.invalidate()
        levelTimer = nil
        recorder?.stop()
        recorder = nil
        level = 0

        guard let url = recordingURL else {
            state = .idle
            return
        }
        recordingURL = nil
        state = .transcribing
        Task { await transcribe(url: url) }
    }

    private func startMetering() {
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let recorder = self.recorder else { return }
                recorder.updateMeters()
                // -50 dB is about the noise floor of a phone mic in a quiet room.
                let power = Double(recorder.averagePower(forChannel: 0))
                self.level = max(0, min(1, (power + 50) / 50))
            }
        }
    }

    private func requestMicrophone() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
    }

    // MARK: - Transcription

    private func transcribe(url: URL) async {
        defer { try? FileManager.default.removeItem(at: url) }

        guard let coordinator = makeCoordinator() else {
            state = .failed("Add your API key in Settings.")
            return
        }

        var record = DictationRecord(
            status: .pending, provider: ProviderKind.gemini.rawValue,
            model: model, fidelity: fidelity)

        do {
            let audio = try AudioFile(contentsOf: url)
            let result = try await coordinator.service.transcribeWithRetry(
                audio: audio, context: nil)
            let text = result.transcript.transcript
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard !text.isEmpty else {
                state = .idle
                return
            }

            record.status = .completed
            record.text = text
            await history.insert(record, audio: keepAudio ? try? Data(contentsOf: url) : nil)

            deliver(text)
            state = .idle
        } catch {
            // Audio is kept so this can be retried from History, or automatically next launch.
            record.status = .failed
            record.errorMessage = error.localizedDescription
            await history.insert(record, audio: try? Data(contentsOf: url))
            state = .failed(
                TranscriptionService.isTransient(error)
                    ? "\(error.localizedDescription) — saved, retry from History."
                    : error.localizedDescription)
        }
        await refresh()
    }

    /// Hands a finished transcript to the keyboard and the clipboard.
    private func deliver(_ text: String) {
        transcriptStore.append(text)
        // Also to the pasteboard, so it is usable in apps where the keyboard is not enabled.
        UIPasteboard.general.string = text
    }

    // MARK: - History actions

    func retry(_ record: DictationRecord) async {
        guard let coordinator = makeCoordinator() else {
            state = .failed("Add your API key in Settings.")
            return
        }
        retryingIDs.insert(record.id)
        defer { retryingIDs.remove(record.id) }

        if case .success(let text) = await coordinator.retry(record) {
            deliver(text)
        }
        await refresh()
    }

    func retryAll() async {
        guard let coordinator = makeCoordinator() else { return }
        let pending = await history.retryable()
        retryingIDs = Set(pending.map(\.id))
        defer { retryingIDs.removeAll() }

        _ = await coordinator.retryAll()
        await refresh()
    }

    func delete(_ record: DictationRecord) async {
        await history.delete(id: record.id)
        await refresh()
    }

    func clearHistory() async {
        await history.deleteAll()
        transcriptStore.clear()
        await refresh()
    }

    func checkConnection() async {
        isCheckingConnection = true
        connectionStatus = nil
        defer { isCheckingConnection = false }

        guard !apiKey.isEmpty else {
            connectionStatus = "No API key set."
            return
        }
        do {
            _ = try await GeminiProvider(apiKey: apiKey).transcribe(
                TranscriptionRequest(
                    model: model,
                    systemInstruction: "You are a transcription engine.",
                    parts: [.text("Pretend the audio said: ok. Transcribe it.")]))
            connectionStatus = "✓ Reachable, key accepted"
        } catch {
            connectionStatus = "✗ \(error.localizedDescription)"
        }
    }

    private func makeCoordinator() -> RetryCoordinator? {
        guard !apiKey.isEmpty,
            let promptURL = Self.bundledPromptURL,
            let instruction = try? prompts.builder(default: promptURL)
                .systemInstruction(fidelity: fidelity)
        else { return nil }

        return RetryCoordinator(
            service: TranscriptionService(
                provider: GeminiProvider(apiKey: apiKey), model: model,
                systemInstruction: instruction),
            store: history)
    }
}

/// Keychain wrapper. The key never goes in `UserDefaults` — this is a bring-your-own-key app, so
/// the key is the whole privacy story.
enum KeychainStore {
    private static let service = "ai.19pine.donottype"

    static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String, account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        SecItemAdd(base.merging([kSecValueData as String: Data(value.utf8)]) { _, new in new }
            as CFDictionary, nil)
    }
}
