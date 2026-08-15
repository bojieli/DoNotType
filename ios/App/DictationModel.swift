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
    /// Everything a dictation does, under one category so a log filter finds all of it.
    private let log = Log("dictate")

    /// The in-flight dictation's id, from the tap to the transcript.
    private var pendingID = UUID()

    /// Eight characters is enough to pick one dictation out of a day's log and short enough to sit
    /// in every line without pushing the interesting fields off the end.
    static func short(_ id: UUID) -> String { String(id.uuidString.prefix(8)) }

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

    /// The backend, chosen per install.
    ///
    /// Recognition services are a better trade here than anywhere else in this project. A keyboard
    /// extension cannot read the screen, so iOS has no grounding to give up — the thing that makes
    /// Deepgram and Voxtral a compromise on macOS costs nothing on iOS, and what is left is that
    /// they are several times faster and cheaper. See `ios/README.md`.
    var provider: ProviderKind {
        didSet {
            UserDefaults.standard.set(provider.rawValue, forKey: "provider")
            // Keys and models are stored per provider, so switching reloads rather than carrying
            // one backend's settings into another's fields.
            apiKey = KeychainStore.read(account: provider.rawValue) ?? ""
            model = Self.storedModel(for: provider)
        }
    }

    var apiKey: String {
        didSet { KeychainStore.write(apiKey, account: provider.rawValue) }
    }
    var model: String {
        didSet { UserDefaults.standard.set(model, forKey: "model-\(provider.rawValue)") }
    }

    /// A recogniser cannot rewrite, and on iOS it cannot be grounded either, so the only thing to
    /// say about one is what it is good at.
    var providerNote: String? {
        // The gateway forwards audio correctly; it is a measured quality difference, not a
        // capability one, and the picker is where two identical-looking entries are chosen between.
        if provider == .openrouter {
            return "Routes through a gateway. The same Gemini model measures worse this way than "
                + "through Gemini directly — 2 to 5 regressions per suite run against 1 — so "
                + "prefer the Gemini service unless you need a model Google does not serve."
        }
        guard provider.isSpeechRecognition else { return nil }

        switch provider {
        case .mistral:
            return "Transcription only, and faster for it. Handles Mandarin and English together."
        case .deepgram:
            // Louder than a trade-off note: this one predicts lost dictations.
            return "⚠ Transcription only, and it cannot transcribe Chinese with autodetection — "
                + "it returned nothing for 44 of 68 Mandarin clips. Choose another service if you "
                + "dictate in Chinese."
        default:
            return "Transcription only, and faster for it. Screen grounding is unavailable on iOS "
                + "either way, so nothing is lost here."
        }
    }

    /// Backend started alongside the primary when it has not answered in time. Nil disables it.
    ///
    /// The same trade as on macOS, and it matters more here: a phone keyboard waiting sixty
    /// seconds is a keyboard someone stops using.
    var fallbackProvider: ProviderKind? {
        didSet {
            UserDefaults.standard.set(fallbackProvider?.rawValue ?? "", forKey: "fallbackProvider")
            fallbackAPIKey = fallbackProvider
                .map { KeychainStore.read(account: $0.rawValue) ?? "" } ?? ""
        }
    }

    /// The fallback's own key, stored under its own provider so choosing it here never disturbs
    /// the primary's credentials.
    var fallbackAPIKey: String = "" {
        didSet {
            guard let kind = fallbackProvider else { return }
            KeychainStore.write(fallbackAPIKey, account: kind.rawValue)
        }
    }

    var fallbackAfterSeconds: Double {
        didSet {
            UserDefaults.standard.set(
                min(max(fallbackAfterSeconds, 1), 120), forKey: "fallbackAfterSeconds")
        }
    }

    var fallbackChoices: [ProviderKind] { ProviderKind.allCases.filter { $0 != provider } }

    var fallbackSummary: String? {
        guard let kind = fallbackProvider else { return nil }
        return "If \(provider.rawValue) has not answered in \(Int(fallbackAfterSeconds))s, "
            + "\(kind.rawValue) starts alongside it and whichever finishes first is used."
    }

    static func storedFallbackSeconds() -> Double {
        let stored = UserDefaults.standard.double(forKey: "fallbackAfterSeconds")
        return stored > 0 ? min(max(stored, 1), 120) : 8
    }

    static func storedModel(for provider: ProviderKind) -> String {
        UserDefaults.standard.string(forKey: "model-\(provider.rawValue)")
            .flatMap { $0.isEmpty ? nil : $0 }
            // The pre-provider-choice install stored one flat model, and it was Gemini's.
            ?? (provider == .gemini
                ? UserDefaults.standard.string(forKey: "model") : nil)
            ?? provider.defaultModel
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
        let kind = ProviderKind(rawValue: defaults.string(forKey: "provider") ?? "")
            ?? .defaultForNewInstalls
        provider = kind
        apiKey = KeychainStore.read(account: kind.rawValue) ?? ""
        model = Self.storedModel(for: kind)
        let fallbackRaw = defaults.string(forKey: "fallbackProvider") ?? ""
        let fallbackKind = ProviderKind(rawValue: fallbackRaw).flatMap { $0 == kind ? nil : $0 }
        fallbackProvider = fallbackKind
        fallbackAPIKey = fallbackKind.map { KeychainStore.read(account: $0.rawValue) ?? "" } ?? ""
        fallbackAfterSeconds = Self.storedFallbackSeconds()
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

        // Before the first request, and before anything else can log. On a phone there is no
        // Console and no shell, so a log file in the shared container is the only evidence a bug
        // report can ever carry.
        AppLogging.start(directory: directory)
    }

    // MARK: - Files

    /// Builds the offline transcriber for the file screen, from the same settings a dictation uses.
    ///
    /// - Parameter secondStage: a model backend to run a rewrite or summary through, for when the
    ///   chosen service is a recogniser and has no text input at all.
    func makeFileTranscriber(secondStage: ProviderKind? = nil) -> FileTranscriber? {
        guard !apiKey.isEmpty,
            let promptURL = Self.bundledPromptURL,
            let builder = try? prompts.builder(default: promptURL),
            let instruction = try? builder.systemInstruction(fidelity: fidelity),
            let backend = try? ProviderFactory.make(provider, apiKey: apiKey)
        else { return nil }

        let service = TranscriptionService(
            provider: backend, model: model, systemInstruction: instruction, fidelity: fidelity)

        var helper: TranscriptionService?
        if let secondStage, let key = KeychainStore.read(account: secondStage.rawValue),
            !key.isEmpty, let backend = try? ProviderFactory.make(secondStage, apiKey: key)
        {
            helper = TranscriptionService(
                provider: backend, model: Self.storedModel(for: secondStage),
                systemInstruction: instruction, fidelity: fidelity)
        }

        return FileTranscriber(
            service: service, prompt: builder, fidelity: fidelity, secondStage: helper)
    }

    /// Files land in the same history as dictations, so searching does not depend on remembering
    /// how something was captured. The recording stays where the user put it.
    func store(_ outcome: FileTranscriber.Outcome) async {
        await history.insert(outcome.historyRecord(), audio: nil)
        await refresh()
    }

    /// Hands text to the keyboard and the clipboard, as a finished dictation is handed over.
    func deliverToKeyboard(_ text: String) { deliver(text) }

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

    /// How long a press must last before releasing it ends the recording.
    ///
    /// 350 ms: long enough that a deliberate tap never trips it, short enough that someone who
    /// meant to hold does not get a surprise toggle. Matches the desktop hotkey and the Android
    /// keyboard, so the gesture means the same thing everywhere.
    private static let holdThreshold: TimeInterval = 0.35
    private var pressStartedAt: Date?

    /// Touch-down. Recording starts immediately rather than waiting to classify the gesture --
    /// waiting would clip the first word, which is the one people say fastest.
    func pressBegan() {
        guard pressStartedAt == nil else { return }  // DragGesture.onChanged repeats
        pressStartedAt = Date()

        switch state {
        case .recording: finishRecording()  // second tap ends it
        case .idle, .failed: Task { await beginRecording() }
        case .transcribing: break
        }
    }

    /// Touch-up. A hold ends here; a tap leaves recording running until the next tap.
    func pressEnded() {
        defer { pressStartedAt = nil }
        guard let startedAt = pressStartedAt else { return }
        guard Date().timeIntervalSince(startedAt) >= Self.holdThreshold else { return }
        if state == .recording { finishRecording() }
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

            // One id from the tap to the transcript, on every line and on the history row. A phone
            // has nowhere to show a trace, so the log is the only place this can be reconstructed.
            pendingID = UUID()
            log.info(
                "recording started",
                [
                    "dictation": Self.short(pendingID),
                    "provider": provider.rawValue, "model": model,
                    "fidelity": fidelity.rawValue,
                ])
            startMetering()
        } catch {
            log.error(
                "could not start recording",
                [
                    "dictation": Self.short(pendingID),
                    "detail": FailureAdvice.detail(of: error),
                ])
            state = .failed(FailureAdvice.describe(error).message)
        }
    }

    private func finishRecording() {
        levelTimer?.invalidate()
        levelTimer = nil
        recorder?.stop()
        recorder = nil
        level = 0

        guard let url = recordingURL else {
            log.info("recording produced no file", ["dictation": Self.short(pendingID)])
            state = .idle
            return
        }
        recordingURL = nil
        log.info(
            "recording finished",
            [
                "dictation": Self.short(pendingID),
                "bytes": "\((try? Data(contentsOf: url))?.count ?? 0)",
            ])
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

        // From the end of speech, not from the request: everything in between is time the user
        // spends waiting, and a figure that skipped it would flatter the app.
        let releasedAt = Date()
        let audioDuration = (try? AudioFile(contentsOf: url))?.durationSeconds ?? 0
        var record = DictationRecord(
            id: pendingID,
            status: .pending, provider: provider.rawValue,
            model: model, fidelity: fidelity, durationSeconds: audioDuration)

        do {
            let audio = try AudioFile(contentsOf: url)
            let requestStart = Date()
            // Hedged when a fallback is configured; a transparent pass-through otherwise.
            let outcome = try await makeTranscriber(primary: coordinator.service)
                .transcribe(audio: audio, context: nil)
            let result = outcome.result
            // Recorded as the backend that answered, not the one that was asked.
            record.provider = outcome.attribution.provider
            record.model = outcome.attribution.model
            record.requestSeconds = Date().timeIntervalSince(requestStart)
            record.usage = result.usage
            record.chunkCount = result.chunkCount
            let text = result.transcript.transcript
                .trimmingCharacters(in: .whitespacesAndNewlines)

            log.info(
                "transcript received",
                [
                    "dictation": Self.short(pendingID), "chars": "\(text.count)",
                    "language": result.transcript.language,
                    "chunks": "\(result.chunkCount)",
                    "audioTokens": result.usage.audioTokens.map(String.init) ?? "unreported",
                    "model": outcome.attribution.model,
                    "ms": LogClock.ms(Date().timeIntervalSince(requestStart)),
                ])
            log.content("transcript", text, level: .trace)

            guard !text.isEmpty else {
                // Not an error, and the one outcome people report as one: the tap worked, the
                // request worked, and nothing was said.
                log.info("nothing was said", ["dictation": Self.short(pendingID)])
                state = .idle
                return
            }

            record.status = .completed
            record.text = text
            record.latencySeconds = Date().timeIntervalSince(releasedAt)
            await history.insert(record, audio: keepAudio ? try? Data(contentsOf: url) : nil)

            deliver(text)
            state = .idle
        } catch {
            let advice = FailureAdvice.describe(error)
            let detail = FailureAdvice.detail(of: error)

            // The whole thing, in the log, on one record. A phone is the hardest place to read a
            // failure on and the easiest place to lose one, so it goes somewhere durable first.
            log.error(
                "transcription failed",
                [
                    "advice": advice.message, "queued": advice.isQueued ? "yes" : "no",
                    "retryable": advice.isRetryable ? "yes" : "no",
                    "provider": provider.rawValue, "model": model, "detail": detail,
                ])

            // Audio is kept so this can be retried from History, or automatically next launch.
            record.status = .failed
            record.errorMessage = advice.message
            record.errorDetail = detail
            await history.insert(record, audio: try? Data(contentsOf: url))
            state = .failed(advice.message)
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
            let backend = try ProviderFactory.make(provider, apiKey: apiKey)
            // A recognition backend rejects a text-only request by design, so probing one with the
            // text round trip would report a working key as broken. It gets a fraction of a second
            // of silence instead — enough to exercise auth, the URL and the response shape.
            let parts: [InputPart] =
                backend.grounding(forModel: model) == .multimodal
                ? [.text("Pretend the audio said: ok. Transcribe it.")]
                : [.audio(data: Self.silentProbeWAV, mimeType: "audio/wav")]

            _ = try await backend.transcribe(
                TranscriptionRequest(
                    model: model,
                    systemInstruction: "You are a transcription engine.",
                    parts: parts))
            connectionStatus = "✓ Reachable, key accepted"
        } catch ProviderError.emptyOutput {
            // Silence transcribes to nothing, which is the correct answer and proves the round
            // trip worked. Only the recognition path can reach this.
            connectionStatus = "✓ Reachable, key accepted"
        } catch {
            connectionStatus = "✗ \(error.localizedDescription)"
        }
    }

    /// Wraps the primary with the configured fallback. Built per dictation, because the provider,
    /// its key and the delay are all live settings.
    private func makeTranscriber(primary: TranscriptionService) -> FallbackTranscriber {
        guard let kind = fallbackProvider,
            let key = KeychainStore.read(account: kind.rawValue), !key.isEmpty,
            let backend = try? ProviderFactory.make(kind, apiKey: key),
            let promptURL = Self.bundledPromptURL,
            let instruction = try? prompts.builder(default: promptURL)
                .systemInstruction(fidelity: fidelity)
        else { return FallbackTranscriber(primary: primary) }

        return FallbackTranscriber(
            primary: primary,
            secondary: TranscriptionService(
                provider: backend, model: Self.storedModel(for: kind),
                systemInstruction: instruction, fidelity: fidelity),
            hedgeAfter: .seconds(fallbackAfterSeconds))
    }

    private func makeCoordinator() -> RetryCoordinator? {
        guard !apiKey.isEmpty,
            let promptURL = Self.bundledPromptURL,
            let instruction = try? prompts.builder(default: promptURL)
                .systemInstruction(fidelity: fidelity)
        else { return nil }

        guard let backend = try? ProviderFactory.make(provider, apiKey: apiKey)
        else { return nil }

        return RetryCoordinator(
            service: TranscriptionService(
                provider: backend, model: model,
                systemInstruction: instruction, fidelity: fidelity),
            store: history)
    }

    /// A quarter-second of 16 kHz mono silence for the connection test, built rather than shipped
    /// as a resource used by one button.
    static let silentProbeWAV: Data = {
        let sampleRate = 16_000
        let dataBytes = sampleRate / 4 * 2
        var wav = Data()
        func text(_ value: String) { wav.append(Data(value.utf8)) }
        func u32(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) }
        }
        func u16(_ value: UInt16) {
            withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) }
        }

        text("RIFF"); u32(UInt32(36 + dataBytes)); text("WAVEfmt ")
        u32(16); u16(1); u16(1); u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        text("data"); u32(UInt32(dataBytes))
        wav.append(Data(repeating: 0, count: dataBytes))
        return wav
    }()
}

/// Keychain wrapper. The key never goes in `UserDefaults` — this is a bring-your-own-key app, so
/// the key is the whole privacy story.
enum KeychainStore {
    private static let service = "app.donottype"

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
