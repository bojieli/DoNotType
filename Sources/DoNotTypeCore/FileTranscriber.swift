import Foundation

/// Transcribes a recording that already exists, rather than one being spoken right now.
///
/// ## Why this is a separate type from the live path
///
/// Live dictation is a latency problem: the user is standing there, the audio is already in the
/// right format, and every decision — pre-upload, hedging, chunk concurrency — exists to shorten
/// the wait. A file on disk is a *throughput* problem. It may be forty minutes long, in a format
/// nothing downstream understands, and nobody is waiting on the first word.
///
/// The two share everything that matters (`TranscriptionService`, the prompt, the chunker, the
/// providers) and differ in what wraps them, which is what this type is: decode, transcribe, and
/// then optionally run the second stage the mode asks for.
///
/// ## The invariant
///
/// The verbatim transcript is produced first and returned alongside whatever was derived from it,
/// always — including for summaries, where the derived text is by definition missing most of what
/// was said. A caller that only wants the summary can ignore `verbatim`; a caller that discards it
/// has made that choice explicitly, which is the whole difference this project is arguing for.
public struct FileTranscriber: Sendable {
    /// What the caller can show while this runs. A forty-minute file is not a spinner.
    public enum Progress: Sendable, Equatable {
        case decoding(String)
        case transcribing(done: Int, of: Int)
        case deriving(TranscriptMode)
    }

    public struct Outcome: Sendable {
        public var sourceURL: URL
        /// Word for word, at the requested fidelity. Always present.
        public var verbatim: String
        /// What the mode produced. Identical to `verbatim` for `.verbatim`.
        public var delivered: String
        public var mode: TranscriptMode
        public var fidelity: Fidelity
        public var language: String
        public var usage: TokenUsage
        /// How many requests the audio was split across.
        public var chunkCount: Int
        public var durationSeconds: Double?
        public var decodeSeconds: Double
        public var transcriptionSeconds: Double
        /// Time in the second stage, when there was one.
        public var secondStageSeconds: Double?
        public var provider: String
        public var model: String
        /// The backend that ran the second stage, when it was not the transcription one.
        public var secondStageProvider: String?

        public var totalSeconds: Double {
            decodeSeconds + transcriptionSeconds + (secondStageSeconds ?? 0)
        }

        /// How much faster than real time the whole thing ran. Nil when the duration is unknown.
        public var realtimeFactor: Double? {
            guard let durationSeconds, durationSeconds > 0 else { return nil }
            return totalSeconds / durationSeconds
        }

        /// A history row for this file, so an offline transcription is searchable next to the
        /// dictations — and so `dnt` and the app agree on what one looks like.
        public func historyRecord() -> DictationRecord {
            DictationRecord(
                status: .completed,
                text: verbatim,
                styledText: mode == .verbatim ? nil : delivered,
                style: mode.rewriteStyle,
                provider: provider,
                model: model,
                fidelity: fidelity,
                durationSeconds: durationSeconds ?? 0,
                latencySeconds: totalSeconds,
                requestSeconds: transcriptionSeconds,
                rewriteSeconds: secondStageSeconds,
                chunkCount: chunkCount,
                usage: usage,
                mode: mode,
                sourceFileName: sourceURL.lastPathComponent)
        }
    }

    /// Transcribes the audio.
    public var service: TranscriptionService
    /// Runs the second stage, when the transcription backend cannot.
    ///
    /// This is what makes `--mode summary --provider xai` work at all: xAI's endpoint is a
    /// recogniser and has no text input, so summarising through it is not a slow path, it is an
    /// impossible one. Pointing the second stage at a model keeps the fast recogniser for the part
    /// it is good at.
    public var secondStage: TranscriptionService?
    public var prompt: PromptBuilder
    public var fidelity: Fidelity

    private let log = Log("file")

    public init(
        service: TranscriptionService,
        prompt: PromptBuilder,
        fidelity: Fidelity = .default,
        secondStage: TranscriptionService? = nil
    ) {
        self.service = service
        self.prompt = prompt
        self.fidelity = fidelity
        self.secondStage = secondStage
    }

