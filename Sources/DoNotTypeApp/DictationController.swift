import AppKit
import DoNotTypeCore
import Foundation
import os

/// Orchestrates one dictation: hold the key, speak, release, get your words back.
@MainActor
final class DictationController {
    enum State: Equatable {
        case idle
        case recording
        case transcribing
        case failed(String)
    }

    private(set) var state: State = .idle {
        didSet { if state != oldValue { onStateChange?(state) } }
    }

    var onStateChange: ((State) -> Void)?
    /// Fires after a dictation is stored, so an open settings window can refresh.
    var onHistoryChange: (() -> Void)?

    let store: HistoryStore

    private let log = Logger(subsystem: "ai.19pine.donottype", category: "dictation")
    private let recorder = AudioRecorder()
    private let hotkey = HotkeyMonitor()
    private let grounding = GroundingCoordinator()

    init(store: HistoryStore) {
        self.store = store
    }

    func start() -> Bool {
        hotkey.trigger = Settings.shared.trigger
        hotkey.onPress = { [weak self] in self?.beginRecording() }
        hotkey.onRelease = { [weak self] in self?.finishRecording() }
        hotkey.onCancel = { [weak self] in self?.cancelRecording() }
        return hotkey.start()
    }

    func stop() { hotkey.stop() }

    /// Re-reads the trigger after the user changes it in settings.
    func reloadHotkey() {
        hotkey.stop()
        hotkey.trigger = Settings.shared.trigger
        _ = hotkey.start()
    }

    /// Drains anything that failed while the network was down. Called at launch.
    func retryPending() async {
        guard let coordinator = makeCoordinator() else { return }
        let pending = await store.retryable()
        guard !pending.isEmpty else { return }

        log.info("retrying \(pending.count) pending dictation(s)")
        _ = await coordinator.retryAll()
        onHistoryChange?()
    }

    // MARK: - Recording

    private func beginRecording() {
        guard state == .idle else { return }
        do {
            try recorder.start()
            state = .recording
            // Phase 2 of the capture: the expensive accessibility walk runs while the user is
            // still speaking, so grounding costs no perceived latency.
            grounding.beginCapture()
        } catch {
            log.error("could not start recording: \(error.localizedDescription)")
            fail(error.localizedDescription)
        }
    }

    private func cancelRecording() {
        guard state == .recording else { return }
        recorder.cancel()
        grounding.cancel()
        state = .idle
    }

    private func finishRecording() {
        guard state == .recording else { return }

        let audio: AudioFile
        do {
            audio = try recorder.stop()
        } catch AudioRecorder.RecorderError.tooShort {
            // A tap rather than a hold. Silently return to idle; not worth interrupting anyone.
            grounding.cancel()
            state = .idle
            return
        } catch {
            grounding.cancel()
            fail(error.localizedDescription)
            return
        }

        state = .transcribing
        Task { [weak self] in
            guard let self else { return }
            await transcribe(audio: audio, context: await grounding.finishCapture())
        }
    }

    private func transcribe(audio: AudioFile, context: ScreenContext?) async {
        defer { try? FileManager.default.removeItem(at: audio.url) }

        let settings = Settings.shared
        let frontmost = NSWorkspace.shared.frontmostApplication?.localizedName

        guard let coordinator = makeCoordinator() else {
            fail("No API key. Open Settings to add one.")
            return
        }

        var record = DictationRecord(
            status: .pending,
            provider: settings.provider.rawValue,
            model: settings.model,
            fidelity: settings.fidelity,
            appName: context?.appName ?? frontmost,
            windowTitle: context?.windowTitle,
            context: context)

        do {
            let result = try await coordinator.service.transcribeWithRetry(
                audio: audio, context: context)
            let text = result.transcript.transcript
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard !text.isEmpty else {
                state = .idle  // silence in, nothing out
                return
            }

            record.status = .completed
            record.text = text
            await store.insert(record, audio: settings.keepAudio ? try? Data(contentsOf: audio.url) : nil)
            onHistoryChange?()

            state = .idle
            await TextInjector.insert(text)
        } catch {
            log.error("transcription failed: \(error.localizedDescription)")

            // The recording is kept so this can be retried from the history window, or
            // automatically at the next launch. A failed dictation is not lost work.
            record.status = .failed
            record.errorMessage = error.localizedDescription
            await store.insert(record, audio: try? Data(contentsOf: audio.url))
            onHistoryChange?()

            fail(
                TranscriptionService.isTransient(error)
                    ? "\(error.localizedDescription) — saved, retry from History."
                    : error.localizedDescription)
        }
    }

    private func makeCoordinator() -> RetryCoordinator? {
        let settings = Settings.shared
        guard let key = settings.resolvedAPIKey(), !key.isEmpty,
            let provider = try? ProviderFactory.make(
                settings.provider, environment: [settings.provider.apiKeyEnvVar: key]),
            let promptURL = Bundle.main.url(forResource: "PROMPT", withExtension: "md")
                ?? PromptBuilder.findPromptFile(),
            let instruction = try? PromptBuilder(contentsOf: promptURL)
                .systemInstruction(fidelity: settings.fidelity)
        else { return nil }

        return RetryCoordinator(
            service: TranscriptionService(
                provider: provider, model: settings.model, systemInstruction: instruction),
            store: store)
    }

    private func fail(_ message: String) {
        state = .failed(message)
        Task {
            try? await Task.sleep(for: .seconds(5))
            if case .failed = state { state = .idle }
        }
    }
}
