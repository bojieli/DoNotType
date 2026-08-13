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
        let result = try await provider.transcribe(
            TranscriptionRequest(
                model: model, systemInstruction: instruction, parts: [.text(transcript)]))
        let rewritten = result.transcript.transcript.trimmed
        // A rewrite that comes back empty is a failure of the rewrite, not of the dictation.
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

    public init(
        provider: any TranscriptionProvider,
        model: String,
        systemInstruction: String,
        encoder: ContextEncoder = ContextEncoder(),
        fidelity: Fidelity = .default,
        keytermBiasing: Bool = false
    ) {
        self.provider = provider
        self.model = model
        self.systemInstruction = systemInstruction
        self.encoder = encoder
        self.fidelity = fidelity
        self.keytermBiasing = keytermBiasing
    }

    /// What this service's backend can actually do with the screen, for callers that need to say
    /// so out loud — the settings panel, and the history row that records whether a dictation was
    /// grounded.
    public var grounding: GroundingSupport { provider.grounding(forModel: model) }

    /// - Parameter audioPart: overrides how the recording is carried, so a caller that
    ///   pre-uploaded it can pass a URI reference instead of the bytes. Defaults to inline.
    public func transcribe(
        audio: AudioFile, context: ScreenContext?, audioPart: InputPart? = nil
    ) async throws -> TranscriptionResult {
        var parts: [InputPart] = []
        var keyterms: [String] = []

        // Each backend is sent only what it can use. Encoding ten thousand characters of screen
        // text for an endpoint that accepts a raw audio body would not merely be wasted — it would
        // put a "grounded" request in the history for a transcript produced without grounding.
        switch provider.grounding(forModel: model) {
        case .multimodal:
            if let context, !context.isEmpty {
                parts.append(contentsOf: encoder.encode(context))
            }
        case .keyterms(let maxTerms, let maxCharsPerTerm):
            if keytermBiasing, let context, !context.isEmpty {
                keyterms = Keyterms.derive(
                    from: context, maxTerms: maxTerms, maxCharsPerTerm: maxCharsPerTerm)
            }
        case .none:
            break
        }

        // Compressed unless the caller already resolved the audio to a pre-uploaded reference.
        parts.append(audioPart ?? audio.compressedForUpload().part)

        return try await provider.transcribe(
            TranscriptionRequest(
                model: model, systemInstruction: systemInstruction, parts: parts,
                fidelity: fidelity, keyterms: keyterms))
    }

    /// Retries with exponential backoff, giving up early on errors that will not change.
    ///
    /// A pre-uploaded reference is used for the first attempt only. If that fails the retries fall
    /// back to inline bytes, because a URI that failed once may be the thing that is broken —
    /// an expired file, a half-finalised upload — and re-sending it would fail identically.
    public func transcribeWithRetry(
        audio: AudioFile,
        context: ScreenContext?,
        audioPart: InputPart? = nil,
        attempts: Int = 3,
        initialDelay: Duration = .milliseconds(600)
    ) async throws -> TranscriptionResult {
        var delay = initialDelay
        var lastError: any Error = ProviderError.emptyOutput
        var part = audioPart

        for attempt in 1...max(1, attempts) {
            do {
                return try await transcribe(audio: audio, context: context, audioPart: part)
            } catch {
                lastError = error
                guard attempt < attempts, Self.isTransient(error) else { throw error }
                part = nil  // fall back to inline for every subsequent attempt
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
    public func transcribeLong(
        audio: AudioFile,
        context: ScreenContext?,
        audioPart: InputPart? = nil,
        attempts: Int = 3,
        maxConcurrent: Int = 3,
        verifyNumbers: Bool = false,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> TranscriptionResult {
        // The second, ungrounded run only means something when the first one was grounded. A
        // recognition backend never sees the screen, and `Keyterms` cannot emit a digit, so there
        // is no screen-derived number for the check to catch — it would just bill the audio twice
        // and compare a run against itself.
        guard verifyNumbers, grounding == .multimodal, let context, !context.isEmpty else {
            return try await transcribeSplitting(
                audio: audio, context: context, audioPart: audioPart, attempts: attempts,
                maxConcurrent: maxConcurrent, onProgress: onProgress)
        }

        // Grounded and audio-only together. The audio-only run cannot have seen the screen, so its
        // digit sequences are the ones to trust — measured at 8% substitution against 58% for the
        // grounded run alone on the reference clip.
        //
        // Issued concurrently, but measurement says that does *not* make it free: the two requests
        // contend for the same upload and the pair takes roughly twice as long as one. Which is
        // why this is opt-in rather than the default.
        async let grounded = transcribeSplitting(
            audio: audio, context: context, audioPart: audioPart, attempts: attempts,
            maxConcurrent: maxConcurrent, onProgress: onProgress)
        async let audioOnly = transcribeSplitting(
            audio: audio, context: nil, audioPart: nil, attempts: attempts,
            maxConcurrent: maxConcurrent, onProgress: nil)

        var result = try await grounded
        // A failed verification pass must never cost the user their transcript: the grounded run
        // already succeeded, and its numbers being unverified is better than no text at all.
        guard let checked = try? await audioOnly else { return result }

        let reconciled = NumericGuard.reconcile(
            grounded: result.transcript.transcript,
            audioOnly: checked.transcript.transcript)
        result.transcript.transcript = reconciled.text
        result.usage = result.usage + checked.usage
        return result
    }

    private func transcribeSplitting(
        audio: AudioFile,
        context: ScreenContext?,
        audioPart: InputPart?,
        attempts: Int,
        maxConcurrent: Int,
        onProgress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> TranscriptionResult {
        let chunks = AudioChunker.split(wav: audio.data)
        guard chunks.count > 1 else {
            return try await transcribeWithRetry(
                audio: audio, context: context, audioPart: audioPart, attempts: attempts)
        }

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
