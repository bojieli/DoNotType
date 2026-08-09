import Foundation

/// One entry in the Interactions API `input` array.
///
/// The wire format is a flat list of type-discriminated blocks, which maps directly onto the
/// labelled-context design: each block is either a delimiter-wrapped text section, the focused
/// window image, or the recording itself.
public enum InputPart: Sendable, Equatable {
    case text(String)
    case image(data: Data, mimeType: String)
    case audio(data: Data, mimeType: String)
    /// Audio already uploaded to the Files API. Referenced, not carried.
    case remoteAudio(uri: String, mimeType: String)
}

extension InputPart: Encodable {
    private enum CodingKeys: String, CodingKey {
        case type, text, data, uri
        case mimeType = "mime_type"
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let value):
            try c.encode("text", forKey: .type)
            try c.encode(value, forKey: .text)
        case .image(let data, let mimeType):
            try c.encode("image", forKey: .type)
            try c.encode(data.base64EncodedString(), forKey: .data)
            try c.encode(mimeType, forKey: .mimeType)
        case .audio(let data, let mimeType):
            try c.encode("audio", forKey: .type)
            try c.encode(data.base64EncodedString(), forKey: .data)
            try c.encode(mimeType, forKey: .mimeType)
        case .remoteAudio(let uri, let mimeType):
            try c.encode("audio", forKey: .type)
            // `uri`, not `file_uri` — the latter is rejected as an unknown parameter.
            try c.encode(uri, forKey: .uri)
            try c.encode(mimeType, forKey: .mimeType)
        }
    }
}

extension InputPart: CustomStringConvertible {
    /// Redacted description for logs — never dumps base64 payloads.
    public var description: String {
        switch self {
        case .text(let value):
            return "text(\(value.count) chars)"
        case .image(let data, let mimeType):
            return "image(\(data.count) bytes, \(mimeType))"
        case .audio(let data, let mimeType):
            return "audio(\(data.count) bytes, \(mimeType))"
        case .remoteAudio(_, let mimeType):
            return "audio(uploaded, \(mimeType))"
        }
    }
}
