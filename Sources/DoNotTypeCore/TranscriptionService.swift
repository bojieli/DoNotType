import Foundation

/// One place where a dictation becomes a transcript, whether it is the first attempt or the
/// fourth.
///
/// The point of routing retries through the same function as first attempts is that a retried
/// dictation is not a lesser one: it uses the stored screen context, the stored fidelity and the
/// stored audio, so the result is what the original request would have produced had the network
/// held.
public struct TranscriptionService: Sendable {
    /// Rewrites a finished transcript. Text in, text out — no audio, no screen context.
    ///
    /// Deliberately a separate call rather than an instruction folded into transcription. The two
    /// are different jobs with different failure modes, and measurement bears that out: the
    /// combined request was the slower of the two (15.7 s versus 7.5 s) because one call doing
    /// both emits far more output. Keeping them apart also means the verbatim transcript exists
    /// before anything is done to it, which is what makes "revert to what I said" possible.
    public func rewrite(_ transcript: String, instruction: String) async throws -> String {
        guard !transcript.trimmed.isEmpty else { return transcript }
        let started = Date()
        let result = try await provider.transcribe(
            TranscriptionRequest(
                model: model, systemInstruction: instruction, parts: [.text(transcript)]))
        let rewritten = result.transcript.transcript.trimmed
        Self.log.debug(
            "second stage",
            [
                "provider": provider.name, "model": model, "in": "\(transcript.count)",
                "out": "\(rewritten.count)", "ms": LogClock.ms(Date().timeIntervalSince(started)),
            ])
        // A rewrite that comes back empty is a failure of the rewrite, not of the dictation.
        if rewritten.isEmpty {
            Self.log.warning(
                "second stage returned nothing; keeping the transcript",
                ["provider": provider.name, "model": model])
        }
        return rewritten.isEmpty ? transcript : rewritten
    }

    /// Errors worth retrying automatically, as opposed to ones that will fail identically forever.
    ///
    /// A 401 is not a network blip and retrying it just burns the user's time; a 503 or a dropped
    /// connection is exactly what retry exists for.
    public static func isTransient(_ error: any Error) -> Bool {
        if let providerError = error as? ProviderError {
            switch providerError {
            case .http(let status, _):
                return status == 408 || status == 429 || (500...599).contains(status)
            case .missingAPIKey, .audioSilentlyDropped, .audioRequired:
                return false
            case .malformedResponse, .emptyOutput:
                return true
            }
        }
        let code = (error as NSError).code
        return [
            NSURLErrorTimedOut, NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost,
            NSURLErrorNotConnectedToInternet, NSURLErrorDNSLookupFailed,
            NSURLErrorResourceUnavailable, NSURLErrorSecureConnectionFailed,
        ].contains(code)
    }

    static let log = Log("transcribe")

    public var provider: any TranscriptionProvider
    public var model: String
    public var systemInstruction: String
    public var encoder: ContextEncoder
    /// Passed through to backends that have no system instruction to read it from. Model
    /// providers ignore it, having received the same setting baked into `systemInstruction`.
    public var fidelity: Fidelity
    /// Whether to derive a keyterm list from the screen for recognition backends.
    ///
    /// Off by default, and that default is a position rather than caution about a new feature.
    /// Keyterm biasing is a vocabulary prior — the mechanism the README singles out as the thing
    /// that makes a dictation tool overrule clear audio — and it arrives without the "reference
    /// only" framing that makes the same information safe to give a model. `Keyterms` refuses to
    /// emit anything containing a digit for that reason, but the residual risk on names is real.
    /// Measured in `docs/EVALUATION.md`.
    public var keytermBiasing: Bool
    /// Spellings the user deliberately supplied. Unlike `keytermBiasing`, this never derives a
    /// prior from whatever happened to be on screen and is therefore useful even with grounding
    /// off. Model providers receive a reference-only request part; recognition providers receive
    /// the subset safe for their bare keyterm channel.
    public var personalDictionary: [String]
    /// Whether a request that has stalled is joined by a second identical one, the faster of the
    /// two winning. See `StallHedge` for what counts as stalled and why this is not a timeout.
    ///
    /// On by default, because the tail it exists for is the single worst thing about dictating
    /// through a network. Off for measurement: a benchmark that reports the better of two draws is
    /// not reporting the backend's latency.
    public var hedgeStalledRequests: Bool

