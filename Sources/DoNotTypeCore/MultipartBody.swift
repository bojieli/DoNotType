import Foundation

/// Builds `multipart/form-data` bodies for the transcription endpoints that take an upload rather
/// than a raw body.
///
/// Extracted when the second such provider arrived. It is a small amount of code, but it is the
/// kind that fails silently: a missing `\r\n` or a boundary written without its leading `--`
/// produces a request the server rejects with a generic 400, and the bug is invisible in a diff.
/// One implementation, tested once.
struct MultipartBody {
    let boundary: String
    private(set) var data = Data()

    init(boundary: String) {
        self.boundary = boundary
    }

    mutating func addField(_ name: String, _ value: String) {
        data.append(Data("--\(boundary)\r\n".utf8))
        data.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
        data.append(Data("\(value)\r\n".utf8))
    }

    mutating func addFile(
        _ name: String, filename: String, mimeType: String, bytes: Data
    ) {
        data.append(Data("--\(boundary)\r\n".utf8))
        data.append(
            Data(
                "Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n"
                    .utf8))
        data.append(Data("Content-Type: \(mimeType)\r\n\r\n".utf8))
        data.append(bytes)
        data.append(Data("\r\n".utf8))
    }

    /// Closes the body. Must be called exactly once, last.
    mutating func finish() -> Data {
        data.append(Data("--\(boundary)--\r\n".utf8))
        return data
    }

    /// The container is auto-detected from the bytes by every endpoint here, but a filename with
    /// no extension is the kind of thing a strict multipart parser rejects, and it costs one
    /// switch to send a true one.
    static func fileExtension(for mimeType: String) -> String {
        switch mimeType.lowercased() {
        case "audio/wav", "audio/x-wav", "audio/wave": "wav"
        case "audio/flac", "audio/x-flac": "flac"
        case "audio/mpeg", "audio/mp3": "mp3"
        case "audio/ogg", "audio/opus": "ogg"
        case "audio/aac": "aac"
        case "audio/mp4", "audio/m4a", "audio/x-m4a": "m4a"
        default: "bin"
        }
    }
}
