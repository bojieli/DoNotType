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
            case .missingAPIKey, .audioSilentlyDropped:
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

    public init(
        provider: any TranscriptionProvider,
        model: String,
        systemInstruction: String,
        encoder: ContextEncoder = ContextEncoder()
    ) {
        self.provider = provider
        self.model = model
        self.systemInstruction = systemInstruction
        self.encoder = encoder
    }

    /// - Parameter audioPart: overrides how the recording is carried, so a caller that
    ///   pre-uploaded it can pass a URI reference instead of the bytes. Defaults to inline.
    public func transcribe(
        audio: AudioFile, context: ScreenContext?, audioPart: InputPart? = nil
    ) async throws -> TranscriptionResult {
        var parts: [InputPart] = []
        if let context, !context.isEmpty {
            parts.append(contentsOf: encoder.encode(context))
        }
        parts.append(audioPart ?? audio.part)

        return try await provider.transcribe(
            TranscriptionRequest(
                model: model, systemInstruction: systemInstruction, parts: parts))
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
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
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