    public init(
        provider: any TranscriptionProvider,
        model: String,
        systemInstruction: String,
        encoder: ContextEncoder = ContextEncoder(),
        fidelity: Fidelity = .default,
        keytermBiasing: Bool = false,
        personalDictionary: [String] = [],
        hedgeStalledRequests: Bool = true
    ) {
        self.provider = provider
        self.model = model
        self.systemInstruction = systemInstruction
        self.encoder = encoder
        self.fidelity = fidelity
        self.keytermBiasing = keytermBiasing
        self.personalDictionary = PersonalDictionary.sanitized(personalDictionary)
        self.hedgeStalledRequests = hedgeStalledRequests
    }

    /// What this service's backend can actually do with the screen, for callers that need to say
    /// so out loud — the settings panel, and the history row that records whether a dictation was
    /// grounded.
    public var grounding: GroundingSupport { provider.grounding(forModel: model) }

    public func transcribe(
        audio: AudioFile, context: ScreenContext?,
        connection: ConnectionPreference = .pooled
    ) async throws -> TranscriptionResult {
        var parts: [InputPart] = []
        var keyterms: [String] = []

        // Each backend is sent only what it can use. Encoding ten thousand characters of screen
        // text for an endpoint that accepts a raw audio body would not merely be wasted — it would
        // put a "grounded" request in the history for a transcript produced without grounding.
        switch provider.grounding(forModel: model) {
        case .multimodal:
            if let dictionary = PersonalDictionary.referenceBlock(terms: personalDictionary) {
                parts.append(.text(dictionary))
            }
            if let context, !context.isEmpty {
                parts.append(contentsOf: encoder.encode(context))
            }
        case .keyterms(let maxTerms, let maxCharsPerTerm):
            var derived: [String] = []
            if keytermBiasing, let context, !context.isEmpty {
                derived = Keyterms.derive(
                    from: context, maxTerms: maxTerms, maxCharsPerTerm: maxCharsPerTerm)
            }
            keyterms = PersonalDictionary.mergingKeyterms(
                dictionary: personalDictionary, derived: derived, maxTerms: maxTerms,
                maxCharactersPerTerm: maxCharsPerTerm)
        case .none:
            break
        }

        // Compressed here rather than at the call site, so every backend gets it: measured at
        // 960 kB down to 60 kB for thirty seconds of speech.
        let payload = audio.compressedForUpload().part
        parts.append(payload)

        // The routing decision, recorded before the request rather than inferred from the result.
        // "Was this grounded?" has been answered wrongly from a transcript more than once, and it
        // is not answerable at all from the response.
        Self.log.debug(
            "transcribing",
            [
                "provider": provider.name, "model": model,
                "grounding": describe(provider.grounding(forModel: model)),
                "context": context?.isEmpty == false ? "yes" : "no",
                "dictionary": "\(personalDictionary.count)",
                "keyterms": "\(keyterms.count)",
                "fidelity": fidelity.rawValue,
                "audio": payload.description,
                "connection": connection == .fresh ? "fresh" : "pooled",
            ])

        let started = Date()
        var result = try await provider.transcribe(
            TranscriptionRequest(
                model: model, systemInstruction: systemInstruction, parts: parts,
                fidelity: fidelity, keyterms: keyterms, connection: connection))
        Self.log.debug(
            "transcribed",
            [
                "provider": provider.name, "chars": "\(result.transcript.transcript.count)",
                "audioTokens": result.usage.audioTokens.map(String.init) ?? "unreported",
                "ms": LogClock.ms(Date().timeIntervalSince(started)),
            ])

        // Here rather than at the call site, because every backend and every caller — dictation,
        // file transcription, retry, the eval harness — comes through this one method, and a guard
        // that some of them skip is a guard that will be skipped by the one that matters.
        //
        // The duration comes from `audio`, not from the compressed payload: `compressedForUpload`
        // produces Opus, whose length is not readable without decoding it.
        let (checked, verdict) = HallucinationGuard.inspect(
            result.transcript, audioSeconds: audio.durationSeconds)
        if verdict != .kept {
            // Warning, not debug: text the user never said was about to be typed into whatever
            // they had focused, and the whole measurement goes in the line so the threshold can be
            // argued with from the log alone.
            Self.log.warning(
                "transcript discarded — the audio cannot contain it",
                [
                    "provider": provider.name, "model": model,
                    "reason": verdict.summary,
                ])
            // The words themselves only under the content flag, like every other transcript.
            Self.log.content("discarded transcript", result.transcript.transcript)
            result.transcript = checked
            result.suppressed = verdict
        }
        return result
    }

