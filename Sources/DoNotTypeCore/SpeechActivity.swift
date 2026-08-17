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

    /// The part of upstream `get_speech_timestamps` that decides whether final speech exists.
    /// Padding and maximum-segment splitting do not affect this gate, which needs duration rather
    /// than timestamps; preserving the hysteresis and strict minimum-duration comparison does.
    private static func finalisedSpeechSamples(
        probabilities: [Float], audioLengthSamples: Int
    ) -> Int {
        let minimumSpeechSamples = sampleRate * minimumSpeechMilliseconds / 1_000
        let minimumSilenceSamples = sampleRate * minimumSilenceMilliseconds / 1_000
        var speechStart: Int?
        var possibleEnd: Int?
        var total = 0

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

            if end - start > minimumSpeechSamples { total += end - start }
            speechStart = nil
            possibleEnd = nil
        }

        if let start = speechStart, audioLengthSamples - start > minimumSpeechSamples {
            total += audioLengthSamples - start
        }
        return total
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
        try pcm.withUnsafeBytes { raw in
            var state = [Float](repeating: 0, count: 2 * 128)
            var context = [Float](repeating: 0, count: 64)
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
