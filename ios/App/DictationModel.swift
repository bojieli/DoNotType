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

    private var hasOpenedSettings = false

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
    /// The last second and a half of the microphone, oldest first.
    ///
    /// Always full, so the meter starts flat rather than growing in from the left: an empty meter
    /// and a silent one should not look different.
    private(set) var levels = DictationModel.silentMeter
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
        didSet {
            KeychainStore.write(apiKey, account: provider.rawValue)
            // Clearing the field has to clear the pre-rename entry as well, or `storedKey` would
            // read it back on the next launch.
            if apiKey.isEmpty, let renamed = provider.legacyPersistedValue {
                KeychainStore.write("", account: renamed)
            }
        }
    }
    var model: String {
        didSet { UserDefaults.standard.set(model, forKey: "model-\(provider.rawValue)") }
    }

    /// What a dictation produces: the transcript, or a rewrite of it.
    ///
    /// The desktop makes this choice with a second hotkey. A phone has no second key, so it is a
    /// picker above the button — the same rule, expressed with the only input the platform has:
    /// chosen before speaking, never from a menu afterwards.
    var liveStyle: RewriteStyle {
        didSet { UserDefaults.standard.set(liveStyle.rawValue, forKey: "liveStyle") }
    }

    /// Whether the rewrite stage can run at all, and what to say when it cannot.
    ///
    /// From the shared rule rather than asked here. The local version asked
    /// `!provider.isSpeechRecognition || secondStageBackend != nil` — a question about the *kind*
    /// of backend, which never checked that a key existed. It gave the right answer only while the
    /// default backend was a recogniser: the moment the default became a model, the first clause
    /// went true on a fresh install and the picker appeared on a phone that could not transcribe at
    /// all, let alone rewrite.
    var rewriteAvailability: RewriteAvailability {
        RewriteAvailability.resolve(provider: provider) { kind in
            !(KeychainStore.read(account: kind.rawValue) ?? "").isEmpty
        }
    }

    var canRewrite: Bool { rewriteAvailability.isAvailable }

    /// The first configured model backend, for the second stage a recogniser cannot run.
    var secondStageBackend: ProviderKind? {
        ProviderKind.allCases.first {
            $0.supportsTextGeneration && !(KeychainStore.read(account: $0.rawValue) ?? "").isEmpty
        }
    }

    /// A recogniser cannot rewrite, and on iOS it cannot be grounded either, so the only thing to
    /// say about one is what it is good at.
    var providerNote: String? {
        // The recommended two answer the question first: which of these should I pick. The
        // ungrounded wording is the one that is true here — see `ungroundedRecommendationNote`.
        if let recommendation = provider.ungroundedRecommendationNote { return recommendation }

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

    var fallbackChoices: [ProviderKind] { ProviderKind.pickerOrder.filter { $0 != provider } }

    var fallbackSummary: String? {
        guard let kind = fallbackProvider else { return nil }
        return "If \(provider.rawValue) has not answered in \(Int(fallbackAfterSeconds))s, "
            + "\(kind.rawValue) starts alongside it and whichever finishes first is used."
    }

    static func storedFallbackSeconds() -> Double {
        let stored = UserDefaults.standard.double(forKey: "fallbackAfterSeconds")
        return stored > 0 ? min(max(stored, 1), 120) : 8
    }

    /// The Keychain account is the provider's stored name, so a renamed backend has to look
    /// under the old one too or a key that still works reads as missing.
    static func storedKey(for provider: ProviderKind) -> String? {
        if let stored = KeychainStore.read(account: provider.rawValue), !stored.isEmpty {
            return stored
        }
        guard let renamed = provider.legacyPersistedValue else { return nil }
        return KeychainStore.read(account: renamed).flatMap { $0.isEmpty ? nil : $0 }
    }

    static func storedModel(for provider: ProviderKind) -> String {
        let defaults = UserDefaults.standard
        func stored(_ key: String) -> String? {
            defaults.string(forKey: key).flatMap { $0.isEmpty ? nil : $0 }
        }
        if let model = stored("model-\(provider.rawValue)") { return model }
        // The same key under the backend's pre-rename name, so a rename is not a factory reset.
        if let renamed = provider.legacyPersistedValue, let model = stored("model-\(renamed)") {
            return model
        }
        // The pre-provider-choice install stored one flat model, and it was Gemini's.
        if provider == .google, let model = stored("model") { return model }
        return provider.defaultModel
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

    /// Which part the editor is showing. One file at a time, for the same reason as on macOS: the
    /// contract is twelve separate instructions, and a single scrolling buffer is how the shipped
    /// text and the documentation about it ended up in the same box.
    var selectedPart: PromptPart = .system {
        didSet { if selectedPart != oldValue { loadPrompt() } }
    }

    /// The selected part's text. Editable, for the same reason as on macOS.
    var promptText: String = ""
    private(set) var promptStatus: String?
    private(set) var customParts: Set<PromptPart> = []

    /// Whether the *selected* part is the user's rather than the shipped one.
    var isPromptCustom: Bool { customParts.contains(selectedPart) }

    private let transcriptStore = TranscriptStore()
    private let prompts: PromptStore
    private let history: HistoryStore
    private let recorder = StreamingAudioRecorder()
    private var levelTimer: Timer?
    private var recordingURL: URL?
    private var livePipeline: LiveAudioPipeline?

    init() {
        let defaults = UserDefaults.standard
        let kind = ProviderKind(persistedValue: defaults.string(forKey: "provider") ?? "")
            ?? .defaultForNewInstalls
        provider = kind
        apiKey = Self.storedKey(for: kind) ?? ""
        model = Self.storedModel(for: kind)
        let fallbackRaw = defaults.string(forKey: "fallbackProvider") ?? ""
        let fallbackKind = ProviderKind(persistedValue: fallbackRaw)
            .flatMap { $0 == kind ? nil : $0 }
        fallbackProvider = fallbackKind
        fallbackAPIKey = fallbackKind.map { Self.storedKey(for: $0) ?? "" } ?? ""
        fallbackAfterSeconds = Self.storedFallbackSeconds()
        fidelity = Fidelity(rawValue: defaults.string(forKey: "fidelity") ?? "") ?? .default
        liveStyle = RewriteStyle(rawValue: defaults.string(forKey: "liveStyle") ?? "") ?? .verbatim
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
            let backend = try? ProviderFactory.make(provider, apiKey: apiKey)
        else { return nil }

        let builder = prompts.builder(bundled: promptURL)
        guard let instruction = try? builder.systemInstruction(fidelity: fidelity)
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
        Bundle.main.url(forResource: "prompt", withExtension: nil)
    }

    func loadPrompt() {
        guard let bundled = Self.bundledPromptURL else {
            promptStatus = "The prompt/ directory is missing from the app bundle."
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

    func savePrompt() {
        do {
            try prompts.save(promptText, for: selectedPart)
            customParts.insert(selectedPart)
            promptStatus = "Saved \(selectedPart.relativePath). The published measurements "
                + "describe the shipped part and no longer apply to this one."
        } catch {
            promptStatus = error.localizedDescription
        }
    }

    /// Restores the selected part only. The others keep whatever they are, which is the point of
    /// per-part overrides: editing one clause should not pin the whole contract.
    func restoreDefaultPrompt() {
        try? prompts.restore(selectedPart)
        loadPrompt()
        promptStatus = "Restored the shipped \(selectedPart.relativePath)."
    }

    func restoreAllPrompts() {
        try? prompts.restoreAll()
        loadPrompt()
        promptStatus = "Restored every part to the shipped contract."
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
    /// The desktop hotkey's own constant rather than a copy of its value, so the gesture means the
    /// same thing everywhere by construction. The comment here used to claim that match while
    /// holding a different number, which is how it survived the desktop side changing.
    private static let holdThreshold = PressGesture.holdThreshold
    private var pressStartedAt: Date?

    /// Touch-down. Recording starts immediately rather than waiting to classify the gesture --
    /// waiting would clip the first word, which is the one people say fastest.
    /// - Parameter time: the touch's own timestamp. Defaulted for the VoiceOver action, which has
    ///   no event behind it and toggles by calling this and `pressEnded` back to back.
    func pressBegan(at time: Date = Date()) {
        guard pressStartedAt == nil else { return }  // DragGesture.onChanged repeats
        pressStartedAt = time

        switch state {
        case .recording: finishRecording()  // second tap ends it
        case .idle, .failed: Task { await beginRecording() }
        case .transcribing: break
        }
    }

    /// Touch-up. A hold ends here; a tap leaves recording running until the next tap.
    func pressEnded(at time: Date = Date()) {
        defer { pressStartedAt = nil }
        guard let startedAt = pressStartedAt else { return }
        // Both ends come from the gesture's own timestamps, so work done on the main actor between
        // touch-down and touch-up cannot inflate a tap into a hold and end the recording early.
        guard time.timeIntervalSince(startedAt) >= Self.holdThreshold else { return }
        if state == .recording { finishRecording() }
    }

    private func beginRecording() async {
        guard await requestMicrophone() else {
            // Taking somebody to the setting rather than describing where it is. On iOS the app's
            // own page is one tap from here and several taps from the home screen, and a person
            // who has just tried to dictate is at the exact moment when they want to fix it.
            log.error(
                "cannot record: the microphone permission is not granted",
                ["permission": "microphone"])
            state = .failed("Microphone access is off. Opening Settings…")
            openAppSettings()
            return
        }

        // The connection, opened while the user is still speaking. It costs about a second and
        // whether the pooled one is still alive cannot be known without using it, so both happen
        // here rather than after they stop with somebody watching. On a phone this matters more
        // than anywhere: the screen goes off between dictations and the connection rots. Silent on
        // failure by design — nothing has been asked for yet. See `ProviderTransport`.
        if !apiKey.isEmpty,
            let backend = try? ProviderFactory.make(provider, apiKey: apiKey),
            let origin = backend.endpointOrigin
        {
            Task { await ProviderTransport.shared.warmUp(origin) }
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
            if let coordinator = makeCoordinator() {
                let session = LiveTranscriptionSession(
                    transcriber: makeTranscriber(primary: coordinator.service), context: nil)
                let pipeline = LiveAudioPipeline(session: session)
                livePipeline = pipeline
                recorder.onPCM = { [weak pipeline] pcm in pipeline?.append(pcm: pcm) }
            } else {
                livePipeline = nil
                recorder.onPCM = nil
            }
            try recorder.start(url: url)
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
            recorder.cancel()
            livePipeline?.cancel()
            livePipeline = nil
            recorder.onPCM = nil
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
        let stoppedURL = recorder.stop()
        recorder.onPCM = nil
        levels = Self.silentMeter

        guard let url = stoppedURL ?? recordingURL else {
            log.info("recording produced no file", ["dictation": Self.short(pendingID)])
            state = .idle
            return
        }
        recordingURL = nil

        guard stoppedURL != nil else {
            livePipeline?.cancel()
            livePipeline = nil
            state = .idle
            return
        }

        // Nothing without speech in it is ever sent. A model handed room tone does not reliably
        // return silence — it returns a plausible sentence, and a dictation tool that hands that
        // to somebody as their words has done the one thing this project exists to prevent.
        // system.md rule 7 asks for an empty transcript, but it only reaches model providers: a
        // speech recogniser has no system instruction, so for Deepgram, xAI and Voxtral the rule
        // is never sent at all. Not transmitting the audio is the only defence for every backend.
        if let recorded = try? Data(contentsOf: url) {
            let activity = SpeechActivity.measure(wav: recorded)
            guard livePipeline != nil || activity.hasSpeech else {
                log.info(
                    "nothing was said, so nothing was sent",
                    ["dictation": Self.short(pendingID), "audio": activity.summary])
                try? FileManager.default.removeItem(at: url)
                state = .idle
                return
            }
        }

        log.info(
            "recording finished",
            [
                "dictation": Self.short(pendingID),
                "bytes": "\((try? Data(contentsOf: url))?.count ?? 0)",
            ])
        state = .transcribing
        let pipeline = livePipeline
        livePipeline = nil
        Task { await transcribe(url: url, livePipeline: pipeline) }
    }

    /// How much of the recording the meter shows: 24 bars of 60 ms, so a second and a half.
    static let visibleBars = 24

    /// A recording that has just started, or one hearing nothing: flat, and still scrolling.
    static var silentMeter: [AudioLevelMeter.Bar] {
        [AudioLevelMeter.Bar](repeating: .silent, count: visibleBars)
    }

    private func startMetering() {
        levels = Self.silentMeter
        levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.levels = Array(
                    (self.levels + self.recorder.drainLevels()).suffix(Self.visibleBars))
            }
        }
    }

    /// Opens this app's page in Settings, where every permission it needs lives.
    ///
    /// Once per run: somebody who has decided not to grant it should not have Settings thrown at
    /// them on every tap, and the second time it opens it is no longer guidance.
    private func openAppSettings() {
        guard !hasOpenedSettings, let url = URL(string: UIApplication.openSettingsURLString) else {
            return
        }
        hasOpenedSettings = true
        UIApplication.shared.open(url)
    }

    /// The service that runs the second stage: the primary when it can take text, otherwise the
    /// first configured model backend — the recording still goes to the fast recogniser.
    private func makeRewriter() -> TranscriptionService? {
        if !provider.isSpeechRecognition { return makeCoordinator()?.service }
        guard let kind = secondStageBackend,
            let key = KeychainStore.read(account: kind.rawValue), !key.isEmpty,
            let backend = try? ProviderFactory.make(kind, apiKey: key)
        else { return nil }

        return TranscriptionService(
            provider: backend, model: Self.storedModel(for: kind),
            systemInstruction: "", fidelity: fidelity)
    }

    /// The rewrite block from the prompt in force — the user's edited copy when there is one.
    ///
    /// Read the same way `makeCoordinator` reads the system instruction: from the bundle, through
    /// `PromptStore`. There is no filesystem to walk up on a phone, and an app that used the
    /// shipped prompt here while sending an edited one for the transcript would make the two
    /// disagree about the only files that matter.
    private func rewriteInstruction(for style: RewriteStyle) -> String? {
        guard let promptURL = Self.bundledPromptURL else { return nil }
        return try? prompts.builder(bundled: promptURL).rewriteInstruction(style: style)
    }

    private func requestMicrophone() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
    }

    // MARK: - Transcription

    private func transcribe(url: URL, livePipeline: LiveAudioPipeline? = nil) async {
        defer { try? FileManager.default.removeItem(at: url) }

        // Read once, here. Moving the picker while a transcription is in flight must not change
        // what the recording already made becomes.
        let style = liveStyle

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
            let outcome = if let livePipeline {
                try await livePipeline.finish()
            } else {
                try await makeTranscriber(primary: coordinator.service)
                    .transcribe(audio: audio, context: nil)
            }
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

            // A rewrite is a second pass over a transcript that already exists, so the verbatim
            // version is stored either way and "what did I actually say" stays answerable.
            var delivered = text
            if style.isRewrite {
                let rewriteStart = Date()
                log.info(
                    "second stage",
                    [
                        "dictation": Self.short(pendingID), "style": style.rawValue,
                        "chars": "\(text.count)",
                    ])
                if let rewriter = makeRewriter(),
                    let instruction = rewriteInstruction(for: style)
                {
                    do {
                        let styled = try await rewriter.rewrite(text, instruction: instruction)
                        record.styledText = styled
                        record.style = style
                        delivered = styled
                        log.info(
                            "second stage finished",
                            [
                                "dictation": Self.short(pendingID),
                                "chars": "\(styled.count)", "from": "\(text.count)",
                                "ms": LogClock.ms(Date().timeIntervalSince(rewriteStart)),
                            ])
                    } catch {
                        // The words survive either way, so this is a warning rather than a
                        // failure — but it is said out loud, because a rewrite that fails every
                        // time should not be indistinguishable from one never asked for.
                        record.rewriteFailed = true
                        log.warning(
                            "second stage failed, delivering the verbatim transcript",
                            [
                                "dictation": Self.short(pendingID), "style": style.rawValue,
                                "detail": FailureAdvice.detail(of: error),
                            ])
                    }
                } else {
                    record.rewriteFailed = true
                    log.warning(
                        "no backend can rewrite text, delivering the verbatim transcript",
                        ["dictation": Self.short(pendingID), "style": style.rawValue])
                }
                record.rewriteSeconds = Date().timeIntervalSince(rewriteStart)
            }

            record.latencySeconds = Date().timeIntervalSince(releasedAt)
            await history.insert(record, audio: keepAudio ? try? Data(contentsOf: url) : nil)

            deliver(delivered)
            if record.rewriteFailed == true {
                state = .failed("Inserted — not rewritten.")
                await refresh()
                return
            }
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
            let instruction = try? prompts.builder(bundled: promptURL)
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
            let instruction = try? prompts.builder(bundled: promptURL)
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