    private func describe(_ support: GroundingSupport) -> String {
        switch support {
        case .multimodal: "multimodal"
        case .keyterms: "keyterms"
        case .none: "none"
        }
    }

    /// One request, joined by a second identical one if it stalls — see `StallHedge`.
    ///
    /// Wrapped here rather than around `transcribe` itself so that the retry ladder below sees a
    /// single attempt: a stall and a failure are different problems with different remedies, and a
    /// request that stalled three times should still get its three tries at *failing*.
    ///
    /// The duration comes from the audio this call was handed, which for a split recording is one
    /// chunk rather than the whole dictation. That is the right denominator — a chunk is what the
    /// request is being asked to transcribe.
    private func hedgedAttempt(
        audio: AudioFile, context: ScreenContext?,
        connection: ConnectionPreference = .pooled
    ) async throws -> TranscriptionResult {
        guard hedgeStalledRequests else {
            return try await transcribe(audio: audio, context: context, connection: connection)
        }

        let deadline = StallHedge.deadlineSeconds(audioSeconds: audio.durationSeconds)
        let providerName = provider.name
        let modelName = model
        return try await StallHedge.race(
            deadlineSeconds: deadline,
            onHedge: {
                // Info, not debug: this is the app spending a second request on the user's behalf.
                // A hedge that fires on every dictation is a backend having a bad day rather than a
                // working feature, and that should be visible without turning anything on.
                Self.log.info(
                    "request stalled; sending a second one",
                    [
                        "provider": providerName, "model": modelName,
                        "after": String(format: "%.1fs", deadline),
                    ])
            },
            // The duplicate goes out on a connection of its own. On the same one it is not a
            // second draw — it is a second stream on whatever the original is stuck behind, which
            // is how this feature came to fire three times and lose three times. See `StallHedge`.
            attempt: { isHedge in
                try await transcribe(
                    audio: audio, context: context,
                    connection: isHedge ? .fresh : connection)
            })
    }

    /// Retries with exponential backoff, giving up early on errors that will not change.
    public func transcribeWithRetry(
        audio: AudioFile,
        context: ScreenContext?,
        attempts: Int = 3,
        initialDelay: Duration = .milliseconds(600)
    ) async throws -> TranscriptionResult {
        var delay = initialDelay
        var lastError: any Error = ProviderError.emptyOutput

        for attempt in 1...max(1, attempts) {
            do {
                // Every attempt after the first opens its own connection. The one it would
                // otherwise reuse is the one that just failed, and in this app's measured history
                // that is the whole reason a retry succeeds: all sixteen slow dictations finished
                // in 2–6 s once the request went out on a new connection. Before this it happened
                // by luck — the failure had made URLSession discard the dead connection — rather
                // than because anything asked for it.
                return try await hedgedAttempt(
                    audio: audio, context: context,
                    connection: attempt == 1 ? .pooled : .fresh)
            } catch {
                lastError = error
                guard attempt < attempts, Self.isTransient(error) else {
                    // Why it stopped, which is the difference between "the network is bad" and
                    // "your key is wrong" — indistinguishable from the failed dictation alone.
                    Self.log.warning(
                        "giving up",
                        [
                            "attempt": "\(attempt)", "of": "\(attempts)",
                            "transient": Self.isTransient(error) ? "yes" : "no",
                            "error": error.localizedDescription,
                        ])
                    throw error
                }
                Self.log.info(
                    "retrying",
                    [
                        "attempt": "\(attempt)", "of": "\(attempts)",
                        "backoff": "\(delay)", "error": error.localizedDescription,
                    ])
                try? await Task.sleep(for: delay)
                delay = delay * 2
            }
        }
        throw lastError
    }

