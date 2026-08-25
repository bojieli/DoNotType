import Foundation
import OnnxRuntimeBindings

/// Whether a recording contains speech worth sending to a transcription backend.
///
/// This is Silero VAD v6.2.1, not a local approximation. The checked-in ONNX model is evaluated
/// in the upstream 512-sample windows with its recurrent state and 64-sample context carried from
/// one window to the next. Segment detection uses Silero's defaults: 0.5 to begin speech, 0.35 to
/// end it, 100 ms of silence to close a segment and a 250 ms minimum segment.
///
/// Keeping the gate local still matters. A recogniser handed silence may invent a stock sentence,
/// and recogniser APIs have no system instruction that can ask them not to. The difference is that
/// deciding what is speech now belongs to a standard multilingual VAD rather than to thresholds
/// inferred from the recording's own noise floor. The latter discarded continuous speech when the
/// recording contained no quiet section from which to estimate a floor.
public enum SpeechActivity {
    public enum DetectorError: LocalizedError, Sendable {
        case invalidAudio
        case unsupportedSampleRate(Int)
        case unavailable(String)
        case inference(String)

        public var errorDescription: String? {
            switch self {
            case .invalidAudio:
                "The recording is not a 16 kHz mono PCM WAV."
            case .unsupportedSampleRate(let rate):
                "Silero VAD expected 16000 Hz audio, not \(rate) Hz."
            case .unavailable(let detail):
                "Silero VAD could not be loaded: \(detail)"
            case .inference(let detail):
                "Silero VAD could not analyse the recording: \(detail)"
            }
        }
    }

    public struct Reading: Sendable, Equatable {
        /// Duration belonging to Silero-finalised speech segments.
        public let speechMilliseconds: Int
        /// Highest probability returned for any 32 ms window.
        public let maximumProbability: Double
        /// Mean probability over all windows, useful when arguing with a decision from the log.
        public let meanProbability: Double
        public let durationSeconds: Double

        public var hasSpeech: Bool { speechMilliseconds > 0 }

        public var summary: String {
            String(
                format: "silero speech=%dms max=%.3f mean=%.3f of %.2fs",
                speechMilliseconds, maximumProbability, meanProbability, durationSeconds)
        }
    }

    public static let sampleRate = 16_000
    public static let windowSamples = 512
    public static let threshold: Float = 0.5
    public static let negativeThreshold: Float = 0.35
    public static let minimumSpeechMilliseconds = 250
    public static let minimumSilenceMilliseconds = 100

    /// - Parameter pcm: 16 kHz mono 16-bit little-endian samples, without a WAV header.
    public static func measure(pcm: Data, sampleRate: Int = sampleRate) throws -> Reading {
        guard sampleRate == Self.sampleRate else {
            throw DetectorError.unsupportedSampleRate(sampleRate)
        }

        let sampleCount = pcm.count / 2
        let duration = Double(sampleCount) / Double(sampleRate)
        guard sampleCount > 0 else {
            return Reading(
                speechMilliseconds: 0, maximumProbability: 0, meanProbability: 0,
                durationSeconds: duration)
        }

        let model: SileroModel
        switch modelState {
        case .ready(let loaded): model = loaded
        case .failed(let detail): throw DetectorError.unavailable(detail)
        }

        let probabilities: [Float]
        do {
            probabilities = try model.probabilities(pcm: pcm, sampleCount: sampleCount)
        } catch {
            throw DetectorError.inference(error.localizedDescription)
        }

        let speechSamples = finalisedSpeechSamples(
            probabilities: probabilities, audioLengthSamples: sampleCount)
        return Reading(
            speechMilliseconds: Int(
                (Double(speechSamples) * 1_000 / Double(sampleRate)).rounded()),
            maximumProbability: Double(probabilities.max() ?? 0),
            meanProbability: probabilities.isEmpty
                ? 0 : Double(probabilities.reduce(0, +)) / Double(probabilities.count),
            durationSeconds: duration)
    }

    /// - Parameter wav: a 16 kHz mono 16-bit WAV, header and all.
    public static func measure(wav: Data) throws -> Reading {
        guard let body = AudioChunker.pcmBody(of: wav) else { throw DetectorError.invalidAudio }
        return try measure(pcm: body)
    }

    // MARK: - Silero segmentation

