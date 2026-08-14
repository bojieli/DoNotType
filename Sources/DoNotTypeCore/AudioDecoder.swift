import AVFoundation
import Foundation

/// Turns a recording of any format into the 16 kHz mono WAV the rest of the pipeline assumes.
///
/// Live dictation never needed this: `AudioRecorder` captures at 16 kHz mono and hands over PCM
/// already in the right shape. Transcribing a *file* is different — what people have on disk is a
/// voice memo (`.m4a`), a meeting recording (`.mp3`), or a 48 kHz stereo WAV out of some other
/// tool, and every one of those breaks something downstream:
///
/// - `AudioChunker` reads a 16 kHz mono PCM body, so a compressed file is one unsplittable chunk
///   however long it is. A 40-minute recording would go out as a single request.
/// - `AudioFile.durationSeconds` returns nil for anything but WAV, so the history row records a
///   zero-length dictation.
/// - `OpusEncoder` takes 16 kHz mono PCM in, so the upload would not be compressed either.
///
/// Decoding once at the front fixes all three, and costs a pass over the file at far faster than
/// real time. A file that is already 16 kHz mono 16-bit WAV skips this entirely and keeps its exact
/// bytes.
public enum AudioDecoder {
    public enum DecodeError: LocalizedError {
        case unreadable(name: String, detail: String)
        case unsupportedFormat(name: String)
        case conversionFailed(String)
        case empty(name: String)

        public var errorDescription: String? {
            switch self {
            case .unreadable(let name, let detail):
                "Could not read \(name): \(detail). Supported: WAV, MP3, M4A/AAC, AIFF, FLAC, CAF."
            case .unsupportedFormat(let name):
                "\(name) is not audio this system can decode. Supported: WAV, MP3, M4A/AAC, AIFF, "
                    + "FLAC, CAF."
            case .conversionFailed(let detail):
                "Could not convert the recording to 16 kHz mono: \(detail)"
            case .empty(let name):
                "\(name) decoded to no audio at all — it is empty or truncated."
            }
        }
    }

    /// What the models are given regardless of what was recorded. They downsample to this anyway.
    public static let sampleRate = 16_000.0

    private static let log = Log("audio")

    /// Extensions worth offering in a file picker. Not a validation list — anything CoreAudio can
    /// open will decode, and anything it cannot fails with a message that says so.
    public static let openableExtensions = [
        "wav", "wave", "mp3", "m4a", "aac", "aiff", "aif", "aifc", "caf", "flac", "mp4", "mov",
        "ogg", "opus",
    ]

    /// Loads a recording as something the pipeline can chunk, time and compress.
    ///
    /// - Parameter url: any file CoreAudio can open.
    public static func load(_ url: URL) throws -> AudioFile {
        let name = url.lastPathComponent
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw DecodeError.unreadable(name: name, detail: "no such file")
        }

        if let existing = try? Data(contentsOf: url), isAlreadyTarget(existing) {
            log.debug(
                "recording already in target format", ["file": name, "bytes": "\(existing.count)"])
            return AudioFile(data: existing, mimeType: "audio/wav", url: url)
        }

        let started = Date()
        let pcm = try decodeToPCM(url)
        guard !pcm.isEmpty else { throw DecodeError.empty(name: name) }

        let wav = AudioChunker.wrapInWavContainer(pcm, format: AudioChunker.Format())
        let seconds = Double(pcm.count) / Double(AudioChunker.Format().bytesPerSecond)
        log.info(
            "decoded recording",
            [
                "file": name, "seconds": String(format: "%.1f", seconds),
                "bytes": "\(wav.count)", "ms": LogClock.ms(Date().timeIntervalSince(started)),
            ])
        return AudioFile(data: wav, mimeType: "audio/wav", url: url)
    }

    /// True when the bytes are already 16 kHz mono 16-bit PCM WAV, so decoding would be a lossy
    /// round trip that changes nothing.
    static func isAlreadyTarget(_ data: Data) -> Bool {
        guard data.count > 36, data.prefix(4) == Data("RIFF".utf8),
            AudioChunker.pcmBody(of: data) != nil
        else { return false }
        let channels = Int(UInt16(data[22]) | (UInt16(data[23]) << 8))
        let rate = Int(
            UInt32(data[24]) | (UInt32(data[25]) << 8) | (UInt32(data[26]) << 16)
                | (UInt32(data[27]) << 24))
        let bits = data.count > 35 ? Int(UInt16(data[34]) | (UInt16(data[35]) << 8)) : 0
        return channels == 1 && rate == Int(sampleRate) && bits == 16
    }

    /// Streams the file through a converter rather than reading it whole.
    ///
    /// An hour of 44.1 kHz stereo is 1.3 GB as float PCM. Decoding in blocks keeps peak memory at
    /// the size of one block, which matters because the whole point of file transcription is that
    /// the files are long.
    private static func decodeToPCM(_ url: URL) throws -> Data {
        let name = url.lastPathComponent
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw DecodeError.unreadable(name: name, detail: error.localizedDescription)
        }

        let inputFormat = file.processingFormat
        guard
            let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1,
                interleaved: true)
        else { throw DecodeError.unsupportedFormat(name: name) }

        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw DecodeError.unsupportedFormat(name: name)
        }

        let inputFrames: AVAudioFrameCount = 16_384
        // Enough room for the block plus slack: a rate conversion upward produces more output
        // frames than input ones, and a short buffer stalls the converter rather than failing.
        let outputFrames = AVAudioFrameCount(
            Double(inputFrames) * (sampleRate / inputFormat.sampleRate) + 4_096)

        var pcm = Data()

        while true {
            guard
                let output = AVAudioPCMBuffer(
                    pcmFormat: outputFormat, frameCapacity: outputFrames)
            else { throw DecodeError.conversionFailed("could not allocate an output buffer") }

            // The input block is typed `@Sendable` by the SDK but is called synchronously, on this
            // thread, before `convert` returns — so this never actually crosses a thread. Same
            // reasoning, and the same annotation, as `OpusEncoder` needs for the same API.
            nonisolated(unsafe) var readError: (any Error)?
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) {
                _, inputStatus in
                guard
                    let buffer = AVAudioPCMBuffer(
                        pcmFormat: inputFormat, frameCapacity: inputFrames)
                else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try file.read(into: buffer, frameCount: inputFrames)
                } catch {
                    // `AVAudioFile.read` throws instead of returning zero frames when a read lands
                    // on the end of the file, which happens on every complete decode. Only a stop
                    // *before* the end is a real failure — treating both as one would have made
                    // every successful conversion report a corrupt file.
                    if file.framePosition < file.length { readError = error }
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                guard buffer.frameLength > 0 else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return buffer
            }

            if let readError {
                throw DecodeError.unreadable(
                    name: name, detail: readError.localizedDescription)
            }
            if let conversionError {
                throw DecodeError.conversionFailed(conversionError.localizedDescription)
            }

            if output.frameLength > 0, let channel = output.int16ChannelData?[0] {
                let bytes = Int(output.frameLength) * 2  // interleaved mono, 16-bit
                channel.withMemoryRebound(to: UInt8.self, capacity: bytes) {
                    pcm.append($0, count: bytes)
                }
            }

            if status == .endOfStream { break }
            if status == .error {
                throw DecodeError.conversionFailed("the converter stopped partway")
            }
            // `inputRanDry` cannot happen here: the input block always answers, with data or with
            // end-of-stream.
        }

        return pcm
    }
}
