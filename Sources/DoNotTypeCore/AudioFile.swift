import Foundation

/// A recording loaded from disk, with its MIME type resolved from the extension.
public struct AudioFile: Sendable {
    public var data: Data
    public var mimeType: String
    public var url: URL

    public init(contentsOf url: URL) throws {
        self.data = try Data(contentsOf: url)
        self.url = url
        self.mimeType = Self.mimeType(forExtension: url.pathExtension)
    }

    /// For audio already in memory — a retry reading from the history store, or a test fixture.
    public init(data: Data, mimeType: String, url: URL = URL(fileURLWithPath: "/dev/null")) {
        self.data = data
        self.mimeType = mimeType
        self.url = url
    }

    public var part: InputPart { .audio(data: data, mimeType: mimeType) }

    /// The same recording as Ogg Opus, for upload.
    ///
    /// Measured on real speech: 704 kB of 16 kHz PCM becomes 45 kB, and end-to-end latency falls
    /// from 11.4 s to 9.1 s on a 30-second clip and 6.9 s to 4.9 s on a 10-second one. The
    /// transcript does not change — the same fixtures transcribe identically as WAV, FLAC and
    /// Opus, and the provider bills the same audio-token count either way.
    ///
    /// Only the *upload* is compressed. History keeps the WAV, because a retry re-runs the whole
    /// pipeline and the chunker needs PCM to find silence in; re-deriving that from a lossy copy
    /// would make a retried dictation a worse one.
    ///
    /// Returns `self` unchanged if encoding is unavailable or fails. A compression optimisation
    /// must never be able to cost someone their words.
    public func compressedForUpload() -> AudioFile {
        guard mimeType == "audio/wav", OpusEncoder.isAvailable else { return self }
        guard let ogg = try? OpusEncoder().encode(wav: data), ogg.count < data.count else {
            return self
        }
        return AudioFile(data: ogg, mimeType: "audio/ogg", url: url)
    }

    /// Length in seconds, read from the WAV header. Nil for compressed formats, whose duration
    /// cannot be known without decoding — not worth doing for a statistic.
    public var durationSeconds: Double? {
        guard mimeType == "audio/wav",
            let body = AudioChunker.pcmBody(of: data),
            data.count > 34
        else { return nil }

        let channels = Int(
            UInt16(data[22]) | (UInt16(data[23]) << 8))
        let sampleRate = Int(
            UInt32(data[24]) | (UInt32(data[25]) << 8) | (UInt32(data[26]) << 16)
                | (UInt32(data[27]) << 24))
        let bitsPerSample = Int(UInt16(data[34]) | (UInt16(data[35]) << 8))

        let bytesPerSecond = sampleRate * channels * bitsPerSample / 8
        return bytesPerSecond > 0 ? Double(body.count) / Double(bytesPerSecond) : nil
    }

    /// Roughly what the model will bill, at the documented 32 tokens per audio second.
    public func estimatedTokens(durationSeconds: Double) -> Int {
        Int((durationSeconds * 32).rounded(.up))
    }

    /// Documented types are WAV, MP3, AIFF, AAC, OGG and FLAC.
    ///
    /// `audio/ogg` is specified as OGG *Vorbis*; Opus-in-Ogg shares the MIME type but is a
    /// different codec and may not decode. FLAC is the safe lossless default.
    public static func mimeType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "wav", "wave": "audio/wav"
        case "flac": "audio/flac"
        case "mp3", "mpeg", "mpga": "audio/mpeg"
        case "aiff", "aif": "audio/aiff"
        case "aac", "m4a": "audio/aac"
        case "ogg", "oga", "opus": "audio/ogg"
        default: "application/octet-stream"
        }
    }
}
