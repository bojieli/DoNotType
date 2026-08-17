import Foundation

/// Transcribes VAD-finalised parts while their recording is still being captured.
///
/// `LiveAudioPipeline` is the synchronous edge used by real-time audio callbacks. Its unbounded
/// stream preserves every PCM buffer and one worker feeds them, in order, to the actor. The actor
/// owns segmentation and request tasks; release closes the stream, submits the tail, and stitches
/// results by part index rather than completion order.
public final class LiveAudioPipeline: @unchecked Sendable {
    private let continuation: AsyncStream<Data>.Continuation
    private let worker: Task<Void, Never>
    public let session: LiveTranscriptionSession

    public init(session: LiveTranscriptionSession) {
        self.session = session
        let pair = AsyncStream<Data>.makeStream()
        continuation = pair.continuation
        worker = Task {
            for await pcm in pair.stream {
                await session.append(pcm: pcm)
            }
        }
    }

    /// Safe to call from a microphone callback. `yield` copies no shared mutable state and returns
    /// immediately; VAD and networking run away from the real-time audio thread.
    public func append(pcm: Data) {
        continuation.yield(pcm)
    }

    public func finish() async throws -> FallbackTranscriber.Outcome {
        continuation.finish()
        await worker.value
        return try await session.finish()
    }

    public func cancel() {
        continuation.finish()
        worker.cancel()
        Task { await session.cancel() }
    }
}

public actor LiveTranscriptionSession {
    private let transcriber: FallbackTranscriber
    private var context: ScreenContext?
    private let permits: AsyncPermitPool
    private var segmenter: AudioChunker.StreamingSegmenter
    private var tasks: [Int: Task<FallbackTranscriber.Outcome?, any Error>] = [:]
    private var isFinished = false
    private var isCancelled = false

    public init(
        transcriber: FallbackTranscriber,
        context: ScreenContext?,
        maxConcurrent: Int = 3,
        format: AudioChunker.Format = AudioChunker.Format(),
        policy: AudioChunker.BoundaryPolicy = AudioChunker.defaultPolicy
    ) {
        self.transcriber = transcriber
        self.context = context
        permits = AsyncPermitPool(count: max(1, maxConcurrent))
        segmenter = AudioChunker.StreamingSegmenter(format: format, policy: policy)
    }

    public func append(pcm: Data) {
        guard !isFinished, !isCancelled else { return }
        for chunk in segmenter.append(pcm: pcm) { submit(chunk) }
    }

    /// Grounding finishes asynchronously near the start of capture. It is set long before the
    /// first possible 90-second emission, without making hotkey-down wait for a screen walk.
    public func setContext(_ context: ScreenContext?) {
        self.context = context
    }

    public func finish() async throws -> FallbackTranscriber.Outcome {
        guard !isCancelled else { throw CancellationError() }
        if !isFinished {
            isFinished = true
            if let tail = segmenter.finish() { submit(tail) }
        }

        var outcomes: [FallbackTranscriber.Outcome] = []
        do {
            for index in tasks.keys.sorted() {
                if let outcome = try await tasks[index]?.value { outcomes.append(outcome) }
            }
        } catch {
            for task in tasks.values { task.cancel() }
            throw error
        }

        let pieces = outcomes.map(\.result)
        let result = TranscriptionResult(
            transcript: Transcript(
                transcript: AudioChunker.stitch(pieces.map(\.transcript.transcript)),
                language: pieces.first?.transcript.language ?? ""),
            usage: pieces.map(\.usage).reduce(TokenUsage(), +),
            rawOutput: pieces.map(\.rawOutput).joined(separator: "\n"),
            chunkCount: pieces.count)
        return FallbackTranscriber.Outcome(
            result: result, attribution: combinedAttribution(outcomes))
    }

    public func cancel() {
        isCancelled = true
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
    }

    private func submit(_ chunk: AudioChunker.Chunk) {
        let transcriber = self.transcriber
        let context = self.context
        let permits = self.permits
        tasks[chunk.index] = Task {
            let activity = SpeechActivity.measure(wav: chunk.data)
            guard activity.hasSpeech else { return nil }

            await permits.acquire()
            do {
                let outcome = try await transcriber.transcribe(
                    audio: AudioFile(data: chunk.data, mimeType: "audio/wav"), context: context)
                await permits.release()
                return outcome
            } catch {
                await permits.release()
                throw error
            }
        }
    }

    private func combinedAttribution(
        _ outcomes: [FallbackTranscriber.Outcome]
    ) -> FallbackTranscriber.Attribution {
        guard !outcomes.isEmpty else {
            return FallbackTranscriber.Attribution(
                provider: transcriber.primary.provider.name,
                model: transcriber.primary.model,
                wasFallback: false)
        }
        let providers = outcomes.map(\.attribution.provider).reduce(into: [String]()) {
            if !$0.contains($1) { $0.append($1) }
        }
        let models = outcomes.map(\.attribution.model).reduce(into: [String]()) {
            if !$0.contains($1) { $0.append($1) }
        }
        return FallbackTranscriber.Attribution(
            provider: providers.joined(separator: " + "),
            model: models.joined(separator: " + "),
            wasFallback: outcomes.contains { $0.attribution.wasFallback })
    }
}

private actor AsyncPermitPool {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(count: Int) { available = count }

    func acquire() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            available += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}
