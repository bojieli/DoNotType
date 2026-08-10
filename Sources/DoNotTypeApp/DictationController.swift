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

    private let log = Logger(subsystem: "app.donottype", category: "dictation")
    private let recorder = AudioRecorder()
    private let hotkey = HotkeyMonitor()
    private let grounding = GroundingCoordinator()
    private let overlay = RecordingOverlay()
    private let insertions = InsertionTracker()

    /// Opened at hotkey-down so the upload handshake happens while the user is still speaking.
    private var uploader: AudioUploader?
    private var levelTimer: Timer?
    /// Which key started the in-flight recording decides whether it is rewritten.
    private var pendingStyle: RewriteStyle = .verbatim

    init(store: HistoryStore) {
        self.store = store
    }

    func start() -> Bool {
        // Watching the network lets a dictation be queued instead of failing, and lets the queue
        // drain itself the moment connectivity returns.
        Task {
            await Reachability.shared.start()
            await Reachability.shared.onOnlineAgain { [weak self] in
                Task { @MainActor in await self?.retryPending() }
            }
        }
        hotkey.trigger = Settings.shared.trigger
        hotkey.mode = Settings.shared.hotkeyMode
        hotkey.secondaryTrigger = Settings.shared.secondaryTrigger
        hotkey.isRecording = { [weak self] in self?.state == .recording }
        hotkey.onPressStyled = { [weak self] isStyled in
            self?.pendingStyle = isStyled ? Settings.shared.secondaryStyle : .verbatim
        }
        hotkey.onPress = { [weak self] in self?.beginRecording() }
        hotkey.onRelease = { [weak self] in self?.finishRecording() }
        hotkey.onCancel = { [weak self] in self?.cancelRecording() }

        // ⌘⇧Z undoes the last insertion; ⌘⌥Z swaps a rewrite back to what was actually said.
        // Both are cheap only because the verbatim transcript is always kept.
        hotkey.chords = [
            (keyCode: 6, flags: [.maskCommand, .maskShift], action: { [weak self] in
                Task { await self?.undoLastInsertion(revertToVerbatim: false) }
            }),
            (keyCode: 6, flags: [.maskCommand, .maskAlternate], action: { [weak self] in
                Task { await self?.undoLastInsertion(revertToVerbatim: true) }
            }),
            // ⌘⌃V re-pastes the last transcript, for when the first insertion landed in the
            // wrong window.
            (keyCode: 9, flags: [.maskCommand, .maskControl], action: { [weak self] in
                Task { await self?.pasteLastTranscript() }
            }),
        ]
        return hotkey.start()
    }

    func stop() {
        hotkey.stop()
        levelTimer?.invalidate()
    }

    /// Re-reads the trigger and mode after the user changes them in settings.
    func reloadHotkey() {
        hotkey.stop()
        hotkey.trigger = Settings.shared.trigger
        hotkey.mode = Settings.shared.hotkeyMode
        hotkey.secondaryTrigger = Settings.shared.secondaryTrigger
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
            recorder.preferredDeviceUID = Settings.shared.microphoneUID
            try recorder.start()
            state = .recording
            InteractionSounds.playStart()

            // Phase 2 of the capture: the expensive accessibility walk runs while the user is
            // still speaking, so grounding costs no perceived latency.
            grounding.beginCapture()

            // Same trick for the network. Opening the resumable upload session now means the
            // handshake is paid for during the recording rather than after it.
            if let key = Settings.shared.resolvedAPIKey(), Settings.shared.provider == .gemini {
                let uploader = AudioUploader(apiKey: key)
                self.uploader = uploader
                // Declared as Ogg because that is what will actually be sent; the session's
                // content type is fixed when it opens, not when the bytes arrive.
                Task {
                    await uploader.prepare(
                        estimatedBytes: AudioUploader.estimatedUploadBytes,
                        mimeType: OpusEncoder.isAvailable ? "audio/ogg" : "audio/wav")
                }
            }

            overlay.show(phase: .recording, hint: Settings.shared.hotkeyMode.overlayHint)
            startLevelUpdates()
        } catch {
            log.error("could not start recording: \(error.localizedDescription)")
            fail(error.localizedDescription)
        }
    }

    private func cancelRecording() {
        guard state == .recording else { return }
        recorder.cancel()
        grounding.cancel()
        Task { [uploader] in await uploader?.cancel() }
        uploader = nil
        stopLevelUpdates()
        overlay.hide()
        state = .idle
    }

    private func startLevelUpdates() {
        levelTimer?.invalidate()
        levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.overlay.update(level: self.recorder.level)
            }
        }
    }

    private func stopLevelUpdates() {
        levelTimer?.invalidate()
        levelTimer = nil
    }

    private func finishRecording() {
        guard state == .recording else { return }
        stopLevelUpdates()

        InteractionSounds.playStop()

        let audio: AudioFile
        do {
            audio = try recorder.stop()
        } catch AudioRecorder.RecorderError.tooShort {
            // A tap rather than a hold. Silently return to idle; not worth interrupting anyone.
            grounding.cancel()
            Task { [uploader] in await uploader?.cancel() }
            uploader = nil
            overlay.hide()
            state = .idle
            return
        } catch {
            grounding.cancel()
            fail(error.localizedDescription)
            return
        }

        state = .transcribing
        overlay.update(phase: .transcribing)
        // Started here, not at the request: the wait the user experiences includes the screen
        // context read and any fallback, and a figure that skipped those would flatter the app.
        let releasedAt = Date()
        Task { [weak self] in
            guard let self else { return }
            await transcribe(
                audio: audio, context: await grounding.finishCapture(), releasedAt: releasedAt)
        }
    }

    private func transcribe(
        audio: AudioFile, context: ScreenContext?, releasedAt: Date = Date()
    ) async {
        defer { try? FileManager.default.removeItem(at: audio.url) }

        let style = pendingStyle
        pendingStyle = .verbatim
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
            durationSeconds: audio.durationSeconds ?? 0,
            context: context)

        // Offline is worth knowing *before* spending fifteen seconds on a timeout: the dictation
        // goes straight to the queue and the user is told it is safe rather than lost.
        if await !Reachability.shared.isOnline {
            record.status = .pending
            record.errorMessage = "Offline when recorded."
            await store.insert(record, audio: try? Data(contentsOf: audio.url))
            onHistoryChange?()
            fail("Offline — saved, and it will send itself when you reconnect.")
            return
        }

        do {
            // Pre-uploaded if the session opened and the upload landed; inline otherwise. The
            // fallback is silent by design — a flaky network should cost latency, never words.
            let audioPart = await resolveAudioPart(audio)
            let requestStart = Date()
            // Long recordings are split across concurrent requests; short ones — every ordinary
            // dictation — take the single-request path unchanged.
            let result = try await coordinator.service.transcribeLong(
                audio: audio, context: context, audioPart: audioPart,
                verifyNumbers: settings.numberCheck.applies(to: context)
            ) { [weak self] done, total in
                Task { @MainActor in
                    self?.overlay.update(phase: .transcribingChunk(done: done, of: total))
                }
            }
            record.requestSeconds = Date().timeIntervalSince(requestStart)
            record.usage = result.usage
            record.chunkCount = result.chunkCount
            let text = result.transcript.transcript
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard !text.isEmpty else {
                overlay.hide()
                state = .idle  // silence in, nothing out
                return
            }

            record.status = .completed
            record.text = text

            // The rewrite is a second pass over a transcript that already exists, so the verbatim
            // version is stored either way and "what did I actually say" stays answerable.
            var delivered = text
            if style.isRewrite, let instruction = rewriteInstruction(for: style) {
                overlay.update(phase: .transcribing)
                let rewriteStart = Date()
                if let styled = try? await coordinator.service.rewrite(text, instruction: instruction) {
                    record.styledText = styled
                    record.style = style
                    delivered = styled
                }
                record.rewriteSeconds = Date().timeIntervalSince(rewriteStart)
            }

            record.latencySeconds = Date().timeIntervalSince(releasedAt)
            await store.insert(record, audio: settings.keepAudio ? try? Data(contentsOf: audio.url) : nil)
            onHistoryChange?()

            state = .idle
            await TextInjector.insert(delivered)
            insertions.record(recordID: record.id, delivered: delivered, verbatim: text)
            // Confirm rather than vanish: a silent disappearance leaves the user checking whether
            // anything happened, especially when the target app scrolled.
            overlay.confirmInserted(characters: delivered.count)
        } catch {
            log.error("transcription failed: \(error.localizedDescription)")

            // The recording is kept so this can be retried from the history window, or
            // automatically at the next launch. A failed dictation is not lost work.
            record.status = .failed
            record.errorMessage = error.localizedDescription
            await store.insert(record, audio: try? Data(contentsOf: audio.url))
            onHistoryChange?()

            let advice = FailureAdvice.describe(
                error, isOnline: await Reachability.shared.isOnline)
            fail(advice.message)
        }
    }

    // MARK: - Undo and re-paste

    var canUndo: Bool { insertions.canUndo }
    var canRevertToVerbatim: Bool { insertions.canRevertToVerbatim }

    func undoLastInsertion(revertToVerbatim: Bool) async {
        guard insertions.canUndo else { return }
        let didUndo = await insertions.undo(replacingWithVerbatim: revertToVerbatim)
        guard didUndo else { return }

        overlay.show(
            phase: .inserted(0),
            hint: revertToVerbatim ? "Reverted to what you said" : "Removed")
        overlay.update(phase: .failed(revertToVerbatim ? "Reverted to verbatim" : "Insertion removed"))
        overlay.hide(after: .milliseconds(1_200))
    }

    /// Re-inserts the most recent transcript, for when the first one landed in the wrong window.
    func pasteLastTranscript() async {
        let recent = await store.all().first { $0.status == .completed }
        guard let recent else { return }

        let text = recent.deliveredText
        await TextInjector.insert(text)
        insertions.record(recordID: recent.id, delivered: text, verbatim: recent.text)
        overlay.show(phase: .inserted(text.count), hint: "")
        overlay.hide(after: .milliseconds(900))
    }

    private func rewriteInstruction(for style: RewriteStyle) -> String? {
        guard let promptURL = SettingsModel.bundledPromptURL() else { return nil }
        return try? PromptStore(directory: HistoryStore.defaultDirectory())
            .builder(default: promptURL)
            .rewriteInstruction(style: style)
    }

    /// Chooses the upload route, degrading to inline rather than failing.
    private func resolveAudioPart(_ audio: AudioFile) async -> InputPart? {
        guard let uploader else { return nil }
        self.uploader = nil
        do {
            let plan = try await uploader.plan(for: audio)
            if case .preUploaded = plan.route {
                log.info("audio pre-uploaded; request carries a URI instead of base64")
            }
            return plan.part
        } catch {
            // Only happens when the recording is too big to inline AND the upload service is
            // unreachable. Surfacing it lets the caller store the audio for a later retry.
            log.warning("no upload route available: \(error.localizedDescription)")
            return nil
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
        overlay.update(phase: .failed(message))
        overlay.hide(after: .seconds(5))
        state = .failed(message)
        Task {
            try? await Task.sleep(for: .seconds(5))
            if case .failed = state { state = .idle }
        }
    }
}
