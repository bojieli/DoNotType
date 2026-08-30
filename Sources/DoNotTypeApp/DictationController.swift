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
    /// Fires when opt-in correction learning changes the local dictionary.
    var onDictionaryChange: (([String]) -> Void)?

    let store: HistoryStore

    private let log = Log("dictation")
    private let recorder = AudioRecorder()
    private let hotkey = HotkeyMonitor()
    private var hotkeyPausedForCapture = false
    private let grounding = GroundingCoordinator()
    private let overlay = RecordingOverlay()
    private let insertions = InsertionTracker()

    private var levelTimer: Timer?
    private var livePipeline: LiveAudioPipeline?
    private var pendingContextTask: Task<ScreenContext?, Never>?
    private var transcriptionTask: Task<Void, Never>?
    /// The in-flight dictation's id, from the key press to the insertion.
    private var pendingID = UUID()

    /// Eight characters is enough to pick one dictation out of a day's log and short enough to
    /// sit in every line without pushing the interesting fields off the end.
    static func short(_ id: UUID) -> String { String(id.uuidString.prefix(8)) }

    /// Which key started the in-flight recording decides whether it is rewritten.
    private var pendingStyle: RewriteStyle = .verbatim
    /// Latched only when Return, rather than the normal trigger, finishes this recording.
    private var pendingFinishAndSend: FinishAndSendAction = .disabled
    private(set) var lastLearnedTerms: [String] = []

    /// Who was focused when the key went down, so the transcript cannot be typed somewhere else.
    ///
    /// The process id rather than the name: two windows of the same app are the same target, and
    /// two apps with the same name are not something to gamble a paste on.
    private var pendingTarget: (pid: pid_t, name: String)?
    /// Exact field identity used to keep the delayed submit key in the field recording began in.
    private var pendingFocusIdentity: AccessibilityReader.FocusedElementIdentity?

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
        hotkey.cancelShortcut = Settings.shared.cancelShortcut
        hotkey.finishAndSendAction = Settings.shared.finishAndSendAction
        hotkey.secondaryTrigger = Settings.shared.secondaryTrigger
        hotkey.isRecording = { [weak self] in self?.state == .recording }
        hotkey.isDictationActive = { [weak self] in
            guard let self else { return false }
            return self.state == .recording || self.state == .transcribing
        }
        hotkey.onPressStyled = { [weak self] isStyled in
            self?.pendingStyle = isStyled ? Settings.shared.secondaryStyle : .verbatim
        }
        hotkey.onPress = { [weak self] in self?.beginRecording() }
        hotkey.onRelease = { [weak self] in self?.finishRecording() }
        hotkey.onHoldChange = { [weak self] held in self?.triggerHoldChanged(held) }
        hotkey.onCancel = { [weak self] in self?.cancelActiveDictation() }
        hotkey.onFinishWithReturn = { [weak self] action in self?.finishWithReturn(action) }

        // ⌘⇧Z undoes the last insertion; ⌘⌥Z swaps a rewrite back to what was actually said.
        // Both are cheap only because the verbatim transcript is always kept.
        hotkey.chords = [
            (keyCode: 6, flags: [.maskCommand, .maskShift], action: { [weak self] in
                Task { await self?.undoLastInsertion(revertToVerbatim: false) }
            }),
            (keyCode: 6, flags: [.maskCommand, .maskAlternate], action: { [weak self] in
                Task { await self?.undoLastInsertion(revertToVerbatim: true) }
            }),
        ]
        return hotkey.start()
    }

    func stop() {
        hotkey.stop()
        transcriptionTask?.cancel()
        levelTimer?.invalidate()
    }

    /// Builds the audio input ahead of the first dictation. See `AudioRecorder.warmUp`.
    ///
    /// Detached, because doing it on the main actor would only move the stall from the first key
    /// press to launch, and launch is when the menu bar and the settings window are being built.
    func warmUpAudio() {
        let recorder = self.recorder
        Task.detached(priority: .utility) { recorder.warmUp() }
    }

    /// Re-reads the trigger and mode after the user changes them in settings.
    func reloadHotkey() {
        guard !hotkeyPausedForCapture else { return }
        hotkey.stop()
        hotkey.trigger = Settings.shared.trigger
        hotkey.mode = Settings.shared.hotkeyMode
        hotkey.cancelShortcut = Settings.shared.cancelShortcut
        hotkey.finishAndSendAction = Settings.shared.finishAndSendAction
        hotkey.secondaryTrigger = Settings.shared.secondaryTrigger
        _ = hotkey.start()
    }

    /// Gives the settings recorder exclusive access to keystrokes. Otherwise pressing the old
    /// shortcut while trying to replace it would begin a dictation behind the settings window.
    /// An in-flight dictation keeps ownership until it has finished so its release is never lost.
    func setHotkeyCaptureActive(_ active: Bool) -> Bool {
        if active {
            guard state == .idle, !hotkeyPausedForCapture else { return false }
            hotkeyPausedForCapture = true
            hotkey.stop()
            return true
        }

        guard hotkeyPausedForCapture else { return true }
        hotkeyPausedForCapture = false
        reloadHotkey()
        return true
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
            // Construct the request machinery before capture so the first PCM sample enters both
            // the recovery WAV and the live segmenter. Missing configuration still follows the
            // established post-release error path.
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
            recorder.preferredDeviceUID = Settings.shared.microphoneUID
            try recorder.start()
            state = .recording
            InteractionSounds.playStart()

            // One id from the key press to the insertion, on every line and on the history row.
            // Without it a log with three dictations in it is three interleaved stories, and the
            // question being asked is always about one of them.
            pendingID = UUID()
            pendingFinishAndSend = .disabled
            // Where the words are meant to go, decided now rather than when they arrive.
            pendingTarget = NSWorkspace.shared.frontmostApplication.map {
                ($0.processIdentifier, $0.localizedName ?? "?")
            }
            pendingFocusIdentity = AccessibilityReader.focusedElementIdentity()
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
            let contextTask = Task { [grounding] in await grounding.finishCapture() }
            pendingContextTask = contextTask
            if let session = livePipeline?.session {
                Task {
                    await session.setContext(await contextTask.value)
                }
            }

            // The same trick, for the network. Opening a connection costs about a second, and
            // whether the pooled one is still alive cannot be known without using it — so both
            // happen here, against speech the user was going to produce anyway, rather than after
            // the key comes up with somebody watching. A connection found dead is replaced
            // mid-sentence instead of eight seconds into a wait. See `ProviderTransport`.
            warmUpConnection()

            let hints = recordingHints(isTriggerHeld: hotkey.isHeld)
            overlay.show(
                phase: .recording, hint: hints.primary, subhint: hints.secondary)
            startLevelUpdates()
        } catch {
            recorder.cancel()
            livePipeline?.cancel()
            livePipeline = nil
            recorder.onPCM = nil
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
        recorder.onPCM = nil
        livePipeline?.cancel()
        livePipeline = nil
        pendingContextTask?.cancel()
        pendingContextTask = nil
        grounding.cancel()
        stopLevelUpdates()
        overlay.hide()
        pendingFinishAndSend = .disabled
        pendingFocusIdentity = nil
        state = .idle
    }

    private func cancelActiveDictation() {
        switch state {
        case .recording:
            cancelRecording()
        case .transcribing:
            log.info("transcription cancellation requested", ["dictation": Self.short(pendingID)])
            // The task's cancellation handler also stops live segment requests and context capture.
            grounding.cancel()
            transcriptionTask?.cancel()
            overlay.hide()
        case .idle, .failed:
            break
        }
    }

    private func finishWithReturn(_ action: FinishAndSendAction) {
        guard state == .recording else { return }
        pendingFinishAndSend = action
        log.info(
            "Return finish requested",
            ["dictation": Self.short(pendingID), "action": action.rawValue])
        finishRecording()
    }

    private func triggerHoldChanged(_ isHeld: Bool) {
        guard state == .recording else { return }
        let hints = recordingHints(isTriggerHeld: isHeld)
        overlay.update(
            phase: .recording, hint: hints.primary, subhint: hints.secondary)
    }

    private func recordingHints(isTriggerHeld: Bool) -> (primary: String, secondary: String) {
        let primary = Settings.shared.hotkeyMode.overlayHint(isTriggerHeld: isTriggerHeld)
        // Escape has cancelled a recording since the shortcut existed, and nothing on screen said
        // so; the overlay is the only surface a user is looking at while one is under way.
        let secondary = RecordingHint.secondary(
            finish: Settings.shared.finishAndSendAction == .disabled ? "" : "Return to send",
            cancel: Settings.shared.cancelShortcut)
        return (primary, secondary)
    }

    private func startLevelUpdates() {
        levelTimer?.invalidate()
        levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.overlay.append(levels: self.recorder.drainLevels())
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
            recorder.onPCM = nil
        } catch AudioRecorder.RecorderError.tooShort {
            // A tap rather than a hold is not an error, but hiding the pill makes the gesture look
            // lost. Say what happened without turning the menu-bar icon into a warning.
            log.info("recording too short to send", ["dictation": Self.short(pendingID)])
            livePipeline?.cancel()
            livePipeline = nil
            pendingContextTask?.cancel()
            pendingContextTask = nil
            grounding.cancel()
            notice("Recording was too short — try again")
            return
        } catch {
            livePipeline?.cancel()
            livePipeline = nil
            pendingContextTask?.cancel()
            pendingContextTask = nil
            grounding.cancel()
            fail(error.localizedDescription)
            return
        }

        let activity: SpeechActivity.Reading
        do {
            activity = try SpeechActivity.measure(wav: audio.data)
        } catch {
            livePipeline?.cancel()
            livePipeline = nil
            pendingContextTask?.cancel()
            pendingContextTask = nil
            grounding.cancel()
            try? FileManager.default.removeItem(at: audio.url)
            fail(error.localizedDescription)
            return
        }
        guard livePipeline != nil || activity.hasSpeech else {
            log.info(
                "nothing was said, so nothing was sent",
                ["dictation": Self.short(pendingID), "audio": activity.summary])
            pendingContextTask?.cancel()
            pendingContextTask = nil
            grounding.cancel()
            try? FileManager.default.removeItem(at: audio.url)
            notice("No speech detected — recording wasn’t sent")
            return
        }

        log.info(
            "recording finished",
            [
                "dictation": Self.short(pendingID),
                "seconds": String(format: "%.2f", audio.durationSeconds ?? 0),
                "bytes": "\(audio.data.count)",
                "type": audio.mimeType,
                "audio": activity.summary,
            ])

        state = .transcribing
        let finishAndSend = pendingFinishAndSend
        let submitTarget = pendingFocusIdentity
        let target = pendingTarget
        let dictationID = pendingID
        // Escape cancels the request as well as the recording, and the wait for a request is the
        // longer of the two — so this is the phase where knowing there is a way out matters most.
        overlay.update(
            phase: .transcribing,
            hint: RecordingHint.secondary(
                finish: finishAndSend == .disabled ? "" : "Will send",
                cancel: Settings.shared.cancelShortcut))
        // Started here, not at the request: the wait the user experiences includes the screen
        // context read and any fallback, and a figure that skipped those would flatter the app.
        let releasedAt = Date()
        let pipeline = livePipeline
        livePipeline = nil
        let contextTask = pendingContextTask
        pendingContextTask = nil
        transcriptionTask = Task { [weak self] in
            guard let self else { return }
            defer { transcriptionTask = nil }
            await withTaskCancellationHandler {
                let context = await contextTask?.value
                guard !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: audio.url)
                    transcriptionCancelled()
                    return
                }
                if let session = pipeline?.session { await session.setContext(context) }
                await transcribe(
                    audio: audio, context: context, releasedAt: releasedAt, livePipeline: pipeline,
                    dictationID: dictationID, target: target, finishAndSend: finishAndSend,
                    submitTarget: submitTarget)
            } onCancel: {
                contextTask?.cancel()
                pipeline?.cancel()
            }
        }
    }

    private func transcribe(
        audio: AudioFile, context: ScreenContext?, releasedAt: Date = Date(),
        livePipeline: LiveAudioPipeline? = nil, dictationID: UUID,
        target: (pid: pid_t, name: String)?, finishAndSend: FinishAndSendAction,
        submitTarget: AccessibilityReader.FocusedElementIdentity?
    ) async {
        defer { try? FileManager.default.removeItem(at: audio.url) }

        guard !Task.isCancelled else {
            transcriptionCancelled()
            return
        }

        let style = pendingStyle
        pendingStyle = .verbatim
        let settings = Settings.shared
        // A target language replaces the second stage rather than joining it. Two jobs in one
        // request is exactly the combination this project has already measured as worse, and
        // "formal French" is a feature request rather than a fix for the one that was asked for.
        // The settings window says so beside the rewrite picker, through `RewriteAvailability`.
        let stage: TranscriptMode = settings.translateTo.isEmpty
            ? (style.isRewrite ? .rewrite(style) : .verbatim)
            : .translate(settings.translateTo)
        let frontmost = NSWorkspace.shared.frontmostApplication?.localizedName

        guard let coordinator = makeCoordinator() else {
            fail("No API key. Open Settings to add one.")
            return
        }

        var record = DictationRecord(
            id: dictationID,
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
        let isOnline = await Reachability.shared.isOnline
        guard !Task.isCancelled else {
            transcriptionCancelled()
            return
        }
        if !isOnline {
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
                "dictation": Self.short(dictationID),
                "provider": settings.provider.rawValue, "model": settings.model,
                "fidelity": settings.fidelity.rawValue,
                "mode": stage.rawValue,
                "seconds": String(format: "%.2f", audio.durationSeconds ?? 0),
                "grounded": context == nil ? "no" : "yes",
                "contextChars": "\(context?.visibleText?.count ?? 0)",
                "screenshot": context?.screenshotPNG == nil ? "no" : "yes",
                "app": record.appName ?? "?",
            ])

        // A rewrite is asked for in the same request that transcribes, not in a second one.
        // Measured on gemini-3.5-flash: 2.54 s against 3.11 s for two passes, over 20 trials each.
        // Latency is the whole of the case — substitution is saturated on the reference clip at
        // this model, so it separates nothing either way. The verbatim transcript is still returned
        // alongside the styled text, so it is stored first and stays recoverable. A recogniser
        // cannot answer the wider schema and falls back to the second pass inside
        // `transcribeStyled`.
        //
        // Only the live-pipeline path opts out: it stitches segments transcribed as the user
        // speaks, and a style belongs to the whole utterance rather than to each segment.
        let folded: StyledRequest? = livePipeline == nil ? styledRequest(for: stage) : nil

        do {
            let requestStart = Date()
            // Long recordings are split across concurrent requests; short ones — every ordinary
            // dictation — take the single-request path unchanged.
            // Hedged when a fallback backend is configured: the primary gets the whole delay to
            // itself, and only a stalled one is ever raced. See FallbackTranscriber.
            let outcome: FallbackTranscriber.Outcome
            if let livePipeline {
                outcome = try await livePipeline.finish()
            } else {
                outcome = try await makeTranscriber(primary: coordinator.service).transcribe(
                    audio: audio, context: context, styled: folded
                ) { [weak self] done, total in
                    Task { @MainActor in
                        self?.overlay.update(phase: .transcribingChunk(done: done, of: total))
                    }
                }
            }
            let result = outcome.result
            try Task.checkCancellation()
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
                    "dictation": Self.short(dictationID),
                    "chars": "\(text.count)",
                    "language": result.transcript.language,
                    "chunks": "\(result.chunkCount)",
                    "audioTokens": result.usage.audioTokens.map(String.init) ?? "unreported",
                    "thoughtTokens": result.usage.thoughtTokens.map(String.init) ?? "unreported",
                    "provider": outcome.attribution.provider,
                    "model": outcome.attribution.model,
                    "hedged": outcome.attribution.provider == settings.provider.rawValue
                        ? "no" : "yes",
                    "ms": LogClock.ms(Date().timeIntervalSince(requestStart)),
                ])
            log.content("transcript", text, level: .trace)

            guard !text.isEmpty else {
                // Live segmentation can legitimately produce no qualified chunks even though the
                // pipeline existed. Do not turn that into the same silent disappearance the local
                // VAD gate is intended to explain.
                log.info("nothing was said", ["dictation": Self.short(dictationID)])
                notice("No speech detected — recording wasn’t sent")
                return
            }

            record.status = .completed
            record.text = text

            // The rewrite is a second pass over a transcript that already exists, so the verbatim
            // version is stored either way and "what did I actually say" stays answerable.
            var delivered = text
            var rewriteFailed = false
            if let styled = result.transcript.styled?
                .trimmingCharacters(in: .whitespacesAndNewlines), !styled.isEmpty
            {
                // The rewrite came back in the transcription response, so there is no second stage
                // to run and nothing extra to wait for.
                record.styledText = styled
                record.style = stage.rewriteStyle
                record.mode = stage
                delivered = styled
                log.info(
                    "styled in one request",
                    [
                        "dictation": Self.short(dictationID), "mode": stage.rawValue,
                        "chars": "\(styled.count)", "from": "\(text.count)",
                    ])
            } else if stage.needsSecondPass, let instruction = secondStageInstruction(for: stage) {
                overlay.update(phase: .deriving(stage))
                let rewriteStart = Date()
                log.info(
                    "second stage",
                    [
                        "dictation": Self.short(dictationID), "mode": stage.rawValue,
                        "chars": "\(text.count)",
                    ])
                do {
                    // The selected backend when it is a model; xAI's chat endpoint, or a borrowed
                    // model backend, when it is a recogniser that cannot rewrite on its own.
                    let rewriter = TextStage.service(instruction: instruction)
                        ?? coordinator.service
                    let styled = try await rewriter.rewrite(text, instruction: instruction)
                    try Task.checkCancellation()
                    record.styledText = styled
                    record.style = stage.rewriteStyle
                    record.mode = stage
                    delivered = styled
                    log.info(
                        "second stage finished",
                        [
                            "dictation": Self.short(dictationID),
                            "chars": "\(styled.count)", "from": "\(text.count)",
                            "ms": LogClock.ms(Date().timeIntervalSince(rewriteStart)),
                        ])
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    if Task.isCancelled { throw CancellationError() }
                    rewriteFailed = true
                    // The words survive either way, so this is a warning rather than a failure —
                    // but it used to be `try?`, which meant a rewrite that failed every time was
                    // indistinguishable from one that had never been asked for.
                    log.warning(
                        "second stage failed, delivering the verbatim transcript",
                        [
                            "dictation": Self.short(dictationID), "mode": stage.rawValue,
                            "detail": FailureAdvice.detail(of: error),
                        ])
                }
                record.rewriteSeconds = Date().timeIntervalSince(rewriteStart)
            }

            try Task.checkCancellation()
            record.latencySeconds = Date().timeIntervalSince(releasedAt)
            await store.insert(record, audio: settings.keepAudio ? try? Data(contentsOf: audio.url) : nil)
            onHistoryChange?()

            try Task.checkCancellation()
            state = .idle

            // The words exist by now; only the last step cannot happen. So they go on the
            // clipboard and the user is told to paste — which is a working dictation with one
            // extra keystroke, rather than a failure.
            if let missing = PermissionGuide.accessibility() {
                TextInjector.copyForManualPaste(delivered, dictation: Self.short(dictationID))
                PermissionGuide.present(missing)
                fail("Copied — press ⌘V. Accessibility is off, so it could not paste itself.")
                return
            }

            // Where the user was looking when they spoke, not where they are looking now.
            //
            // The paste goes to whatever holds focus at the moment it fires, which is the right
            // answer only if that is still the same place. It stopped being the same place every
            // time a dictation took a minute: the user gave up waiting and moved on, and the
            // transcript arrived in whatever they had moved on to. In this app's own logs that
            // put 172 and 292 characters of speech into DoNotType's settings window — into the
            // model name field, which then sent each of them to the API as a model.
            //
            // Short waits make it rare rather than impossible, and the failure is silent and
            // occasionally destructive: the text lands in a terminal, a chat box, a password
            // field. So it is checked instead. Nothing is lost when it fires — the transcript is
            // already in the history and on the clipboard, one keystroke from where it was going.
            if let expected = target,
                let current = NSWorkspace.shared.frontmostApplication,
                current.processIdentifier != expected.pid
            {
                TextInjector.copyForManualPaste(delivered, dictation: Self.short(dictationID))
                log.warning(
                    "focus moved while transcribing; not typing into a window the user did not dictate into",
                    [
                        "dictation": Self.short(dictationID),
                        "spokeInto": expected.name,
                        "nowFocused": current.localizedName ?? "?",
                        "waitedMs": LogClock.ms(Date().timeIntervalSince(releasedAt)),
                    ])
                insertions.record(recordID: record.id, delivered: delivered, verbatim: text)
                fail("Copied — press ⌘V. You left \(expected.name) while it was transcribing.")
                return
            }

            await TextInjector.insert(delivered, dictation: Self.short(dictationID))
            insertions.record(recordID: record.id, delivered: delivered, verbatim: text)

            let submission: OverlayState.Submission
            if finishAndSend == .disabled {
                submission = .notRequested
            } else if let expected = submitTarget {
                let current = AccessibilityReader.focusedElementIdentity()
                if current == expected {
                    submission = TextInjector.submit(
                        using: finishAndSend, dictation: Self.short(dictationID))
                        ? .sent : .skippedUnavailable
                } else {
                    submission = .skippedFocusMoved
                    log.warning(
                        "submission skipped because focus moved after insertion",
                        ["dictation": Self.short(dictationID), "action": finishAndSend.rawValue])
                }
            } else {
                submission = .skippedUnavailable
                log.warning(
                    "submission skipped because the original field could not be identified",
                    ["dictation": Self.short(dictationID), "action": finishAndSend.rawValue])
            }

            // Once Return has been sent the message is no longer editable, so an undo shortcut or
            // correction watcher would act on whatever the app focused next instead of this text.
            if submission == .sent {
                insertions.clear()
            } else if settings.learnDictionaryFromEdits {
                insertions.watchForCorrections(to: delivered) { [weak self] candidates in
                    self?.learn(candidates)
                }
            }
            let submissionLog = switch submission {
            case .notRequested: "not requested"
            case .sent: "sent"
            case .skippedFocusMoved: "skipped: focus moved"
            case .skippedUnavailable: "skipped: unavailable"
            }
            log.info(
                "dictation complete",
                [
                    "dictation": Self.short(dictationID), "chars": "\(delivered.count)",
                    "totalMs": LogClock.ms(Date().timeIntervalSince(releasedAt)),
                    "submission": submissionLog,
                ])
            // Confirm rather than vanish: a silent disappearance leaves the user checking whether
            // anything happened, especially when the target app scrolled.
            overlay.confirmInserted(
                characters: delivered.count, rewriteFailed: rewriteFailed, submission: submission)
        } catch is CancellationError {
            transcriptionCancelled()
        } catch {
            if Task.isCancelled {
                transcriptionCancelled()
                return
            }
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

    private func transcriptionCancelled() {
        pendingStyle = .verbatim
        log.info("transcription cancelled", ["dictation": Self.short(pendingID)])
        overlay.hide()
        state = .idle
    }

    // MARK: - Undo and re-paste

    var canUndo: Bool { insertions.canUndo }
    var canRevertToVerbatim: Bool { insertions.canRevertToVerbatim }
    var canUndoDictionaryLearning: Bool { !lastLearnedTerms.isEmpty }

    func undoLastDictionaryLearning() {
        guard !lastLearnedTerms.isEmpty else { return }
        let removed = lastLearnedTerms
        Settings.shared.forgetLearnedDictionaryTerms(removed)
        lastLearnedTerms = []
        onDictionaryChange?([])
        overlay.show(phase: .learned("Removed learned spelling"), hint: "")
        overlay.hide(after: .milliseconds(1_500))
    }

    func undoLastInsertion(revertToVerbatim: Bool) async {
        guard insertions.canUndo else { return }
        let didUndo = await insertions.undo(replacingWithVerbatim: revertToVerbatim)
        guard didUndo else { return }

        overlay.show(
            phase: .inserted(0, rewriteFailed: false, submission: .notRequested),
            hint: revertToVerbatim ? "Reverted to what you said" : "Removed")
        overlay.update(phase: .failed(revertToVerbatim ? "Reverted to verbatim" : "Insertion removed"))
        overlay.hide(after: .milliseconds(1_200))
    }

    private func learn(_ candidates: [String]) {
        let added = Settings.shared.learnDictionaryTerms(candidates)
        guard !added.isEmpty else { return }
        lastLearnedTerms = added
        onDictionaryChange?(added)
        let message = added.count == 1
            ? "Learned “\(added[0])” · undo from the menu"
            : "Learned \(added.count) spellings · undo from the menu"
        log.info("learned dictionary spelling", ["count": "\(added.count)"])
        overlay.show(phase: .learned(message), hint: "")
        overlay.hide(after: .seconds(3))
    }

    /// The second-stage instruction for whichever stage this dictation asked for.
    ///
    /// Routed through `secondStageInstruction` rather than reaching for a builder method, so a
    /// translation cannot be sent through the rewrite block by picking the wrong one.
    private func secondStageInstruction(for mode: TranscriptMode) -> String? {
        guard let promptURL = SettingsModel.bundledPromptURL() else { return nil }
        let instruction = try? PromptStore(directory: HistoryStore.defaultDirectory())
            .builder(bundled: promptURL)
            .secondStageInstruction(for: mode, customStyle: Settings.shared.customRewriteStyle)
        return (instruction ?? nil).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// What to ask the transcription request for beside the verbatim transcript, or nil when the
    /// dictation wants nothing but the words.
    private func styledRequest(for mode: TranscriptMode) -> StyledRequest? {
        switch mode {
        case .verbatim, .summary:
            // A summary is never a live mode — the type system stops it reaching here — and
            // verbatim is the absence of a second stage.
            return nil
        case .translate(let language):
            return .translation(language: language)
        case .rewrite(let style):
            guard let promptURL = SettingsModel.bundledPromptURL() else { return nil }
            return (try? PromptStore(directory: HistoryStore.defaultDirectory())
                .builder(bundled: promptURL)
                .styleClause(style, custom: Settings.shared.customRewriteStyle))
                .flatMap { $0.isEmpty ? nil : StyledRequest.style(clause: $0) }
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
            let backend = try? settings.makeProvider(kind, apiKey: key),
            let promptURL = SettingsModel.bundledPromptURL(),
            // Through the store, not the bundle: a fallback that sent the shipped contract while
            // the primary sent an edited one would make the two disagree about the only files
            // that matter, and which one you got would depend on whether the first request timed
            // out.
            let instruction = try? PromptStore(directory: HistoryStore.defaultDirectory())
                .builder(bundled: promptURL)
                .systemInstruction(
                    fidelity: settings.fidelity, script: settings.chineseScript,
                    dictationStyle: settings.dictationStyle,
                    customDictationStyle: settings.customDictationStyle)
        else {
            return FallbackTranscriber(primary: primary)
        }

        return FallbackTranscriber(
            primary: primary,
            secondary: TranscriptionService(
                provider: backend, model: settings.model(for: kind),
                systemInstruction: instruction, fidelity: settings.fidelity,
                keytermBiasing: settings.keytermBiasing,
                personalDictionary: settings.personalDictionaryTerms,
                typography: settings.typographySpacing),
            hedgeAfter: .seconds(settings.fallbackAfterSeconds))
    }

    /// Opens the connection the dictation about to be recorded will need.
    ///
    /// Deliberately not routed through `makeCoordinator()`, which also reads the prompt directory
    /// off disk. Nothing here needs the prompt — only which host the audio is going to — and this
    /// runs on the key-down path.
    ///
    /// Silent on failure by design: nothing has been asked for yet, so there is nothing to report.
    /// A dead connection found here is simply replaced, and the user never learns it happened.
    private func warmUpConnection() {
        let settings = Settings.shared
        guard let key = settings.resolvedAPIKey(), !key.isEmpty,
            let provider = try? settings.makeProvider(settings.provider, apiKey: key),
            let origin = provider.endpointOrigin
        else { return }
        Task { await ProviderTransport.shared.warmUp(origin) }
    }

    private func makeCoordinator() -> RetryCoordinator? {
        let settings = Settings.shared
        guard let key = settings.resolvedAPIKey(), !key.isEmpty,
            let provider = try? settings.makeProvider(settings.provider, apiKey: key),
            let promptURL = SettingsModel.bundledPromptURL(),
            // Same reason as the fallback above: a retry has to reproduce the request, and a
            // request built from a different prompt is not the same request.
            let instruction = try? PromptStore(directory: HistoryStore.defaultDirectory())
                .builder(bundled: promptURL)
                .systemInstruction(
                    fidelity: settings.fidelity, script: settings.chineseScript,
                    dictationStyle: settings.dictationStyle,
                    customDictationStyle: settings.customDictationStyle)
        else { return nil }

        return RetryCoordinator(
            service: TranscriptionService(
                provider: provider, model: settings.model, systemInstruction: instruction,
                fidelity: settings.fidelity, keytermBiasing: settings.keytermBiasing,
                personalDictionary: settings.personalDictionaryTerms,
                typography: settings.typographySpacing),
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

    /// Shows a harmless completed outcome without blocking the next hotkey press.
    private func notice(_ message: String) {
        overlay.update(phase: .notice(message))
        overlay.hide(after: .seconds(3))
        state = .idle
    }
}
