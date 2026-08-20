import Foundation

/// The model's entire output. Three fields, and the third is optional.
///
/// Every additional field is somewhere the model can decide it has something to add. `language`
/// earns its place because it is cheap and enables per-language routing later. `styled` earns its
/// place because it is what makes a single-request rewrite possible without giving up the verbatim
/// transcript: the model returns both, so "what did I actually say" survives a rewrite that cost
/// no extra round trip. It is nil on every request that did not ask for a style, which is most of
/// them.
public struct Transcript: Sendable, Codable, Equatable {
    public var transcript: String
    public var language: String
    /// The rewritten transcript, when a style was requested in the same request. Nil otherwise.
    public var styled: String?

    public init(transcript: String, language: String = "", styled: String? = nil) {
        self.transcript = transcript
        self.language = language
        self.styled = styled
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

    /// The schema for a request that transcribes and rewrites in one call.
    ///
    /// `styled` is required rather than optional here: a model given the choice sometimes returns
    /// only the field it finds more interesting, and a rewrite request that silently comes back
    /// unrewritten is worse than one that fails loudly enough to fall back.
    public static var styledJSONSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "transcript": ["type": "string"],
                "styled": ["type": "string"],
                "language": ["type": "string"],
            ],
            "required": ["transcript", "styled", "language"],
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
            guard !candidate.isEmpty else {
                throw ProviderError.malformedResponse("the model returned nothing")
            }
            // Truncated or slightly malformed JSON still usually carries the transcript, and
            // throwing it away would lose words the user actually said.
            if candidate.hasPrefix("{"), let salvaged = salvageTranscript(from: candidate) {
                return Transcript(transcript: salvaged, language: "")
            }
            guard !candidate.hasPrefix("{") else {
                // Uncut: this is the response that could not be parsed, and the parse failure
                // is somewhere in it. Cutting the evidence out of the error about the evidence
                // leaves nothing to look at.
                throw ProviderError.malformedResponse(
                    "could not decode Transcript from: \(candidate)")
            }
            return Transcript(transcript: candidate, language: "")
        }
    }

    /// Pulls the `transcript` value out of JSON that failed to decode — most often because the
    /// response was cut off by a token limit part-way through the string.
    static func salvageTranscript(from candidate: String) -> String? {
        guard let keyRange = candidate.range(of: "\"transcript\"") else { return nil }
        let afterKey = candidate[keyRange.upperBound...]
        guard let colon = afterKey.firstIndex(of: ":") else { return nil }

        var value = ""
        var isInside = false
        var isEscaped = false
        for character in afterKey[afterKey.index(after: colon)...] {
            if isEscaped {
                // Only the escapes a transcript realistically contains; anything else passes
                // through as written rather than being dropped.
                value.append(character == "n" ? "\n" : character)
                isEscaped = false
                continue
            }
            if character == "\\" { isEscaped = true; continue }
            if character == "\"" {
                if isInside { break }
                isInside = true
                continue
            }
            if isInside { value.append(character) }
        }
        let trimmed = value.trimmed
        return trimmed.isEmpty ? nil : trimmed
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