    /// The part of upstream `get_speech_timestamps` that decides where final speech is.
    ///
    /// One implementation, used by both the yes/no gate and the boundary finder, because a
    /// segmenter that disagreed with the gate about what counts as speech would cut in places the
    /// gate then refused to send. Padding and maximum-segment splitting do not affect either
    /// caller; preserving the hysteresis and the strict minimum-duration comparison does.
    ///
    /// - Parameter includeOpenSegment: whether a run still open at the end counts. True for a
    ///   finished recording, whose end really is the end. False for a live capture, where the
    ///   speaker has simply not stopped yet and the run's end is not known.
    static func finalisedSpeechSegments(
        probabilities: [Float], audioLengthSamples: Int, includeOpenSegment: Bool = true
    ) -> [Range<Int>] {
        let minimumSpeechSamples = sampleRate * minimumSpeechMilliseconds / 1_000
        let minimumSilenceSamples = sampleRate * minimumSilenceMilliseconds / 1_000
        var speechStart: Int?
        var possibleEnd: Int?
        var segments: [Range<Int>] = []

        for (index, probability) in probabilities.enumerated() {
            let current = windowSamples * index

            if probability >= threshold {
                possibleEnd = nil
                if speechStart == nil { speechStart = current }
                continue
            }

            guard probability < negativeThreshold, let start = speechStart else { continue }
            if possibleEnd == nil { possibleEnd = current }
            guard let end = possibleEnd, current - end >= minimumSilenceSamples else { continue }

            if end - start > minimumSpeechSamples { segments.append(start..<end) }
            speechStart = nil
            possibleEnd = nil
        }

        if includeOpenSegment, let start = speechStart,
            audioLengthSamples - start > minimumSpeechSamples
        {
            segments.append(start..<audioLengthSamples)
        }
        return segments
    }

    private static func finalisedSpeechSamples(
        probabilities: [Float], audioLengthSamples: Int
    ) -> Int {
        finalisedSpeechSegments(
            probabilities: probabilities, audioLengthSamples: audioLengthSamples
        ).reduce(0) { $0 + $1.count }
    }

    // MARK: - Streaming

    /// Silero over a capture that is still running, carrying state instead of re-reading the buffer.
    ///
    /// The live segmenter asks for a boundary every 200 ms once a minute of audio is pending. Doing
    /// that by re-running the model over the whole pending buffer costs about 0.19 s of CPU per
    /// call at 60 seconds pending — roughly a whole core, sustained, for as long as no qualifying
    /// pause appears. Feeding only the new samples costs about 0.6 ms.
    ///
    /// Probabilities are kept for the whole capture rather than trimmed at each cut. One `Float`
    /// per 512 samples is 31 floats a second, so an hour of dictation is under half a megabyte, and
    /// keeping absolute indices means a cut never has to re-align the array against the buffer.
    public final class Stream: @unchecked Sendable {
        private let model: SileroModel
        private var carry: SileroModel.Carry
        /// Samples arrived but not yet a complete 512-sample window.
        private var leftover = Data()
        private var probabilities: [Float] = []
        /// Samples represented by `probabilities`, so callers can index in absolute samples.
        public private(set) var analysedSamples = 0

        public init() throws {
            switch SpeechActivity.modelState {
            case .ready(let loaded): model = loaded
            case .failed(let detail): throw DetectorError.unavailable(detail)
            }
            carry = SileroModel.Carry()
        }

        /// Feeds 16 kHz mono 16-bit PCM. Safe to call with any size, including a partial window.
        public func append(pcm: Data) throws {
            guard !pcm.isEmpty else { return }
            leftover.append(pcm)
            let windowBytes = SpeechActivity.windowSamples * 2
            let complete = leftover.count / windowBytes
            guard complete > 0 else { return }

            let consumed = complete * windowBytes
            let block = leftover.prefix(consumed)
            leftover.removeSubrange(0..<consumed)
            do {
                probabilities.append(
                    contentsOf: try model.probabilities(
                        pcm: Data(block), sampleCount: complete * SpeechActivity.windowSamples,
                        carry: &carry))
            } catch {
                throw DetectorError.inference(error.localizedDescription)
            }
            analysedSamples += complete * SpeechActivity.windowSamples
        }

        /// Finalised speech runs, in absolute sample offsets.
        ///
        /// A run still open at the end of what has been analysed is deliberately excluded: the
        /// speaker has not stopped, so its end is not known yet and nothing may be inferred from it.
        /// - Parameter includingOpenRun: true only when the audio is known to have ended, where
        ///   the last run's end really is its end. False during capture.
        public func speechSegments(includingOpenRun: Bool = false) -> [Range<Int>] {
            SpeechActivity.finalisedSpeechSegments(
                probabilities: probabilities, audioLengthSamples: analysedSamples,
                includeOpenSegment: includingOpenRun)
        }

        /// Boundary candidates in the gaps between finalised speech, relative to `originSample`.
        func pauses(
            from originSample: Int, format: AudioChunker.Format, includingOpenRun: Bool = false
        ) -> [AudioChunker.Pause] {
            SpeechActivity.pauses(
                segments: speechSegments(includingOpenRun: includingOpenRun),
                probabilities: probabilities, from: originSample, format: format)
        }
    }