    /// The backend that will run the second stage, or nil when nothing available can.
    ///
    /// A recogniser has no text channel, so this is a capability question rather than a preference:
    /// `GroundingSupport.readsSystemInstruction` is exactly "this backend is a language model".
    var textCapableService: TranscriptionService? {
        if let secondStage, secondStage.grounding.readsSystemInstruction { return secondStage }
        if service.grounding.readsSystemInstruction { return service }
        return nil
    }

    /// Whether this configuration can run the given mode at all, checked before any audio is sent.
    ///
    /// Asked up front deliberately. Discovering that a summary is impossible *after* billing forty
    /// minutes of audio would be an expensive way to learn it.
    public func supports(_ mode: TranscriptMode) -> Bool {
        !mode.needsSecondPass || textCapableService != nil
    }

    public func transcribe(
        fileAt url: URL,
        mode: TranscriptMode = .verbatim,
        context: ScreenContext? = nil,
        verifyNumbers: Bool = false,
        attempts: Int = 3,
        maxConcurrent: Int = 3,
        onProgress: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> Outcome {
        guard supports(mode) else {
            throw ProviderError.audioRequired(provider: service.provider.name)
        }

        let name = url.lastPathComponent
        log.info(
            "transcribing file",
            [
                "file": name, "mode": mode.rawValue, "provider": service.provider.name,
                "model": service.model, "fidelity": fidelity.rawValue,
            ])

        onProgress?(.decoding(name))
        let decodeStart = Date()
        let audio = try AudioDecoder.load(url)
        let decodeSeconds = Date().timeIntervalSince(decodeStart)

        let transcribeStart = Date()
        let result = try await service.transcribeLong(
            audio: audio, context: context, attempts: attempts, maxConcurrent: maxConcurrent,
            verifyNumbers: verifyNumbers,
            onProgress: { done, total in onProgress?(.transcribing(done: done, of: total)) })
        let transcriptionSeconds = Date().timeIntervalSince(transcribeStart)

        let verbatim = result.transcript.transcript.trimmed
        log.info(
            "transcribed file",
            [
                "file": name, "chars": "\(verbatim.count)", "chunks": "\(result.chunkCount)",
                "ms": LogClock.ms(transcriptionSeconds),
            ])
        log.content("transcript", verbatim, level: .trace)

        var outcome = Outcome(
            sourceURL: url,
            verbatim: verbatim,
            delivered: verbatim,
            mode: mode,
            fidelity: fidelity,
            language: result.transcript.language,
            usage: result.usage,
            chunkCount: result.chunkCount,
            durationSeconds: audio.durationSeconds,
            decodeSeconds: decodeSeconds,
            transcriptionSeconds: transcriptionSeconds,
            provider: service.provider.name,
            model: service.model)

        // An empty transcript means silence, and there is nothing to rewrite or summarise. Running
        // the second stage anyway would ask a model to write prose from nothing, which is the one
        // way this pipeline could invent words outright.
        guard mode.needsSecondPass, !verbatim.isEmpty else { return outcome }

        guard let instruction = try prompt.secondStageInstruction(for: mode),
            let deriver = textCapableService
        else { return outcome }

        onProgress?(.deriving(mode))
        let deriveStart = Date()
        let derived = try await deriver.rewrite(verbatim, instruction: instruction)
        outcome.secondStageSeconds = Date().timeIntervalSince(deriveStart)
        outcome.delivered = derived
        outcome.secondStageProvider = deriver.provider.name == service.provider.name
            ? nil : deriver.provider.name
        log.info(
            "second stage finished",
            [
                "file": name, "mode": mode.rawValue, "chars": "\(derived.count)",
                "from": "\(verbatim.count)",
                "ms": LogClock.ms(outcome.secondStageSeconds ?? 0),
                "provider": deriver.provider.name,
            ])
        return outcome
    }
}
