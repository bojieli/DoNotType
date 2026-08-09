import Foundation

/// The model's entire output. Two fields, deliberately.
///
/// Every additional field is somewhere the model can decide it has something to add. `language`
/// earns its place because it is cheap and enables per-language routing later; nothing else has.
public struct Transcript: Sendable, Codable, Equatable {
    public var transcript: String
    public var language: String

    public init(transcript: String, language: String = "") {
        self.transcript = transcript
        self.language = language
    }

    /// JSON Schema sent as the structured-output contract.
    ///
    /// Computed rather than stored: `[String: Any]` is not `Sendable`, and a fresh dictionary per
    /// call costs nothing next to an HTTP round trip.
    public static var jsonSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "transcript": ["type": "string"],
                "language": ["type": "string"],
            ],
            "required": ["transcript", "language"],
            "additionalProperties": false,
        ]
    }

    /// Parses a model response that should be JSON but may not quite be.
    ///
    /// Models wrap structured output in markdown fences often enough — observed from
    /// `gemini-3.6-flash` through an OpenAI-compatible shim even with `response_format` set —
    /// that tolerating it is cheaper than failing a dictation over punctuation.
    public static func parse(_ raw: String) throws -> Transcript {
        let candidate = stripCodeFence(raw).trimmed
        guard let data = candidate.data(using: .utf8) else {
            throw ProviderError.malformedResponse("response was not valid UTF-8")
        }
        do {
            return try JSONDecoder().decode(Transcript.self, from: data)
        } catch {
            // A model that ignored the schema entirely and returned bare prose is still usable:
            // the text it produced is the transcript. Better a working dictation than an error.
            guard !candidate.isEmpty, !candidate.hasPrefix("{") else {
                throw ProviderError.malformedResponse(
                    "could not decode Transcript from: \(candidate.prefix(200))")
            }
            return Transcript(transcript: candidate, language: "")
        }
    }

    static func stripCodeFence(_ raw: String) -> String {
        let text = raw.trimmed
        guard text.hasPrefix("```") else { return text }
        var lines = text.components(separatedBy: .newlines)
        lines.removeFirst()                                  // ``` or ```json
        if lines.last?.trimmed == "```" { lines.removeLast() }
        return lines.joined(separator: "\n")
    }
}