    /// The gaps between finalised speech runs, as boundary candidates.
    ///
    /// A gap is bounded by two runs that each cleared Silero's 250 ms minimum, so it is flanked by
    /// real speech by construction — the energy finder has to check that separately with a
    /// five-frames-in-two-seconds heuristic.
    ///
    /// `depth` is the model's own confidence that the gap is not speech, scaled to the 0–20 range
    /// the energy finder's decibel depth uses, so one scorer can rank candidates from either source.
    static func pauses(
        segments: [Range<Int>], probabilities: [Float], from originSample: Int,
        format: AudioChunker.Format
    ) -> [AudioChunker.Pause] {
        var out: [AudioChunker.Pause] = []
        for (a, b) in zip(segments, segments.dropFirst()) {
            let gapStart = a.upperBound
            let gapEnd = b.lowerBound
            guard gapEnd > gapStart, gapStart >= originSample else { continue }

            let firstWindow = gapStart / windowSamples
            let lastWindow = max(firstWindow + 1, gapEnd / windowSamples)
            let slice = probabilities[
                min(firstWindow, probabilities.count)..<min(lastWindow, probabilities.count)]
            let meanSpeech = slice.isEmpty ? 0 : Double(slice.reduce(0, +)) / Double(slice.count)

            let middle = (gapStart + gapEnd) / 2 - originSample
            out.append(
                AudioChunker.Pause(
                    cut: middle * 2,
                    seconds: Double(middle) / Double(sampleRate),
                    duration: Double(gapEnd - gapStart) / Double(sampleRate),
                    depth: (1 - meanSpeech) * 20))
        }
        return out
    }

    // MARK: - Model lifetime

    private enum ModelState: @unchecked Sendable {
        case ready(SileroModel)
        case failed(String)
    }

    private static let modelState: ModelState = {
        do { return .ready(try SileroModel()) }
        catch { return .failed(error.localizedDescription) }
    }()
}

/// One immutable ONNX session shared by measurements. Each invocation owns its recurrent state and
/// context, and ONNX Runtime sessions support concurrent `run` calls.
private final class SileroModel: @unchecked Sendable {
    private let session: ORTSession

    init() throws {
        guard let modelURL = Bundle.module.url(forResource: "silero_vad", withExtension: "onnx")
        else { throw SpeechActivity.DetectorError.unavailable("silero_vad.onnx is missing") }

        let environment = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        try options.setIntraOpNumThreads(1)
        session = try ORTSession(
            env: environment, modelPath: modelURL.path, sessionOptions: options)
    }

    func probabilities(pcm: Data, sampleCount: Int) throws -> [Float] {
        var carry = Carry()
        return try probabilities(pcm: pcm, sampleCount: sampleCount, carry: &carry)
    }

    /// The recurrent state Silero carries from one 512-sample window to the next.
    ///
    /// Split out so a live capture can keep feeding the same session instead of re-running the
    /// model over the whole buffer on every tick. Upstream's own streaming mode is exactly this:
    /// the state and the 64-sample context are the entire history the model needs.
    struct Carry {
        var state = [Float](repeating: 0, count: 2 * 128)
        var context = [Float](repeating: 0, count: 64)
    }

    func probabilities(pcm: Data, sampleCount: Int, carry: inout Carry) throws -> [Float] {
        try pcm.withUnsafeBytes { raw in
            var state = carry.state
            var context = carry.context
            defer {
                carry.state = state
                carry.context = context
            }
            var probabilities: [Float] = []
            probabilities.reserveCapacity(
                (sampleCount + SpeechActivity.windowSamples - 1)
                    / SpeechActivity.windowSamples)

            for offset in stride(from: 0, to: sampleCount, by: SpeechActivity.windowSamples) {
                var input = [Float](repeating: 0, count: 64 + SpeechActivity.windowSamples)
                input.replaceSubrange(0..<64, with: context)
                let count = min(SpeechActivity.windowSamples, sampleCount - offset)
                for index in 0..<count {
                    let value = raw.loadUnaligned(
                        fromByteOffset: (offset + index) * MemoryLayout<Int16>.size,
                        as: Int16.self)
                    input[64 + index] = Float(Int16(littleEndian: value)) / 32_768
                }

                let outputs = try session.run(
                    withInputs: [
                        "input": tensor(input, shape: [1, 576], type: .float),
                        "state": tensor(state, shape: [2, 1, 128], type: .float),
                        "sr": tensor(
                            [Int64(SpeechActivity.sampleRate)], shape: [], type: .int64),
                    ],
                    outputNames: ["output", "stateN"], runOptions: nil)

                guard let output = outputs["output"], let nextState = outputs["stateN"] else {
                    throw SpeechActivity.DetectorError.inference("the model returned no output")
                }
                probabilities.append(try floats(from: output, count: 1)[0])
                state = try floats(from: nextState, count: 2 * 128)
                context = Array(input.suffix(64))
            }
            return probabilities
        }
    }

    private func tensor<T>(
        _ values: [T], shape: [NSNumber], type: ORTTensorElementDataType
    ) throws -> ORTValue {
        let data = values.withUnsafeBytes { bytes in
            NSMutableData(bytes: bytes.baseAddress, length: bytes.count)
        }
        return try ORTValue(tensorData: data, elementType: type, shape: shape)
    }

    private func floats(from value: ORTValue, count: Int) throws -> [Float] {
        let data = try value.tensorData()
        let byteCount = count * MemoryLayout<Float>.size
        guard data.length >= byteCount else {
            throw SpeechActivity.DetectorError.inference(
                "the model returned \(data.length) bytes, expected \(byteCount)")
        }
        var result = [Float](repeating: 0, count: count)
        result.withUnsafeMutableBytes { bytes in
            data.getBytes(bytes.baseAddress!, length: byteCount)
        }
        return result
    }
}