    /// Transcribes a recording of any length, splitting long ones across concurrent requests.
    ///
    /// A nine-minute dictation is roughly 17,000 audio tokens in one request, and the user is
    /// sitting there waiting after they have already stopped talking. Splitting on silence turns
    /// the wait into roughly the slowest chunk rather than the sum of all of them.
    ///
    /// Every chunk carries the *same* screen context. That is what stops chunk three spelling a
    /// name differently from chunk two — a real risk, since each request is independent and has no
    /// idea what the others produced.
    ///
    /// Short recordings take the ordinary single-request path untouched, so this is safe to call
    /// unconditionally.
    ///
    /// One request per chunk, and never more than that. A dictation used to be able to cost two
    /// full requests — a grounded one and a screen-blind one whose digits were spliced back in —
    /// and that is gone. It treated a symptom of grounding by buying a second opinion, and the
    /// bill was the wrong shape: the wait became the *slower* of two draws from a latency
    /// distribution whose tail is the whole problem. Measured on this machine, a single request
    /// ran 8.9 s at the median and 21 s at p90; waiting on the slower of two moved p90 to 37 s.
    /// A number the model got wrong is a prompt and grounding problem, to be fixed where it is
    /// caused rather than voted on afterwards.
    public func transcribeLong(
        audio: AudioFile,
        context: ScreenContext?,
        attempts: Int = 3,
        maxConcurrent: Int = 3,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> TranscriptionResult {
        let chunks = AudioChunker.split(wav: audio.data)
        guard chunks.count > 1 else {
            return try await transcribeWithRetry(
                audio: audio, context: context, attempts: attempts)
        }

        Self.log.info(
            "split recording",
            [
                "chunks": "\(chunks.count)", "concurrency": "\(maxConcurrent)",
                "seconds": String(
                    format: "%.0f", chunks.reduce(0) { $0 + $1.durationSeconds }),
            ])

        var results = [TranscriptionResult?](repeating: nil, count: chunks.count)
        var finished = 0

        // Bounded concurrency: a ten-minute dictation is ten simultaneous requests otherwise,
        // which is the fastest way to hit a rate limit and turn a slow dictation into a failed one.
        try await withThrowingTaskGroup(of: (Int, TranscriptionResult).self) { group in
            var next = 0
            func submit() {
                guard next < chunks.count else { return }
                let chunk = chunks[next]
                next += 1
                group.addTask {
                    let piece = AudioFile(data: chunk.data, mimeType: "audio/wav")
                    let result = try await transcribeWithRetry(
                        audio: piece, context: context, attempts: attempts)
                    return (chunk.index, result)
                }
            }

            for _ in 0..<min(maxConcurrent, chunks.count) { submit() }
            while let (index, result) = try await group.next() {
                results[index] = result
                finished += 1
                onProgress?(finished, chunks.count)
                submit()
            }
        }

        let pieces = results.compactMap { $0 }
        return TranscriptionResult(
            transcript: Transcript(
                transcript: AudioChunker.stitch(pieces.map(\.transcript.transcript)),
                language: pieces.first?.transcript.language ?? ""),
            usage: pieces.map(\.usage).reduce(TokenUsage(), +),
            rawOutput: pieces.map(\.rawOutput).joined(separator: "\n"),
            chunkCount: pieces.count)
    }
}

/// Drains everything that failed while the network was down.
///
/// Deliberately sequential: a user coming back online after an hour may have a dozen pending
/// dictations, and firing them concurrently is the fastest way to hit a rate limit and turn a
/// recoverable backlog into a stuck one.
public struct RetryCoordinator: Sendable {
    public struct Outcome: Sendable {
        public var succeeded: [UUID] = []
        public var failed: [(id: UUID, error: String)] = []
        public var isEmpty: Bool { succeeded.isEmpty && failed.isEmpty }
    }

    public var service: TranscriptionService
    public var store: HistoryStore

    public init(service: TranscriptionService, store: HistoryStore) {
        self.service = service
        self.store = store
    }

    /// Retries a single record and writes the result back to the store.
    @discardableResult
    public func retry(_ record: DictationRecord) async -> Result<String, any Error> {
        var updated = record
        updated.retryCount += 1

        do {
            let audio = try await store.audioFile(for: record)
            let result = try await service.transcribe(audio: audio, context: record.context)
            let text = result.transcript.transcript
                .trimmingCharacters(in: .whitespacesAndNewlines)

            updated.status = .completed
            updated.text = text
            updated.errorMessage = nil
            await store.update(updated)
            return .success(text)
        } catch {
            updated.status = .failed
            updated.errorMessage = error.localizedDescription
            await store.update(updated)
            return .failure(error)
        }
    }

    public func retryAll() async -> Outcome {
        var outcome = Outcome()
        for record in await store.retryable() {
            switch await retry(record) {
            case .success: outcome.succeeded.append(record.id)
            case .failure(let error):
                outcome.failed.append((record.id, error.localizedDescription))
            }
        }
        return outcome
    }
}
