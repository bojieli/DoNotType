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
