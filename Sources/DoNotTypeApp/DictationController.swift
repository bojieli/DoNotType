import AppKit
import DoNotTypeCore
import Foundation

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

    private let log = Log("dictation")
    private let recorder = AudioRecorder()
    private let hotkey = HotkeyMonitor()
    private let grounding = GroundingCoordinator()
    private let overlay = RecordingOverlay()
    private let insertions = InsertionTracker()

    /// Opened at hotkey-down so the upload handshake happens while the user is still speaking.
    private var uploader: AudioUploader?
    private var levelTimer: Timer?
    /// The in-flight dictation's id, from the key press to the insertion.
    private var pendingID = UUID()

    /// Eight characters is enough to pick one dictation out of a day's log and short enough to
    /// sit in every line without pushing the interesting fields off the end.
    static func short(_ id: UUID) -> String { String(id.uuidString.prefix(8)) }

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

        // Checked here rather than only at onboarding. A recording made without this permission is
        // not refused — it is silence, and silence costs a request and produces an empty transcript
        // that reads as the app being broken.
        if let missing = PermissionGuide.microphone() {
            PermissionGuide.present(missing)
            fail(missing.message)
            return
        }

        do {
            recorder.preferredDeviceUID = Settings.shared.microphoneUID
            try recorder.start()
            state = .recording
            InteractionSounds.playStart()

            // One id from the key press to the insertion, on every line and on the history row.
            // Without it a log with three dictations in it is three interleaved stories, and the
            // question being asked is always about one of them.
            pendingID = UUID()
            log.info(
                "recording started",
                [
                    "dictation": Self.short(pendingID),
                    "mode": Settings.shared.hotkeyMode.rawValue,
                    "style": pendingStyle.rawValue,
                    "device": Settings.shared.microphoneUID ?? "system default",
                    "provider": Settings.shared.provider.rawValue,
                    "model": Settings.shared.model,
                    "fidelity": Settings.shared.fidelity.rawValue,
                    "grounding": Settings.shared.groundingEnabled ? "on" : "off",
                ])

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
                        mimeType: OpusEncoder.isAvailable ? "audio/ogg" : "audio/wav")
                }
            }

            overlay.show(phase: .recording, hint: Settings.shared.hotkeyMode.overlayHint)
            startLevelUpdates()
        } catch {
            log.error(
                "could not start recording",
                [
                    "dictation": Self.short(pendingID),
                    "device": Settings.shared.microphoneUID ?? "system default",
                    "detail": FailureAdvice.detail(of: error),
                ])
            fail(error.localizedDescription)
        }
    }

    private func cancelRecording() {
        guard state == .recording else { return }
        log.info("recording cancelled", ["dictation": Self.short(pendingID)])
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
            // A tap rather than a hold. Silently return to idle; not worth interrupting anyone —
            // but logged, because "I pressed the key and nothing happened" is a real report and
            // this is the most common innocent explanation for it.
            log.info("recording too short to send", ["dictation": Self.short(pendingID)])
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

        log.info(
            "recording finished",
            [
                "dictation": Self.short(pendingID),
                "seconds": String(format: "%.2f", audio.durationSeconds ?? 0),
                "bytes": "\(audio.data.count)",
                "type": audio.mimeType,
            ])

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
            id: pendingID,
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

        log.info(
            "transcribing",
            [
                "dictation": Self.short(pendingID),
                "provider": settings.provider.rawValue, "model": settings.model,
                "fidelity": settings.fidelity.rawValue,
                "style": style.rawValue,
                "seconds": String(format: "%.2f", audio.durationSeconds ?? 0),
                "grounded": context == nil ? "no" : "yes",
                "contextChars": "\(context?.visibleText?.count ?? 0)",
                "screenshot": context?.screenshotPNG == nil ? "no" : "yes",
                "app": record.appName ?? "?",
            ])

        do {
            // Pre-uploaded if the session opened and the upload landed; inline otherwise. The
            // fallback is silent by design — a flaky network should cost latency, never words.
            let audioPart = await resolveAudioPart(audio)
            let requestStart = Date()
            // Long recordings are split across concurrent requests; short ones — every ordinary
            // dictation — take the single-request path unchanged.
            // Hedged when a fallback backend is configured: the primary gets the whole delay to
            // itself, and only a stalled one is ever raced. See FallbackTranscriber.
            let outcome = try await makeTranscriber(primary: coordinator.service).transcribe(
                audio: audio, context: context, audioPart: audioPart,
                verifyNumbers: settings.numberCheck.applies(to: context)
            ) { [weak self] done, total in
                Task { @MainActor in
                    self?.overlay.update(phase: .transcribingChunk(done: done, of: total))
                }
            }
            let result = outcome.result
            // Recorded as the backend that actually answered, not the one that was asked. A
            // history row claiming Gemini for a transcript xAI produced would make the whole
            // history untrustworthy for exactly the comparisons it exists to support.
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
                    "dictation": Self.short(pendingID),
                    "chars": "\(text.count)",
                    "language": result.transcript.language,
                    "chunks": "\(result.chunkCount)",
                    "audioTokens": result.usage.audioTokens.map(String.init) ?? "unreported",
                    "provider": outcome.attribution.provider,
                    "model": outcome.attribution.model,
                    "hedged": outcome.attribution.provider == settings.provider.rawValue
                        ? "no" : "yes",
                    "ms": LogClock.ms(Date().timeIntervalSince(requestStart)),
                ])
            log.content("transcript", text, level: .trace)

            guard !text.isEmpty else {
                // Not an error, and the one outcome people report as one: the key worked, the
                // request worked, and nothing was said.
                log.info("nothing was said", ["dictation": Self.short(pendingID)])
                overlay.hide()
                state = .idle  // silence in, nothing out
                return
            }

            record.status = .completed
            record.text = text

            // The rewrite is a second pass over a transcript that already exists, so the verbatim
            // version is stored either way and "what did I actually say" stays answerable.
            var delivered = text
            var rewriteFailed = false
            if style.isRewrite, let instruction = rewriteInstruction(for: style) {
                overlay.update(phase: .deriving(style))
                let rewriteStart = Date()
                log.info(
                    "second stage",
                    [
                        "dictation": Self.short(pendingID), "style": style.rawValue,
                        "chars": "\(text.count)",
                    ])
                do {
                    let styled = try await coordinator.service.rewrite(
                        text, instruction: instruction)
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
                    rewriteFailed = true
                    // The words survive either way, so this is a warning rather than a failure —
                    // but it used to be `try?`, which meant a rewrite that failed every time was
                    // indistinguishable from one that had never been asked for.
                    log.warning(
                        "second stage failed, delivering the verbatim transcript",
                        [
                            "dictation": Self.short(pendingID), "style": style.rawValue,
                            "detail": FailureAdvice.detail(of: error),
                        ])
                }
                record.rewriteSeconds = Date().timeIntervalSince(rewriteStart)
            }

            record.latencySeconds = Date().timeIntervalSince(releasedAt)
            await store.insert(record, audio: settings.keepAudio ? try? Data(contentsOf: audio.url) : nil)
            onHistoryChange?()

            state = .idle

            // The words exist by now; only the last step cannot happen. So they go on the
            // clipboard and the user is told to paste — which is a working dictation with one
            // extra keystroke, rather than a failure.
            if let missing = PermissionGuide.accessibility() {
                TextInjector.copyForManualPaste(delivered, dictation: Self.short(pendingID))
                PermissionGuide.present(missing)
                fail("Copied — press ⌘V. Accessibility is off, so it could not paste itself.")
                return
            }

            await TextInjector.insert(delivered, dictation: Self.short(pendingID))
            insertions.record(recordID: record.id, delivered: delivered, verbatim: text)
            log.info(
                "dictation complete",
                [
                    "dictation": Self.short(pendingID), "chars": "\(delivered.count)",
                    "totalMs": LogClock.ms(Date().timeIntervalSince(releasedAt)),
                ])
            // Confirm rather than vanish: a silent disappearance leaves the user checking whether
            // anything happened, especially when the target app scrolled.
            overlay.confirmInserted(characters: delivered.count, rewriteFailed: rewriteFailed)
        } catch {
            let advice = FailureAdvice.describe(
                error, isOnline: await Reachability.shared.isOnline)
            let detail = FailureAdvice.detail(of: error)

            // The whole thing, in the log, on one record. Whatever the interface shows, this is
            // what somebody diagnosing it has to be able to read.
            log.error(
                "transcription failed",
                [
                    "advice": advice.message, "queued": advice.isQueued ? "yes" : "no",
                    "retryable": advice.isRetryable ? "yes" : "no",
                    "provider": settings.provider.rawValue, "model": settings.model,
                    "detail": detail,
                ])

            // The recording is kept so this can be retried from the history window, or
            // automatically at the next launch. A failed dictation is not lost work.
            record.status = .failed
            record.errorMessage = advice.message
            record.errorDetail = detail
            await store.insert(record, audio: try? Data(contentsOf: audio.url))
            onHistoryChange?()

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
            phase: .inserted(0, rewriteFailed: false),
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
        overlay.show(phase: .inserted(text.count, rewriteFailed: false), hint: "")
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

    /// Wraps the configured primary with a fallback, when one is set.
    ///
    /// Built per dictation rather than cached: the fallback provider, its key and the delay are all
    /// live settings, and a cached transcriber would keep using the previous ones until relaunch.
    private func makeTranscriber(primary: TranscriptionService) -> FallbackTranscriber {
        let settings = Settings.shared
        guard let kind = settings.fallbackProvider,
            let key = settings.resolvedAPIKey(for: kind), !key.isEmpty,
            let backend = try? ProviderFactory.make(kind, apiKey: key),
            let promptURL = SettingsModel.bundledPromptURL(),
            let instruction = try? PromptBuilder(contentsOf: promptURL)
                .systemInstruction(fidelity: settings.fidelity)
        else {
            return FallbackTranscriber(primary: primary)
        }

        return FallbackTranscriber(
            primary: primary,
            secondary: TranscriptionService(
                provider: backend, model: settings.model(for: kind),
                systemInstruction: instruction, fidelity: settings.fidelity,
                keytermBiasing: settings.keytermBiasing),
            hedgeAfter: .seconds(settings.fallbackAfterSeconds))
    }

    private func makeCoordinator() -> RetryCoordinator? {
        let settings = Settings.shared
        guard let key = settings.resolvedAPIKey(), !key.isEmpty,
            let provider = try? ProviderFactory.make(settings.provider, apiKey: key),
            let promptURL = Bundle.main.url(forResource: "PROMPT", withExtension: "md")
                ?? PromptBuilder.findPromptFile(),
            let instruction = try? PromptBuilder(contentsOf: promptURL)
                .systemInstruction(fidelity: settings.fidelity)
        else { return nil }

        return RetryCoordinator(
            service: TranscriptionService(
                provider: provider, model: settings.model, systemInstruction: instruction,
                fidelity: settings.fidelity, keytermBiasing: settings.keytermBiasing),
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
