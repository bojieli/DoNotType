import AppKit
import DoNotTypeCore
import Foundation
import Observation
import UniformTypeIdentifiers

/// Drives the "Transcribe a Recording" window.
///
/// The window exists because the app could only ever transcribe speech it had just recorded, which
/// left every recording already on disk — a voice memo, a call, an interview — outside a tool built
/// exactly for turning speech into text. Everything it needs already existed in the core; what was
/// missing was a way in that did not involve holding a key down next to a speaker.
///
/// It shares `FileTranscriber` with `dnt transcribe`, so the two cannot drift on what a mode means
/// or on which backend runs the second stage.
@MainActor
@Observable
final class FileTranscriptionModel {
    enum Phase: Equatable {
        case idle
        case decoding
        case transcribing(done: Int, of: Int)
        case deriving(String)
        case finished
        case failed(String)

        var isRunning: Bool {
            switch self {
            case .decoding, .transcribing, .deriving: true
            case .idle, .finished, .failed: false
            }
        }
    }

    /// Which text the result pane is showing. Present whenever a mode derived something, because
    /// being able to check a summary against the words behind it is the point.
    enum Display: String, CaseIterable {
        case result
        case verbatim
    }

    private(set) var phase: Phase = .idle
    var files: [URL] = []
    var mode: TranscriptMode {
        didSet { Settings.shared.fileMode = mode }
    }
    var display: Display = .result

    private(set) var outcome: FileTranscriber.Outcome?
    private(set) var statusLine: String?
    private(set) var completedCount = 0

    private let store: HistoryStore
    private let log = Log("filewindow")
    private var task: Task<Void, Never>?

    init(store: HistoryStore) {
        self.store = store
        self.mode = Settings.shared.fileMode
    }

    var canStart: Bool { !files.isEmpty && !phase.isRunning }

    /// What the result pane should show right now.
    var visibleText: String {
        guard let outcome else { return "" }
        return display == .verbatim ? outcome.verbatim : outcome.delivered
    }

    var derivedSomething: Bool {
        guard let outcome else { return false }
        return outcome.mode != .verbatim && outcome.delivered != outcome.verbatim
    }

    /// Why the selected mode cannot run, in one sentence, or nil when it can.
    ///
    /// Shown before the button is pressed rather than as an error afterwards: with a recognition
    /// backend selected, "summarise this" is not slow, it is impossible, and finding that out after
    /// uploading forty minutes of audio would be an expensive way to learn it.
    var modeWarning: String? {
        guard mode.needsSecondPass else { return nil }
        let settings = Settings.shared
        guard settings.provider.isSpeechRecognition else { return nil }

        if let stage = TextStage.provider() {
            // Naming the model rather than only the backend: with xAI they are the same account
            // and different products, so "xai will do it" would not answer the question.
            let model = TextStage.model(for: stage)
            return "\(settings.provider.displayName) only transcribes, so the \(noun) will be "
                + "produced by \(model) in a second request."
        }
        return "\(settings.provider.displayName) is a speech recognition service and cannot "
            + "\(verb). Add a key for a model backend in Settings, or choose Verbatim."
    }

    private var noun: String {
        switch mode {
        case .summary: "summary"
        case .rewrite: "rewrite"
        case .translate: "translation"
        case .verbatim: "transcript"
        }
    }

    private var verb: String {
        switch mode {
        case .summary: "summarise"
        case .rewrite: "rewrite"
        case .translate: "translate"
        case .verbatim: "transcribe"
        }
    }

