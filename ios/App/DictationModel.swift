import AVFoundation
import DoNotTypeCore
import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

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
        /// The gesture completed normally, but there was nothing worth sending.
        case notice(String)
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
    /// The recording waiting for the user to say where to put it. Nil unless the picker is open.
    var audioExport: AudioExport?
    private(set) var audioBytes: Int64 = 0
    private(set) var connectionStatus: String?
    private(set) var isCheckingConnection = false
    private(set) var keyboardWasSeen = false
    private(set) var keyboardHasFullAccess: Bool?

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
            endpoint = Self.storedEndpoint(for: provider)
            publishSecondStageAvailability()
            correctUnrunnableMode()
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
            publishSecondStageAvailability()
            correctUnrunnableMode()
        }
    }
    var model: String {
        didSet {
            // Not stored while it could not be a model ID at all. This field saves as you type, so
            // without the guard a stray keystroke would replace a working configuration before
            // anybody could read the warning under the field. What was typed stays in the field;
            // only the store is protected. Matches the macOS panel — see `SettingsModel.model`.
            guard ModelIdentifier.isValid(model) else { return }
            UserDefaults.standard.set(model, forKey: "model-\(provider.rawValue)")
        }
    }

    /// Why the Model field cannot be stored, or nil while there is nothing wrong with it.
    var modelProblem: String? { ModelIdentifier.validationMessage(for: model) }
    var endpoint: String {
        didSet { UserDefaults.standard.set(endpoint, forKey: "endpoint-\(provider.rawValue)") }
    }

    /// What the next dictation produces. Both phones expose this as a three-way chip; what Rewrite
    /// and Translate each produce is configured separately in Settings.
    ///
    /// One setting rather than two that could disagree. It used to be a rewrite style doubling as a
    /// toggle, with a target language in Settings silently overriding it — so the chip could read
    /// Rewrite over a dictation that was going to come back translated.
    var liveMode: LiveMode {
        didSet {
            UserDefaults.standard.set(liveMode.rawValue, forKey: "liveMode")
            voiceKeyboardBridge.setLiveMode(liveMode)
        }
    }

    /// The style used whenever the chip is on Rewrite. Keeping it separate means selecting Dictate
    /// does not forget whether Rewrite was configured as Formal or Concise.
    var preferredRewriteStyle: RewriteStyle {
        didSet {
            guard preferredRewriteStyle.isRewrite else { return }
            UserDefaults.standard.set(preferredRewriteStyle.rawValue, forKey: "rewriteStyle")
        }
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
        availability(of: .rewrite)
    }

    var canRewrite: Bool { rewriteAvailability.isAvailable }

    /// Whether a given mode can run right now, and what to say when it cannot.
    func availability(of mode: LiveMode) -> RewriteAvailability {
        mode.availability(provider: provider, language: translateTo) { kind in
            !(KeychainStore.read(account: kind.rawValue) ?? "").isEmpty
        }
    }

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

    /// The audio-input caveat for the endpoint the primary backend is pointed at.
    ///
    /// The string itself lives in `ProviderKind` because macOS shows the same one. Unlike the
    /// recommendation above it, this claim needs no ungrounded variant: it is about whether the
    /// recording arrives at all, which is the same question on a phone as on a desktop.
    var endpointAudioNote: String? {
        provider.thirdPartyAudioNote(endpointOverride: endpoint)
    }

    /// The same caveat for the second backend, which has its own endpoint field.
    var fallbackEndpointAudioNote: String? {
        fallbackProvider?.thirdPartyAudioNote(endpointOverride: fallbackEndpoint)
    }

    /// Backend started alongside the primary when it has not answered in time. Nil disables it.
    ///
    /// The same trade as on macOS, and it matters more here: a phone keyboard waiting sixty
    /// seconds is a keyboard someone stops using.
    var fallbackProvider: ProviderKind? {
        didSet {
            UserDefaults.standard.set(fallbackProvider?.rawValue ?? "", forKey: "fallbackProvider")
            fallbackAPIKey = fallbackProvider
                .map { Self.storedKey(for: $0) ?? "" } ?? ""
            fallbackModel = fallbackProvider.map { Self.storedModel(for: $0) } ?? ""
            fallbackEndpoint = fallbackProvider.map { Self.storedEndpoint(for: $0) } ?? ""
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

    var fallbackModel: String = "" {
        didSet {
            // Guarded like the primary's, and for the same reason — see `model`.
            guard ModelIdentifier.isValid(fallbackModel) else { return }
            guard let kind = fallbackProvider, !fallbackModel.trimmed.isEmpty else { return }
            UserDefaults.standard.set(fallbackModel.trimmed, forKey: "model-\(kind.rawValue)")
        }
    }

    /// See `modelProblem` — the same check, for the second backend's model.
    var fallbackModelProblem: String? { ModelIdentifier.validationMessage(for: fallbackModel) }

    var fallbackEndpoint: String = "" {
        didSet {
            guard let kind = fallbackProvider else { return }
            UserDefaults.standard.set(fallbackEndpoint.trimmed, forKey: "endpoint-\(kind.rawValue)")
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

    static func storedEndpoint(for provider: ProviderKind) -> String {
        UserDefaults.standard.string(forKey: "endpoint-\(provider.rawValue)")?.trimmed ?? ""
    }
    var fidelity: Fidelity {
        didSet { UserDefaults.standard.set(fidelity.rawValue, forKey: "fidelity") }
    }
    /// What happens where Chinese meets Latin in a finished transcript. Deterministic — see
    /// `Typography`. The other three clients spell the stored values the same way.
    var typographySpacing: TypographySpacing {
        didSet {
            UserDefaults.standard.set(typographySpacing.rawValue, forKey: "typographySpacing")
        }
    }
    /// Which characters Chinese is written in. Asked of the model; see `ChineseScript`.
    var chineseScript: ChineseScript {
        didSet { UserDefaults.standard.set(chineseScript.rawValue, forKey: "chineseScript") }
    }
    /// The language dictations are written in, or empty for the one that was spoken.
    ///
    /// Empty by default, and that default is the product: this is the one setting that makes the
    /// Speak button deliver something other than what was said. What it does not change is the
    /// promise underneath — the verbatim transcript is still produced first and still stored.
    var translateTo: String {
        didSet {
            let cleaned = TranslationTarget.sanitized(translateTo)
            if cleaned != translateTo {
                translateTo = cleaned
                return
            }
            UserDefaults.standard.set(cleaned, forKey: "translateTo")
            voiceKeyboardBridge.setTranslationTarget(cleaned)
            correctUnrunnableMode()
        }
    }

    /// How the transcript should be written down — a description, or a sentence written the way
    /// the user wants theirs written. Empty sends nothing at all.
    ///
    /// Sanitised on the way in rather than on the way out, so what the settings screen shows is
    /// what a request would carry.
    var dictationExample: String {
        didSet {
            let cleaned = Typography.sanitizedSample(dictationExample)
            if cleaned != dictationExample {
                dictationExample = cleaned
                return
            }
            UserDefaults.standard.set(cleaned, forKey: "dictationExample")
        }
    }

    /// Turns a pre-example install's style setting into the text that setting was sending.
    ///
    /// Runs once, at launch, clearing the retired keys behind it so it cannot run twice and cannot
    /// resurrect a value the user has since edited. An example already set wins: overwriting a box
    /// somebody has typed into would be the one unforgivable outcome.
    private func migrateDictationExample() {
        let defaults = UserDefaults.standard
        let legacyStyle = defaults.string(forKey: "dictationStyle")
        let legacyCustom = defaults.string(forKey: "customDictationStyle")
        guard legacyStyle != nil || legacyCustom != nil else { return }
        defer {
            defaults.removeObject(forKey: "dictationStyle")
            defaults.removeObject(forKey: "customDictationStyle")
        }
        guard dictationExample.isEmpty else { return }
        let migrated = DictationExample.migrating(
            legacyStyle: legacyStyle, legacyCustom: legacyCustom, presetText: presetText)
        guard !migrated.isEmpty else { return }
        dictationExample = migrated
    }

    /// Drops a preset's text into the example box, where it can be read and edited before use.
    func applyPreset(_ preset: DictationPreset) {
        guard let text = presetText(preset) else { return }
        dictationExample = text
    }

    /// Resolves a preset's text for the button, the migration and the importer, or nil when the
    /// bundle is unreadable — in which case a legacy style migrates to an empty box, which sends
    /// nothing.
    func presetText(_ preset: DictationPreset) -> String? {
        Self.bundledPromptURL.flatMap {
            try? prompts.builder(bundled: $0).dictationPresetText(preset)
        }
    }

    /// The same, for the rewrite stage. Its own setting because the two are different jobs — this
    /// one may reword, and the dictation style may not.
    var customRewriteStyle: String {
        didSet {
            let cleaned = Typography.sanitizedSample(customRewriteStyle)
            if cleaned != customRewriteStyle {
                customRewriteStyle = cleaned
                return
            }
            UserDefaults.standard.set(cleaned, forKey: "customRewriteStyle")
        }
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

    private(set) var dictionaryTerms: [String] = []
    private(set) var learnedDictionaryTerms: [String] = []
    private(set) var dictionaryStatus: String?
    var learnDictionaryFromEdits: Bool = false {
        didSet {
            guard learnDictionaryFromEdits != oldValue else { return }
            if let snapshot = try? dictionaryStore.setLearning(learnDictionaryFromEdits) {
                applyDictionary(snapshot)
            }
        }
    }
    var personalDictionaryTerms: [String] {
        PersonalDictionary.sanitized(dictionaryTerms + learnedDictionaryTerms)
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
    private let dictionaryStore: DictionaryStore
    private let prompts: PromptStore
    private let history: HistoryStore
    private let recorder = StreamingAudioRecorder()
    private let voiceKeyboardBridge = VoiceKeyboardBridge()
    private var levelTimer: Timer?
    private var recordingURL: URL?
    private var livePipeline: LiveAudioPipeline?
    private var transcribingPipeline: LiveAudioPipeline?
    private var transcriptionTask: Task<Void, Never>?
    private var isStartingRecording = false
    private var currentDictationIsFromKeyboard = false
    private var keyboardSessionTimeoutTask: Task<Void, Never>?
    private static let keyboardSessionTimeout: TimeInterval = 5 * 60

    /// Shown only for a cold keyboard launch while recording starts and iOS restores the app whose
    /// text field still owns the keyboard.
    private(set) var isReturnToHostPresented = false

    init() {
        let defaults = UserDefaults.standard
        let kind = ProviderKind(persistedValue: defaults.string(forKey: "provider") ?? "")
            ?? .defaultForNewInstalls
        provider = kind
        apiKey = Self.storedKey(for: kind) ?? ""
        model = Self.storedModel(for: kind)
        endpoint = Self.storedEndpoint(for: kind)
        let fallbackRaw = defaults.string(forKey: "fallbackProvider") ?? ""
        let fallbackKind = ProviderKind(persistedValue: fallbackRaw)
            .flatMap { $0 == kind ? nil : $0 }
        fallbackProvider = fallbackKind
        fallbackAPIKey = fallbackKind.map { Self.storedKey(for: $0) ?? "" } ?? ""
        fallbackModel = fallbackKind.map { Self.storedModel(for: $0) } ?? ""
        fallbackEndpoint = fallbackKind.map { Self.storedEndpoint(for: $0) } ?? ""
        fallbackAfterSeconds = Self.storedFallbackSeconds()
        fidelity = Fidelity(rawValue: defaults.string(forKey: "fidelity") ?? "") ?? .default
        typographySpacing =
            TypographySpacing(rawValue: defaults.string(forKey: "typographySpacing") ?? "")
            ?? .default
        chineseScript =
            ChineseScript(rawValue: defaults.string(forKey: "chineseScript") ?? "") ?? .default
        dictationExample = defaults.string(forKey: "dictationExample") ?? ""
        customRewriteStyle = defaults.string(forKey: "customRewriteStyle") ?? ""
        translateTo = TranslationTarget.sanitized(defaults.string(forKey: "translateTo") ?? "")
        let storedLiveStyle =
            RewriteStyle(rawValue: defaults.string(forKey: "liveStyle") ?? "") ?? .verbatim
        if let stored = LiveMode(rawValue: defaults.string(forKey: "liveMode") ?? "") {
            liveMode = stored
        } else {
            // Migrated from the two-state switch, and from the target language that used to
            // override it — which is what an older build actually did with these two settings.
            let translating = !TranslationTarget.sanitized(
                defaults.string(forKey: "translateTo") ?? "").isEmpty
            liveMode = translating ? .translate : (storedLiveStyle.isRewrite ? .rewrite : .dictate)
        }
        let storedRewriteStyle =
            RewriteStyle(rawValue: defaults.string(forKey: "rewriteStyle") ?? "")
        if let storedRewriteStyle, storedRewriteStyle.isRewrite {
            preferredRewriteStyle = storedRewriteStyle
        } else {
            preferredRewriteStyle = storedLiveStyle.isRewrite ? storedLiveStyle : .casual
        }
        retention = RetentionPolicy(rawValue: defaults.string(forKey: "retention") ?? "")
            ?? .forever
        keepAudio = defaults.bool(forKey: "keepAudio")

        // Inside the App Group so the keyboard could read it too if that ever becomes useful.
        let directory = TranscriptStore.containerURL
            ?? HistoryStore.defaultDirectory()
        // A correctly signed install uses the App Group so the keyboard sees the same terms. The
        // fallback keeps the app usable if that entitlement is temporarily unavailable (including
        // unsigned simulator/UI-test builds), matching the history and prompt stores below.
        dictionaryStore = DictionaryStore(directory: directory)
        history = HistoryStore(directory: directory.appendingPathComponent("History"))
        prompts = PromptStore(directory: directory.appendingPathComponent("Prompt"))
        applyDictionary(dictionaryStore.load())
        loadPrompt()

        // After `prompts`, because resolving a preset's text needs it, and before the first
        // request can read the setting. An install that predates the example box still has the
        // retired style pair; the shared rule turns it into the text that pair was already
        // sending, so upgrading changes nothing about the request and everything about whether it
        // can be seen.
        migrateDictationExample()

        // Before the first request, and before anything else can log. On a phone there is no
        // Console and no shell, so a log file in the shared container is the only evidence a bug
        // report can ever carry.
        AppLogging.start(directory: directory)

        recorder.onHeartbeat = { [voiceKeyboardBridge] in
            voiceKeyboardBridge.touchSession()
        }
        VoiceKeyboardBridge.observeCommands { [weak self] command in
            Task { @MainActor in self?.handleKeyboardCommand(command) }
        }
        VoiceKeyboardBridge.observeUpdates { [weak self] in
            Task { @MainActor in
                self?.refreshKeyboardSetupStatus()
                self?.syncLiveModeFromKeyboard()
            }
        }
        refreshKeyboardSetupStatus()

        // If the keyboard already wrote a choice before cold-launching this process, its choice
        // wins; otherwise the app's stored mode is what the keyboard should be showing.
        if let chosen = voiceKeyboardBridge.liveMode {
            liveMode = chosen
        } else {
            voiceKeyboardBridge.setLiveMode(liveMode)
        }
        publishSecondStageAvailability()

        // A process restart destroys the recording and request tasks but leaves App Group state
        // intact. Do not strand the keyboard on a recording/transcribing screen that no task can
        // ever complete; `waiting` is deliberately preserved because that is the cold-launch
        // request this new process is about to handle.
        let inheritedKeyboardPhase = voiceKeyboardBridge.snapshot.phase
        if inheritedKeyboardPhase == .recording || inheritedKeyboardPhase == .transcribing {
            log.warning(
                "clearing an interrupted keyboard operation after process launch",
                ["phase": inheritedKeyboardPhase.rawValue])
            voiceKeyboardBridge.publishFailure("Dictation was interrupted — tap to try again.")
        }

        #if DEBUG
        // The simulator cannot feed silence into AVAudioEngine reliably. This launch-only seam
        // keeps the user-visible no-speech outcome under UI test without changing release builds.
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-ui-testing-no-api-key") {
            apiKey = ""
        } else if arguments.contains("-ui-testing-configured") {
            apiKey = "ui-test-key"
        }
        if arguments.contains("-ui-testing-no-speech-notice") {
            state = .notice("No speech detected — recording wasn’t sent")
        } else if arguments.contains("-ui-testing-recording-state") {
            // Drives the foreground-lifecycle contract without relying on a simulator microphone.
            state = .recording
        } else if arguments.contains("-ui-testing-transcribing-state") {
            state = .transcribing
        } else if arguments.contains("-ui-testing-keyboard-return-state") {
            state = .recording
            // Match the production cold-launch invariant. Scene activation can briefly report
            // inactive while the app is coming forward; without this marker the lifecycle handler
            // mistakes the keyboard-owned recording for an ordinary in-app recording and removes
            // the return instructions before they are visible.
            currentDictationIsFromKeyboard = true
            isReturnToHostPresented = true
        }
        #endif
    }

    // MARK: - Settings transfer

    func settingsTransferDocument() -> SettingsTransferDocument {
        let providers = Dictionary(uniqueKeysWithValues: ProviderKind.allCases.map { kind in
            let storedEndpoint = Self.storedEndpoint(for: kind)
            return (
                kind.rawValue,
                SettingsTransferDocument.Provider(
                    model: Self.storedModel(for: kind),
                    endpoint: storedEndpoint.isEmpty ? nil : storedEndpoint,
                    apiKey: Self.storedKey(for: kind))
            )
        })
        return SettingsTransferDocument(
            selectedProvider: provider.rawValue,
            providers: providers,
            fidelity: fidelity.rawValue,
            fallback: fallbackProvider.map {
                .init(provider: $0.rawValue, afterSeconds: fallbackAfterSeconds)
            },
            retention: retention.rawValue,
            keepAudio: keepAudio,
            dictionary: .init(
                manual: dictionaryTerms,
                learned: learnedDictionaryTerms,
                learnsFromEdits: learnDictionaryFromEdits),
            typography: .init(
                spacing: typographySpacing.rawValue,
                chineseScript: chineseScript.rawValue,
                dictationExample: dictationExample,
                // The retired pair too, so a profile made here still imports into a build that
                // predates the box: an example arrives there as `custom` with the same text.
                dictationStyle: dictationExample.isEmpty ? "spoken" : "custom",
                customDictationStyle: dictationExample,
                customRewriteStyle: customRewriteStyle,
                translateTo: translateTo),
            iOS: .init(liveStyle: (liveMode == .rewrite ? preferredRewriteStyle : .verbatim)
                .rawValue))
    }

    func importSettingsTransfer(_ document: SettingsTransferDocument) async throws {
        try document.validate()
        guard let selected = ProviderKind(persistedValue: document.selectedProvider) else {
            throw SettingsTransferApplyError.unsupportedValue(
                field: "selectedProvider", value: document.selectedProvider)
        }
        guard let importedFidelity = Fidelity(rawValue: document.fidelity) else {
            throw SettingsTransferApplyError.unsupportedValue(
                field: "fidelity", value: document.fidelity)
        }
        guard let importedRetention = RetentionPolicy(rawValue: document.retention) else {
            throw SettingsTransferApplyError.unsupportedValue(
                field: "retention", value: document.retention)
        }
        var importedTypography: ImportedTypography?
        if let typography = document.typography {
            guard let spacing = TypographySpacing(rawValue: typography.spacing) else {
                throw SettingsTransferApplyError.unsupportedValue(
                    field: "typography.spacing", value: typography.spacing)
            }
            guard let script = ChineseScript(rawValue: typography.chineseScript) else {
                throw SettingsTransferApplyError.unsupportedValue(
                    field: "typography.chineseScript", value: typography.chineseScript)
            }
            // Absent is "the profile predates styles", which keeps what this device has; present
            // and unreadable fails the whole import rather than being silently defaulted.
            // A profile written before the example box carries the retired pair instead, and is
            // migrated by the shared rule rather than rejected.
            let example: String
            if let stored = typography.dictationExample {
                example = Typography.sanitizedSample(stored)
            } else if typography.dictationStyle != nil || typography.customDictationStyle != nil {
                example = DictationExample.migrating(
                    legacyStyle: typography.dictationStyle,
                    legacyCustom: typography.customDictationStyle,
                    presetText: presetText)
            } else {
                example = dictationExample
            }
            importedTypography = ImportedTypography(
                spacing: spacing, script: script, example: example,
                customRewrite: typography.customRewriteStyle ?? customRewriteStyle,
                translateTo: typography.translateTo ?? "")
        }
        let importedFallback: ProviderKind? = try document.fallback.map { fallback in
            guard let kind = ProviderKind(persistedValue: fallback.provider) else {
                throw SettingsTransferApplyError.unsupportedValue(
                    field: "fallback.provider", value: fallback.provider)
            }
            return kind
        }
        let importedStyle: RewriteStyle? = try document.iOS.map { values in
            // "bullets" predates the rename to casual; see SettingsModel for the same alias.
            guard let style = RewriteStyle(rawValue: values.liveStyle)
                ?? (values.liveStyle == "bullets" ? .casual : nil)
            else {
                throw SettingsTransferApplyError.unsupportedValue(
                    field: "iOS.liveStyle", value: values.liveStyle)
            }
            return style
        }

        let defaults = UserDefaults.standard
        for (raw, imported) in document.providers {
            guard let kind = ProviderKind(persistedValue: raw) else { continue }
            defaults.set(
                imported.model.trimmed.isEmpty ? kind.defaultModel : imported.model.trimmed,
                forKey: "model-\(kind.rawValue)")
            defaults.set(imported.endpoint?.trimmed ?? "", forKey: "endpoint-\(kind.rawValue)")
            KeychainStore.write(imported.apiKey ?? "", account: kind.rawValue)
            if (imported.apiKey ?? "").isEmpty, let renamed = kind.legacyPersistedValue {
                KeychainStore.write("", account: renamed)
            }
        }
        defaults.set(selected.rawValue, forKey: "provider")
        defaults.set(importedFidelity.rawValue, forKey: "fidelity")
        defaults.set(importedFallback?.rawValue ?? "", forKey: "fallbackProvider")
        defaults.set(
            min(max(document.fallback?.afterSeconds ?? 8, 1), 120),
            forKey: "fallbackAfterSeconds")
        defaults.set(importedRetention.rawValue, forKey: "retention")
        defaults.set(document.keepAudio, forKey: "keepAudio")
        if let typography = importedTypography {
            defaults.set(typography.spacing.rawValue, forKey: "typographySpacing")
            defaults.set(typography.script.rawValue, forKey: "chineseScript")
            defaults.set(
                Typography.sanitizedSample(typography.example), forKey: "dictationExample")
            defaults.set(
                Typography.sanitizedSample(typography.customRewrite),
                forKey: "customRewriteStyle")
            defaults.set(
                TranslationTarget.sanitized(typography.translateTo), forKey: "translateTo")
        }
        if let importedStyle {
            defaults.set(importedStyle.rawValue, forKey: "liveStyle")
            if importedStyle.isRewrite {
                defaults.set(importedStyle.rawValue, forKey: "rewriteStyle")
            }
        }

        let snapshot = try dictionaryStore.replace(with: .init(
            manual: document.dictionary.manual,
            learned: document.dictionary.learned,
            learnsFromEdits: document.dictionary.learnsFromEdits))

        if let typography = importedTypography {
            typographySpacing = typography.spacing
            chineseScript = typography.script
            dictationExample = typography.example
            customRewriteStyle = typography.customRewrite
            translateTo = typography.translateTo
        }
        provider = selected
        apiKey = Self.storedKey(for: selected) ?? ""
        model = Self.storedModel(for: selected)
        endpoint = Self.storedEndpoint(for: selected)
        fallbackProvider = importedFallback
        fallbackAPIKey = importedFallback.map { Self.storedKey(for: $0) ?? "" } ?? ""
        fallbackModel = importedFallback.map { Self.storedModel(for: $0) } ?? ""
        fallbackEndpoint = importedFallback.map { Self.storedEndpoint(for: $0) } ?? ""
        fallbackAfterSeconds = Self.storedFallbackSeconds()
        fidelity = importedFidelity
        retention = importedRetention
        keepAudio = document.keepAudio
        if let importedStyle {
            if importedStyle.isRewrite { preferredRewriteStyle = importedStyle }
            // The document predates the mode picker and carries a style, not a mode. A target
            // language in the same document is what the exporting build would have done with it.
            liveMode = !translateTo.isEmpty
                ? .translate
                : (importedStyle.isRewrite ? .rewrite : .dictate)
        }
        applyDictionary(snapshot)
        await refresh()
    }

    // MARK: - Files

    /// Builds the offline transcriber for the file screen, from the same settings a dictation uses.
    ///
    /// - Parameter secondStage: a model backend to run a rewrite or summary through, for when the
    ///   chosen service is a recogniser and has no text input at all.
    func makeFileTranscriber(secondStage: ProviderKind? = nil) -> FileTranscriber? {
        guard hasAPIKey,
            let promptURL = Self.bundledPromptURL,
            let backend = try? ProviderFactory.make(
                provider, apiKey: apiKey, endpoint: endpoint)
        else { return nil }

        let builder = prompts.builder(bundled: promptURL)
        guard let instruction = try? builder.systemInstruction(
            fidelity: fidelity, script: chineseScript, dictationExample: dictationExample)
        else { return nil }

        let service = TranscriptionService(
            provider: backend, model: model, systemInstruction: instruction, fidelity: fidelity,
            personalDictionary: personalDictionaryTerms, typography: typographySpacing)

        var helper: TranscriptionService?
        if let secondStage, let key = KeychainStore.read(account: secondStage.rawValue),
            !key.isEmpty,
            let backend = try? ProviderFactory.make(
                secondStage, apiKey: key, endpoint: Self.storedEndpoint(for: secondStage))
        {
            helper = TranscriptionService(
                provider: backend, model: Self.storedModel(for: secondStage),
                systemInstruction: instruction, fidelity: fidelity,
                personalDictionary: personalDictionaryTerms, typography: typographySpacing)
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

    // MARK: - Personal dictionary

    func refreshDictionary() { applyDictionary(dictionaryStore.load()) }

    func refreshKeyboardSetupStatus() {
        let setup = voiceKeyboardBridge.keyboardSetupStatus
        keyboardWasSeen = setup.lastSeen != nil
        keyboardHasFullAccess = setup.hasFullAccess
    }

    func addDictionaryTerm(_ raw: String) {
        do {
            let snapshot = try dictionaryStore.add(raw)
            applyDictionary(snapshot)
            dictionaryStatus = "Added “(try PersonalDictionary.normalize(raw))”."
        } catch { dictionaryStatus = error.localizedDescription }
    }

    func replaceDictionaryTerm(_ original: String, with raw: String, learned: Bool) {
        do {
            applyDictionary(try dictionaryStore.replace(original, with: raw, learned: learned))
            dictionaryStatus = "Saved."
        } catch { dictionaryStatus = error.localizedDescription }
    }

    func deleteDictionaryTerm(_ term: String, learned: Bool) {
        do {
            applyDictionary(try dictionaryStore.remove(term, learned: learned))
            dictionaryStatus = "Removed “(term)”."
        } catch { dictionaryStatus = error.localizedDescription }
    }

    func importDictionary(from url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let (snapshot, count) = try dictionaryStore.importCSV(Data(contentsOf: url))
            applyDictionary(snapshot)
            dictionaryStatus = "Imported \(count) new "
                + (count == 1 ? "entry." : "entries.")
        } catch { dictionaryStatus = error.localizedDescription }
    }

    private func applyDictionary(_ snapshot: DictionaryStore.Snapshot) {
        dictionaryTerms = snapshot.manual
        learnedDictionaryTerms = snapshot.learned
        learnDictionaryFromEdits = snapshot.learnsFromEdits
    }

    var hasAppGroup: Bool { TranscriptStore.containerURL != nil }
    var hasAPIKey: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-ui-testing-no-api-key") { return false }
        #endif
        return !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    /// Counted over everything, not the filtered view — a queue you cannot see is still a queue.
    var retryableCount: Int { allRecords.count(where: \.canRetry) }

    var keySource: String {
        hasAPIKey ? "Keychain" : "not set"
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

    /// Handles `donottype://dictate`, after the keyboard has persisted a start request and opened
    /// the containing app. Persisting first matters: a Darwin notification cannot wake a process
    /// that does not exist yet, while this state survives the launch.
    func handleKeyboardLaunch() {
        let snapshot = voiceKeyboardBridge.snapshot
        guard snapshot.phase == .waiting,
            let updatedAt = snapshot.updatedAt,
            Date().timeIntervalSince(updatedAt) < 10
        else { return }

        // Mark ownership before creating the task. A cold launch can emit an inactive scene phase
        // between this synchronous URL handler and `beginRecording`; the lifecycle handler must
        // already know that the keyboard remains the recording's visible surface at that point.
        guard !isStartingRecording, state != .recording, state != .transcribing else { return }
        currentDictationIsFromKeyboard = true
        syncLiveModeFromKeyboard()
        isReturnToHostPresented = true
        Task { await beginRecording(fromKeyboard: true) }
    }

    func dismissReturnToHost() {
        isReturnToHostPresented = false
    }

    private func handleKeyboardCommand(_ command: VoiceKeyboardBridge.Command) {
        switch command {
        case .start:
            guard !isStartingRecording, state != .recording, state != .transcribing else { return }
            currentDictationIsFromKeyboard = true
            syncLiveModeFromKeyboard()
            Task { await beginRecording(fromKeyboard: true) }
        case .stop:
            if state == .recording, currentDictationIsFromKeyboard { finishRecording() }
        case .cancel:
            guard currentDictationIsFromKeyboard else { return }
            cancelCurrentOperationLocally()
        }
    }

    /// Cancels capture or the request that follows it. The keyboard writes its shared state to
    /// idle before posting the command; the app does the same when this action originates on its
    /// own screen so neither surface can remain stuck on "Transcribing…".
    func cancelCurrentOperation() {
        guard state == .recording || state == .transcribing else { return }
        if currentDictationIsFromKeyboard { voiceKeyboardBridge.requestCancel() }
        cancelCurrentOperationLocally()
    }

    func toggleRecording() {
        switch state {
        case .recording: finishRecording()
        case .idle, .notice, .failed: Task { await beginRecording(fromKeyboard: false) }
        case .transcribing: break
        }
    }

    /// Changes only the stage used by the next live dictation. What Rewrite and Translate each
    /// produce remains a Settings preference, shared with the keyboard through the bridge.
    ///
    /// A mode that cannot run is refused rather than stored: the chip would otherwise promise
    /// something the next dictation will not do.
    @discardableResult
    func setLiveMode(_ mode: LiveMode) -> String? {
        let availability = availability(of: mode)
        if let reason = availability.reason {
            // Said where the tap happened, in the sentence the other three clients use, rather
            // than leaving a control that does nothing when pressed.
            showNotice(reason)
            return reason
        }
        liveMode = mode
        return nil
    }

    private func syncLiveModeFromKeyboard() {
        guard let chosen = voiceKeyboardBridge.liveMode, chosen != liveMode else { return }
        liveMode = chosen
    }

    /// Drops back to Dictate when the chosen mode stopped being runnable — a cleared key, a
    /// backend that only transcribes, a target language emptied out. Leaving it selected would
    /// promise something the next dictation will not do.
    private func correctUnrunnableMode() {
        guard !availability(of: liveMode).isAvailable else { return }
        liveMode = .dictate
    }

    /// Tells the keyboard what it cannot work out for itself: the keys live in this app's Keychain.
    func publishSecondStageAvailability() {
        voiceKeyboardBridge.publishSecondStageBlocker(
            SecondStageBlocker(
                RewriteAvailability.resolve(provider: provider) { kind in
                    !(KeychainStore.read(account: kind.rawValue) ?? "").isEmpty
                }))
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
        case .idle, .notice, .failed: Task { await beginRecording(fromKeyboard: false) }
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

    private func beginRecording(fromKeyboard: Bool) async {
        guard !isStartingRecording, state != .recording, state != .transcribing else { return }
        isStartingRecording = true
        currentDictationIsFromKeyboard = fromKeyboard
        keyboardSessionTimeoutTask?.cancel()
        keyboardSessionTimeoutTask = nil
        defer { isStartingRecording = false }

        // Fail before asking for the microphone or capturing speech. A recording with nowhere to
        // send it is not useful, and discovering that only after speaking makes setup look broken.
        guard hasAPIKey else {
            failRecordingStart("Add an API key in Settings before dictating.")
            return
        }

        // A cold deep link reaches SwiftUI before the containing app necessarily becomes active.
        // Activating a record session during that transition fails with `!int`
        // (`cannotInterruptOthers`). A warm keyboard session already has live input and must not
        // be activated again while the app is in the background.
        if fromKeyboard, !recorder.isMonitoring,
            !(await waitForContainingAppToBecomeActive())
        {
            failRecordingStart(
                "DoNotType could not activate the microphone. Open the app and try again.")
            return
        }

        guard await requestMicrophone() else {
            // Taking somebody to the setting rather than describing where it is. On iOS the app's
            // own page is one tap from here and several taps from the home screen, and a person
            // who has just tried to dictate is at the exact moment when they want to fix it.
            log.error(
                "cannot record: the microphone permission is not granted",
                ["permission": "microphone"])
            failRecordingStart("Microphone access is off. Open DoNotType Settings to enable it.")
            openAppSettings()
            return
        }

        // The connection, opened while the user is still speaking. It costs about a second and
        // whether the pooled one is still alive cannot be known without using it, so both happen
        // here rather than after they stop with somebody watching. On a phone this matters more
        // than anywhere: the screen goes off between dictations and the connection rots. Silent on
        // failure by design — nothing has been asked for yet. See `ProviderTransport`.
        if hasAPIKey,
            let backend = try? ProviderFactory.make(
                provider, apiKey: apiKey, endpoint: endpoint),
            let origin = backend.endpointOrigin
        {
            Task { await ProviderTransport.shared.warmUp(origin) }
        }

        do {
            if !recorder.isMonitoring {
                let session = AVAudioSession.sharedInstance()
                // allowBluetoothHFP is the iOS 26 SDK's name for allowBluetooth; the CI image's
                // Xcode 16.4 SDK only has the old one. The compiler version tracks the SDK here.
                #if compiler(>=6.2)
                try session.setCategory(
                    .playAndRecord, mode: .measurement,
                    options: [.defaultToSpeaker, .mixWithOthers, .allowBluetoothHFP])
                #else
                try session.setCategory(
                    .playAndRecord, mode: .measurement,
                    options: [.defaultToSpeaker, .mixWithOthers, .allowBluetooth])
                #endif
                try session.setActive(true)
            }

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
            if fromKeyboard {
                voiceKeyboardBridge.touchSession()
                voiceKeyboardBridge.publishRecordingStarted()
                returnToKeyboardHostAfterColdLaunch()
            }

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
            deactivateAudioSession()
            voiceKeyboardBridge.endSession()
            livePipeline?.cancel()
            livePipeline = nil
            recorder.onPCM = nil
            log.error(
                "could not start recording",
                [
                    "dictation": Self.short(pendingID),
                    "detail": FailureAdvice.detail(of: error),
                ])
            failRecordingStart(recordingStartMessage(for: error))
        }
    }

    private func waitForContainingAppToBecomeActive() async -> Bool {
        for _ in 0..<50 {
            if UIApplication.shared.applicationState == .active { return true }
            if Task.isCancelled { return false }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return UIApplication.shared.applicationState == .active
    }

    /// A keyboard cannot request microphone access itself, so a cold press must briefly activate
    /// its containing app. Generic suspension does not restore the caller on current iOS—it can
    /// leave DoNotType in front or reveal the Home Screen. The extension therefore persists its
    /// host bundle identifier before launching us. Prefer a registered URL for known system apps,
    /// then use Launch Services' bundle-targeted handoff for other hosts. The bottom-edge gesture
    /// remains the fallback if iOS rejects both runtime paths.
    private func returnToKeyboardHostAfterColdLaunch() {
        guard isReturnToHostPresented else { return }
        let host = voiceKeyboardBridge.returnHostBundleIdentifier
        log.info(
            "returning to the keyboard host after microphone activation",
            ["host": host ?? "unavailable"])

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, self.state == .recording,
                self.currentDictationIsFromKeyboard
            else { return }

            if let host, await self.openKeyboardHost(bundleIdentifier: host) { return }
            self.log.warning(
                "targeted keyboard return failed; leaving the manual return fallback visible",
                ["host": host ?? "unavailable"])
        }
    }

    private func openKeyboardHost(bundleIdentifier: String) async -> Bool {
        // Notes is the first-party test target and publishes a URL scheme. Opening the root does
        // not create a note or mutate its content; it simply foregrounds the existing Notes scene.
        let knownURL: URL? = switch bundleIdentifier {
        case "com.apple.mobilenotes", "com.apple.Notes": URL(string: "mobilenotes://")
        default: nil
        }
        if let knownURL, await UIApplication.shared.open(knownURL) {
            log.info("returned through the host URL", ["host": bundleIdentifier])
            return true
        }

        guard let workspaceType = NSClassFromString("LSApplicationWorkspace") as? NSObject.Type,
            let workspace = workspaceType.perform(NSSelectorFromString("defaultWorkspace"))?
                .takeUnretainedValue() as? NSObject
        else {
            log.warning("Launch Services workspace is unavailable", ["host": bundleIdentifier])
            return false
        }
        let selector = NSSelectorFromString("openApplicationWithBundleID:")
        guard workspace.responds(to: selector) else {
            log.warning("Launch Services cannot open a bundle identifier", ["host": bundleIdentifier])
            return false
        }
        _ = workspace.perform(selector, with: bundleIdentifier)
        log.info("requested a bundle-targeted host return", ["host": bundleIdentifier])
        return true
    }

    private func recordingStartMessage(for error: Error) -> String {
        let underlying = error as NSError
        if underlying.domain == NSOSStatusErrorDomain,
            underlying.code == Int(AVAudioSession.ErrorCode.cannotInterruptOthers.rawValue)
        {
            return "iOS was still switching apps, so the microphone was not ready. Try again."
        }
        return FailureAdvice.describe(error).message
    }

    private func failRecordingStart(_ message: String) {
        state = .failed(message)
        if currentDictationIsFromKeyboard { voiceKeyboardBridge.publishFailure(message) }
        currentDictationIsFromKeyboard = false
        isReturnToHostPresented = false
        // A failed command may have arrived during an existing warm session (for example, after
        // the key was removed). Cancelling its old timer must not leave the microphone warm
        // indefinitely.
        armKeyboardSessionTimeout()
    }

    private func finishRecording() {
        levelTimer?.invalidate()
        levelTimer = nil
        let keepSessionWarm = currentDictationIsFromKeyboard
        let stoppedURL = recorder.stop(keepMonitoring: keepSessionWarm)
        if keepSessionWarm {
            voiceKeyboardBridge.touchSession()
        } else {
            deactivateAudioSession()
        }
        recorder.onPCM = nil
        levels = Self.silentMeter

        guard let url = stoppedURL ?? recordingURL else {
            log.info("recording produced no file", ["dictation": Self.short(pendingID)])
            finishKeyboardRequestWithFailure("Recording failed — no audio was captured.")
            return
        }
        recordingURL = nil

        guard stoppedURL != nil else {
            livePipeline?.cancel()
            livePipeline = nil
            log.info("recording too short to send", ["dictation": Self.short(pendingID)])
            finishKeyboardRequestWithNotice("Recording was too short — try again")
            return
        }

        // Nothing without speech in it is ever sent. A model handed room tone does not reliably
        // return silence — it returns a plausible sentence, and a dictation tool that hands that
        // to somebody as their words has done the one thing this project exists to prevent.
        // system.md rule 7 asks for an empty transcript, but it only reaches model providers: a
        // speech recogniser has no system instruction, so for Deepgram, xAI and Voxtral the rule
        // is never sent at all. Not transmitting the audio is the only defence for every backend.
        if let recorded = try? Data(contentsOf: url) {
            let activity: SpeechActivity.Reading
            do {
                activity = try SpeechActivity.measure(wav: recorded)
            } catch {
                livePipeline?.cancel()
                livePipeline = nil
                try? FileManager.default.removeItem(at: url)
                finishKeyboardRequestWithFailure(error.localizedDescription)
                return
            }
            guard livePipeline != nil || activity.hasSpeech else {
                log.info(
                    "nothing was said, so nothing was sent",
                    ["dictation": Self.short(pendingID), "audio": activity.summary])
                try? FileManager.default.removeItem(at: url)
                finishKeyboardRequestWithNotice("No speech detected — recording wasn’t sent")
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
        if currentDictationIsFromKeyboard { voiceKeyboardBridge.publishTranscribing() }
        let pipeline = livePipeline
        livePipeline = nil
        transcribingPipeline = pipeline
        transcriptionTask?.cancel()
        transcriptionTask = Task { @MainActor [weak self] in
            await self?.transcribe(url: url, livePipeline: pipeline)
        }
    }

    /// Stops ordinary in-app capture when its visible surface disappears. A dictation explicitly
    /// started by the keyboard is the exception: the keyboard is its visible recording surface,
    /// and the containing app owns the audio session precisely so it can continue in background.
    func stopRecordingForBackground() {
        // The keyboard is still the visible recording surface. Keep the cold-launch instructions
        // on screen until the user follows them; scene transitions while opening the app used to
        // erase this overlay and leave only the ordinary in-app “tap to stop” screen.
        guard !currentDictationIsFromKeyboard else { return }
        isReturnToHostPresented = false
        guard state == .recording else { return }
        log.info(
            "recording stopped because the app left the foreground",
            ["dictation": Self.short(pendingID)])
        levelTimer?.invalidate()
        levelTimer = nil
        recorder.cancel()
        recorder.onPCM = nil
        deactivateAudioSession()
        livePipeline?.cancel()
        livePipeline = nil
        recordingURL = nil
        pressStartedAt = nil
        levels = Self.silentMeter
        // Do not auto-dismiss this notice while the process is suspended. It should still explain
        // the stopped recording when the user returns, however long the app was in the background.
        state = .notice("Recording stopped when DoNotType left the foreground")
    }

    private func cancelCurrentOperationLocally() {
        let keepSessionWarm = currentDictationIsFromKeyboard
        // Read before anything is torn down. The two halves of a dictation lose different things,
        // and a notice saying "Cancelled" over a recording that was never sent tells the user
        // less than one that says what was thrown away.
        let wasRecording = state == .recording
        transcriptionTask?.cancel()
        transcriptionTask = nil
        transcribingPipeline?.cancel()
        transcribingPipeline = nil
        levelTimer?.invalidate()
        levelTimer = nil
        recorder.cancel(keepMonitoring: keepSessionWarm)
        recorder.onPCM = nil
        livePipeline?.cancel()
        livePipeline = nil
        recordingURL = nil
        pressStartedAt = nil
        levels = Self.silentMeter
        if !keepSessionWarm { deactivateAudioSession() }
        state = .notice(wasRecording ? "Recording discarded" : "Cancelled")
        currentDictationIsFromKeyboard = false
        isReturnToHostPresented = false
        log.info("dictation cancelled", ["dictation": Self.short(pendingID)])
        armKeyboardSessionTimeout()
    }

    private func finishKeyboardRequestWithFailure(_ message: String) {
        state = .failed(message)
        if currentDictationIsFromKeyboard { voiceKeyboardBridge.publishFailure(message) }
        currentDictationIsFromKeyboard = false
        isReturnToHostPresented = false
        armKeyboardSessionTimeout()
    }

    private func finishKeyboardRequestWithNotice(_ message: String) {
        if currentDictationIsFromKeyboard { voiceKeyboardBridge.publishFailure(message) }
        currentDictationIsFromKeyboard = false
        isReturnToHostPresented = false
        armKeyboardSessionTimeout()
        showNotice(message)
    }

    private func armKeyboardSessionTimeout() {
        keyboardSessionTimeoutTask?.cancel()
        guard recorder.isMonitoring else { return }
        keyboardSessionTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.keyboardSessionTimeout))
            guard let self, !Task.isCancelled,
                self.state != .recording, self.state != .transcribing
            else { return }
            self.recorder.stopMonitoring()
            self.deactivateAudioSession()
            self.voiceKeyboardBridge.endSession()
        }
    }

    /// Releases the route immediately so music, calls, and other audio regain their prior session.
    private func deactivateAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(
                false, options: .notifyOthersOnDeactivation)
        } catch {
            log.warning(
                "could not deactivate the audio session",
                ["detail": FailureAdvice.detail(of: error)])
        }
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
            let backend = try? ProviderFactory.make(
                kind, apiKey: key, endpoint: Self.storedEndpoint(for: kind))
        else { return nil }

        return TranscriptionService(
            provider: backend, model: Self.storedModel(for: kind),
            systemInstruction: "", fidelity: fidelity,
            personalDictionary: personalDictionaryTerms, typography: typographySpacing)
    }

    /// What this dictation's second stage is: whichever one the chip was showing.
    ///
    /// Exclusive by construction rather than by a settings flag overriding a toggle — two jobs in
    /// one request is the combination this project has already measured as worse.
    var liveStage: TranscriptMode {
        liveMode.stage(style: preferredRewriteStyle, language: translateTo)
    }

    /// The second-stage instruction for whichever stage this dictation asked for, routed through
    /// the one entry point so a translation cannot be sent through the rewrite block.
    private func secondStageInstruction(for mode: TranscriptMode) -> String? {
        guard let promptURL = Self.bundledPromptURL else { return nil }
        let instruction = try? prompts.builder(bundled: promptURL)
            .secondStageInstruction(for: mode, customStyle: customRewriteStyle)
        return (instruction ?? nil).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// What to ask the transcription request for beside the verbatim transcript.
    private func styledRequest(for mode: TranscriptMode) -> StyledRequest? {
        switch mode {
        case .verbatim, .summary: nil
        case .translate(let language): .translation(language: language)
        case .rewrite(let style):
            rewriteStyleClause(for: style).flatMap {
                $0.isEmpty ? nil : StyledRequest.style(clause: $0)
            }
        }
    }

    /// The rewrite block from the prompt in force — the user's edited copy when there is one.
    ///
    /// Read the same way `makeCoordinator` reads the system instruction: from the bundle, through
    /// `PromptStore`. There is no filesystem to walk up on a phone, and an app that used the
    /// shipped prompt here while sending an edited one for the transcript would make the two
    /// disagree about the only files that matter.
    private func rewriteInstruction(for style: RewriteStyle) -> String? {
        guard let promptURL = Self.bundledPromptURL else { return nil }
        return try? prompts.builder(bundled: promptURL)
            .rewriteInstruction(style: style, custom: customRewriteStyle)
    }

    /// The style rule alone, for folding a rewrite into the request that carries the audio.
    private func rewriteStyleClause(for style: RewriteStyle) -> String? {
        guard let promptURL = Self.bundledPromptURL else { return nil }
        return try? prompts.builder(bundled: promptURL)
            .styleClause(style, custom: customRewriteStyle)
    }

    private func requestMicrophone() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
    }

    // MARK: - Transcription

    private func transcribe(url: URL, livePipeline: LiveAudioPipeline? = nil) async {
        defer { try? FileManager.default.removeItem(at: url) }
        let dictationID = pendingID
        defer {
            if pendingID == dictationID {
                transcribingPipeline = nil
                transcriptionTask = nil
            }
        }
        let isKeyboardRequest = currentDictationIsFromKeyboard

        // Read once, here. Moving the picker while a transcription is in flight must not change
        // what the recording already made becomes.
        let style = liveMode == .rewrite ? preferredRewriteStyle : .verbatim
        let stage = liveStage

        guard let coordinator = makeCoordinator() else {
            finishKeyboardRequestWithFailure("Add your API key in Settings.")
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
            // Live segmentation is intentionally verbatim: a style belongs to the whole
            // utterance, not to each segment. The ordinary request can return both fields at once.
            let folded: StyledRequest? = livePipeline == nil ? styledRequest(for: stage) : nil
            // Hedged when a fallback is configured; a transparent pass-through otherwise.
            let outcome = if let livePipeline {
                try await livePipeline.finish()
            } else {
                try await makeTranscriber(primary: coordinator.service)
                    .transcribe(audio: audio, context: nil, styled: folded)
            }
            try Task.checkCancellation()
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
                // Live segmentation can produce no Silero-qualified chunks, and a backend can
                // also return an empty transcript. Both need a visible outcome; returning to idle
                // immediately makes a successful tap look ignored.
                log.info("nothing was said", ["dictation": Self.short(pendingID)])
                finishKeyboardRequestWithNotice("No speech was transcribed")
                return
            }

            record.status = .completed
            record.text = text

            // A model response may carry the rewrite beside the verbatim transcript. Recognition
            // backends and older responses fall through to the existing text-only stage.
            var delivered = text
            if stage.needsSecondPass, let styled = result.transcript.styled?.trimmed,
                !styled.isEmpty
            {
                record.styledText = styled
                record.style = stage.rewriteStyle
                record.mode = stage
                delivered = styled
                log.info(
                    "styled in one request",
                    [
                        "dictation": Self.short(pendingID), "mode": stage.rawValue,
                        "chars": "\(styled.count)", "from": "\(text.count)",
                    ])
            } else if stage.needsSecondPass {
                let rewriteStart = Date()
                log.info(
                    "second stage",
                    [
                        "dictation": Self.short(pendingID), "mode": stage.rawValue,
                        "chars": "\(text.count)",
                    ])
                if let rewriter = makeRewriter(),
                    let instruction = secondStageInstruction(for: stage)
                {
                    do {
                        let styled = try await rewriter.rewrite(text, instruction: instruction)
                        try Task.checkCancellation()
                        record.styledText = styled
                        record.style = stage.rewriteStyle
                        record.mode = stage
                        delivered = styled
                        log.info(
                            "second stage finished",
                            [
                                "dictation": Self.short(pendingID),
                                "chars": "\(styled.count)", "from": "\(text.count)",
                                "ms": LogClock.ms(Date().timeIntervalSince(rewriteStart)),
                            ])
                    } catch {
                        if error is CancellationError || Task.isCancelled {
                            throw CancellationError()
                        }
                        // The words survive either way, so this is a warning rather than a
                        // failure — but it is said out loud, because a rewrite that fails every
                        // time should not be indistinguishable from one never asked for.
                        record.rewriteFailed = true
                        log.warning(
                            "second stage failed, delivering the verbatim transcript",
                            [
                                "dictation": Self.short(pendingID), "mode": stage.rawValue,
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
            try Task.checkCancellation()
            await history.insert(record, audio: keepAudio ? try? Data(contentsOf: url) : nil)
            try Task.checkCancellation()

            deliver(delivered, toKeyboard: isKeyboardRequest)
            currentDictationIsFromKeyboard = false
            isReturnToHostPresented = false
            armKeyboardSessionTimeout()
            if record.rewriteFailed == true {
                state = .failed("Inserted — not rewritten.")
                await refresh()
                return
            }
            state = .idle
        } catch {
            if error is CancellationError || Task.isCancelled {
                log.info("transcription cancelled", ["dictation": Self.short(dictationID)])
                return
            }
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
            if isKeyboardRequest { voiceKeyboardBridge.publishFailure(advice.message) }
            currentDictationIsFromKeyboard = false
            isReturnToHostPresented = false
            armKeyboardSessionTimeout()
        }
        await refresh()
    }

    /// Hands a finished transcript to the keyboard and the clipboard.
    private func deliver(_ text: String, toKeyboard: Bool = false) {
        transcriptStore.append(text)
        if toKeyboard { voiceKeyboardBridge.publishResult(text) }
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

    /// Transcribes a stored recording again, for a dictation that arrived and arrived wrong.
    ///
    /// The same request Retry makes, and deliberately not the same ending: a retry is recovering
    /// words that never reached the keyboard, so it delivers them. Nothing is waiting on these —
    /// the user is reading their own history — and putting them on the clipboard would quietly
    /// replace whatever is there. The row updates; Copy is one button away.
    func redo(_ record: DictationRecord) async {
        guard let coordinator = makeCoordinator() else {
            state = .failed("Add your API key in Settings.")
            return
        }
        retryingIDs.insert(record.id)
        defer { retryingIDs.remove(record.id) }

        _ = await coordinator.retry(record)
        await refresh()
    }

    /// Loads a recording for the export sheet, which is what asks the user where it goes.
    ///
    /// Read here rather than handed to the sheet as a file URL: the store's copy lives in the app
    /// container under a UUID, and a share sheet offering `A1B2….wav` names the file after an
    /// implementation detail.
    func prepareAudioExport(_ record: DictationRecord) async {
        do {
            let audio = try await history.audioFile(for: record)
            audioExport = AudioExport(data: audio.data, name: record.audioExportName)
        } catch {
            state = .failed(error.localizedDescription)
        }
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

        guard hasAPIKey else {
            connectionStatus = "No API key set."
            return
        }
        do {
            let backend = try ProviderFactory.make(
                provider, apiKey: apiKey, endpoint: endpoint)
            // Audio, for every backend — the same shape a dictation sends. Model backends used to
            // get a text round trip, which a text-only relay or checkpoint answers perfectly well
            // before dropping the first real recording. See `ProviderProbe.check`, which this
            // mirrors.
            let parts: [InputPart] = [.audio(data: Self.silentProbeWAV, mimeType: "audio/wav")]

            _ = try await backend.transcribe(
                TranscriptionRequest(
                    model: model,
                    systemInstruction: "You are a transcription engine.",
                    parts: parts))
            connectionStatus = "✓ Reachable, key accepted"
        } catch ProviderError.emptyOutput {
            // Silence transcribes to nothing, which is the correct answer and proves the round
            // trip worked.
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
            let backend = try? ProviderFactory.make(
                kind, apiKey: key, endpoint: Self.storedEndpoint(for: kind)),
            let promptURL = Self.bundledPromptURL,
            let instruction = try? prompts.builder(bundled: promptURL)
                .systemInstruction(
                    fidelity: fidelity, script: chineseScript,
                    dictationExample: dictationExample)
        else { return FallbackTranscriber(primary: primary) }

        return FallbackTranscriber(
            primary: primary,
            secondary: TranscriptionService(
                provider: backend, model: Self.storedModel(for: kind),
                systemInstruction: instruction, fidelity: fidelity,
                personalDictionary: personalDictionaryTerms, typography: typographySpacing),
            hedgeAfter: .seconds(fallbackAfterSeconds))
    }

    private func makeCoordinator() -> RetryCoordinator? {
        guard hasAPIKey,
            let promptURL = Self.bundledPromptURL,
            let instruction = try? prompts.builder(bundled: promptURL)
                .systemInstruction(
                    fidelity: fidelity, script: chineseScript,
                    dictationExample: dictationExample)
        else { return nil }

        guard let backend = try? ProviderFactory.make(
            provider, apiKey: apiKey, endpoint: endpoint)
        else { return nil }

        return RetryCoordinator(
            service: TranscriptionService(
                provider: backend, model: model,
                systemInstruction: instruction, fidelity: fidelity,
                personalDictionary: personalDictionaryTerms, typography: typographySpacing),
            store: history)
    }

    /// Keeps a harmless outcome visible long enough to read while leaving the record button live.
    private func showNotice(_ message: String) {
        state = .notice(message)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, self.state == .notice(message) else { return }
            self.state = .idle
        }
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

/// A recording on its way out of the history, named for when it was said.
///
/// Write-only. The history is written by dictating, not by importing a file, so there is no
/// direction in which this document is ever read back.
struct AudioExport: FileDocument, Identifiable {
    static var readableContentTypes: [UTType] { [.wav] }

    let id = UUID()
    let data: Data
    let name: String

    init(data: Data, name: String) {
        self.data = data
        self.name = name
    }

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.fileReadUnsupportedScheme)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
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
