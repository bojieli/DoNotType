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

    private let log = Logger(subsystem: "ai.19pine.donottype", category: "dictation")
    private let recorder = AudioRecorder()
    private let hotkey = HotkeyMonitor()
    private let grounding = GroundingCoordinator()
    private var history: [HistoryEntry] = []

    /// The last few dictations, newest first. Audio is not retained unless the user opts in.
    struct HistoryEntry: Identifiable {
        let id = UUID()
        let text: String
        let at: Date
        let context: ScreenContext?
        let contextTokens: Int
    }

    var recentHistory: [HistoryEntry] { history }

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
            // A tap rather than a hold. Silently return to idle; this is not an error worth
            // interrupting anyone over.
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
        defer {
            if !Settings.shared.keepAudio { try? FileManager.default.removeItem(at: audio.url) }
        }

        let settings = Settings.shared
        guard let key = settings.resolvedAPIKey(), !key.isEmpty else {
            fail("No API key. Add one in Settings.")
            return
        }

        do {
            let provider = try ProviderFactory.make(
                settings.provider, environment: [settings.provider.apiKeyEnvVar: key])
            let promptURL = Bundle.main.url(forResource: "PROMPT", withExtension: "md")
                ?? PromptBuilder.findPromptFile()
            guard let promptURL else {
                fail("PROMPT.md is missing from the app bundle.")
                return
            }

            let encoder = ContextEncoder()
            var parts: [InputPart] = []
            if let context { parts.append(contentsOf: encoder.encode(context)) }
            parts.append(audio.part)

            let result = try await provider.transcribe(
                TranscriptionRequest(
                    model: settings.model,
                    systemInstruction: try PromptBuilder(contentsOf: promptURL)
                        .systemInstruction(fidelity: settings.fidelity),
                    parts: parts))

            let text = result.transcript.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                state = .idle  // silence in, nothing out
                return
            }

            history.insert(
                HistoryEntry(
                    text: text, at: Date(), context: context,
                    contextTokens: context.map(encoder.estimatedTokens) ?? 0),
                at: 0)
            if history.count > 50 { history.removeLast() }

            state = .idle
            await TextInjector.insert(text)
        } catch {
            log.error("transcription failed: \(error.localizedDescription)")
            fail(error.localizedDescription)
        }
    }

    private func fail(_ message: String) {
        state = .failed(message)
        Task {
            try? await Task.sleep(for: .seconds(4))
            if case .failed = state { state = .idle }
        }
    }
}