    // MARK: - Choosing files

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, .movie]
        panel.message = "Choose recordings to transcribe"
        guard panel.runModal() == .OK else { return }
        files = panel.urls
        outcome = nil
        phase = .idle
        statusLine = nil
    }

    /// Accepts a drop, keeping only what CoreAudio has a chance of opening.
    @discardableResult
    func accept(urls: [URL]) -> Bool {
        let audio = urls.filter {
            AudioDecoder.openableExtensions.contains($0.pathExtension.lowercased())
        }
        guard !audio.isEmpty else {
            statusLine = "Not audio this app can read. Try \(AudioDecoder.supportedFormats)."
            return false
        }
        files = audio
        outcome = nil
        phase = .idle
        statusLine = nil
        return true
    }

    // MARK: - Running

    func start() {
        guard canStart else { return }
        let targets = files
        let selectedMode = mode

        task?.cancel()
        outcome = nil
        completedCount = 0
        statusLine = nil
        phase = .decoding

        task = Task { [weak self] in
            guard let self else { return }
            await run(targets, mode: selectedMode)
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        phase = .idle
        statusLine = "Cancelled."
    }

    private func run(_ targets: [URL], mode selectedMode: TranscriptMode) async {
        guard let transcriber = makeTranscriber() else {
            phase = .failed("No API key. Open Settings to add one.")
            return
        }
        guard transcriber.supports(selectedMode) else {
            phase = .failed(
                "\(Settings.shared.provider.displayName) cannot \(verb) — it only transcribes "
                    + "audio. Add a key for a model backend, or choose Verbatim.")
            return
        }

        var failures: [String] = []
        for (index, url) in targets.enumerated() {
            guard !Task.isCancelled else { return }
            statusLine = targets.count > 1
                ? "\(url.lastPathComponent) (\(index + 1) of \(targets.count))" : url.lastPathComponent

            do {
                let produced = try await transcriber.transcribe(
                    fileAt: url, mode: selectedMode,
                    onProgress: { [weak self] progress in
                        Task { @MainActor in self?.apply(progress) }
                    })
                guard !Task.isCancelled else { return }

                outcome = produced
                display = .result
                completedCount += 1
                // Written to history like any other transcript, so it is searchable next to the
                // dictations. The audio stays where the user put it rather than being copied.
                await store.insert(produced.historyRecord(), audio: nil)
            } catch {
                log.error(
                    "file transcription failed",
                    ["file": url.lastPathComponent, "error": error.localizedDescription])
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        if let first = failures.first, completedCount == 0 {
            phase = .failed(first)
            return
        }
        phase = .finished
        statusLine = summaryLine(count: targets.count, failures: failures)
    }

    private func apply(_ progress: FileTranscriber.Progress) {
        switch progress {
        case .decoding: phase = .decoding
        case .transcribing(let done, let total): phase = .transcribing(done: done, of: total)
        // The mode's own word — "Summarising…", "Loosening…" — rather than its settings label.
        case .deriving(let mode): phase = .deriving(mode.progressLabel)
        }
    }

    private func summaryLine(count: Int, failures: [String]) -> String {
        var parts: [String] = []
        if count > 1 { parts.append("\(completedCount) of \(count) transcribed") }
        if let outcome {
            if let duration = outcome.durationSeconds, duration > 0 {
                parts.append(
                    "\(PerformanceStats.formatDuration(duration)) of audio in "
                        + PerformanceStats.formatDuration(outcome.totalSeconds))
            } else {
                parts.append("in \(PerformanceStats.formatDuration(outcome.totalSeconds))")
            }
            if outcome.chunkCount > 1 { parts.append("\(outcome.chunkCount) parts") }
            if let second = outcome.secondStageProvider { parts.append("\(second) wrote the result") }
        }
        // No silent failures: a batch where two of five failed must not read as a clean run.
        if !failures.isEmpty { parts.append("\(failures.count) failed — see the log") }
        return parts.joined(separator: " · ")
    }

    private func makeTranscriber() -> FileTranscriber? {
        let settings = Settings.shared
        guard let key = settings.resolvedAPIKey(), !key.isEmpty,
            let provider = try? settings.makeProvider(settings.provider, apiKey: key),
            let promptURL = SettingsModel.bundledPromptURL()
        else { return nil }

        let builder = PromptStore(directory: HistoryStore.defaultDirectory())
            .builder(bundled: promptURL)
        guard let instruction = try? builder.systemInstruction(
            fidelity: settings.fidelity, script: settings.chineseScript,
            dictationStyle: settings.dictationStyle,
            customDictationStyle: settings.customDictationStyle)
        else { return nil }

        let service = TranscriptionService(
            provider: provider, model: settings.model, systemInstruction: instruction,
            fidelity: settings.fidelity, keytermBiasing: settings.keytermBiasing,
            personalDictionary: settings.personalDictionaryTerms,
            typography: settings.typographySpacing)

        return FileTranscriber(
            service: service, prompt: builder, fidelity: settings.fidelity,
            secondStage: TextStage.service(instruction: instruction))
    }

    // MARK: - Results

    func copyResult() {
        guard !visibleText.isEmpty else { return }
        Diagnostics.copyToPasteboard(visibleText)
        statusLine = "Copied \(visibleText.count) characters."
    }

    /// Writes the result next to the recording, with the verbatim transcript beside it when the
    /// mode produced something different. Same rule as `dnt transcribe --output`.
    func save() {
        guard let outcome else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue =
            outcome.sourceURL.deletingPathExtension().lastPathComponent + ".txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let target = panel.url else { return }

        do {
            try outcome.delivered.write(to: target, atomically: true, encoding: .utf8)
            if derivedSomething {
                let beside = target.deletingPathExtension().appendingPathExtension("verbatim.txt")
                try outcome.verbatim.write(to: beside, atomically: true, encoding: .utf8)
                statusLine = "Saved, with the verbatim transcript beside it."
            } else {
                statusLine = "Saved."
            }
        } catch {
            statusLine = error.localizedDescription
        }
    }

    /// Types the result where the cursor is, which is what the app does with a dictation.
    func insertAtCursor() async {
        guard !visibleText.isEmpty else { return }
        await TextInjector.insert(visibleText)
        statusLine = "Inserted \(visibleText.count) characters."
    }
}
