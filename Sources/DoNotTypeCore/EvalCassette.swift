import CryptoKit
import Foundation

/// Recorded provider answers, so the suite can be re-run without a key and without paying.
///
/// ## Why this exists
///
/// Every number this project publishes comes from a paid run, on one machine, in one voice. That
/// makes the central claims — the ones the README leads with — unreproducible for anybody else.
/// A contributor cannot check them, CI cannot regress-test them, and a reviewer asked for numbers
/// has to spend money to produce any. For a project whose whole argument is "measure it", that is
/// the wrong shape.
///
/// A cassette is one paid run, written down. `--record` captures what each backend actually said;
/// `--replay` feeds those answers back with no network at all. The scoring, the diff
/// classification, the pass/fail thresholds and the prompt itself are all still exercised — only
/// the provider is not.
///
/// ## What it deliberately does not do
///
/// **It does not make replayed numbers new evidence.** Replaying the same recording twice cannot
/// discover anything about a model; it can only tell you that the harness still classifies those
/// answers the same way. That is exactly what is wanted from CI and exactly what must not be
/// written into the changelog as a fresh measurement.
///
/// **It does not flatten the variance.** Transcription is non-deterministic, and this suite's own
/// noise floor — the spread between passes — is a number it reports. So a cassette stores every
/// take in the order it was recorded and replays them in that order, rather than answering the
/// same request identically forever. Three recorded passes replay as three different passes.
///
/// **It does not survive a prompt change.** The system instruction is part of the key, so editing
/// `prompt/` misses every take and the run fails with a message saying to re-record. Replayed
/// numbers can therefore never be attributed to a prompt that did not produce them, which is the
/// one way a cache like this could actively mislead.
public struct Cassette: Codable, Sendable {
    /// One recorded answer.
    public struct Take: Codable, Sendable {
        public var transcript: String
        public var language: String
        public var rawOutput: String
        public var promptTokens: Int?
        public var completionTokens: Int?
        public var audioTokens: Int?
        public var recordedAt: Date

        public init(result: TranscriptionResult, recordedAt: Date = Date()) {
            self.transcript = result.transcript.transcript
            self.language = result.transcript.language
            self.rawOutput = result.rawOutput
            self.promptTokens = result.usage.promptTokens
            self.completionTokens = result.usage.completionTokens
            self.audioTokens = result.usage.audioTokens
            self.recordedAt = recordedAt
        }

        public var result: TranscriptionResult {
            TranscriptionResult(
                transcript: Transcript(transcript: transcript, language: language),
                usage: TokenUsage(
                    promptTokens: promptTokens,
                    completionTokens: completionTokens,
                    audioTokens: audioTokens),
                rawOutput: rawOutput)
        }
    }

    /// What was recorded, so a reader can tell whether it is still relevant.
    public struct Provenance: Codable, Sendable {
        public var provider: String
        public var model: String
        public var fidelity: String
        public var recordedAt: Date
        /// Fingerprint of the system instruction, so a changed prompt is visible in a diff of this
        /// file rather than only at replay time.
        public var promptDigest: String

        public init(
            provider: String, model: String, fidelity: String, recordedAt: Date,
            promptDigest: String
        ) {
            self.provider = provider
            self.model = model
            self.fidelity = fidelity
            self.recordedAt = recordedAt
            self.promptDigest = promptDigest
        }
    }

    public var provenance: Provenance
    /// Request key to the answers it produced, in the order they were produced.
    public var takes: [String: [Take]]

    public init(provenance: Provenance, takes: [String: [Take]] = [:]) {
        self.provenance = provenance
        self.takes = takes
    }
}

/// Reads and writes a cassette, and hands out takes in recorded order.
///
/// An actor because the suite runs cases concurrently in some modes, and a replay that handed the
/// same take to two callers would silently halve the variance it exists to preserve.
public actor CassetteStore {
    public enum Mode: Sendable, Equatable {
        /// Straight through to the provider. The normal path.
        case live
        /// Through to the provider, writing down what it said.
        case recording(URL)
        /// Answered entirely from the file. No network.
        case replaying(URL)

        public var url: URL? {
            switch self {
            case .live: nil
            case .recording(let url), .replaying(let url): url
            }
        }
    }

    public enum CassetteError: LocalizedError {
        case missing(URL)
        case noTakeFor(key: String, caseHint: String)
        case unreadable(URL, String)
        case stale(URL, recorded: Cassette.Provenance, current: Cassette.Provenance, [String])

        public var errorDescription: String? {
            switch self {
            case .missing(let url):
                """
                No cassette at \(url.path). Record one first, which costs a single paid run:

                    swift run dnt-eval suite --record \(url.path)

                Then commit it, and every run after that is free.
                """
            case .noTakeFor(_, let hint):
                """
                Nothing recorded for this request (\(hint)).

                The prompt, the model, the fidelity and the audio are all part of the key, so this \
                means one of them differs from the recording. If you edited prompt/ that is \
                expected and correct — replayed numbers must never be attributed to a prompt that \
                did not produce them. Re-record with --record.
                """
            case .unreadable(let url, let detail):
                "Could not read the cassette at \(url.path): \(detail)"
            case .stale(let url, let recorded, let current, let differences):
                // Said once, before any case runs, because the alternative is what this project
                // shipped: every request misses the key, each one reports "Nothing recorded", and
                // 48 identical errors describe a single fact — the prompt moved. One case failing
                // to find a take is a puzzle; the whole file failing is a stale cassette, and only
                // this check can tell those two apart.
                """
                The cassette at \(url.path) does not match this run, so nothing in it would be \
                found: \(differences.joined(separator: ", ")).

                    recorded  \(recorded.model) · \(recorded.fidelity) · prompt \
                \(recorded.promptDigest) · recorded \
                \(ISO8601DateFormatter().string(from: recorded.recordedAt))
                    this run  \(current.model) · \(current.fidelity) · prompt \
                \(current.promptDigest)

                The model, the fidelity and the prompt are all part of every request key, so a \
                replay across a change to any of them cannot answer one single request. Replayed \
                numbers must never be attributed to a prompt that did not produce them.

                Re-record it, which costs one paid run:

                    swift run dnt-eval suite --record \(url.path) --provider \
                \(current.provider) --model \(current.model) --fidelity \(current.fidelity)
                """
            }
        }
    }

    private let mode: Mode
    private var cassette: Cassette?
    /// How many takes for a key have been handed out this run.
    private var cursors: [String: Int] = [:]
    /// Keys whose recorded takes ran out and had to be reused.
    private(set) public var exhaustedKeys: Set<String> = []

    private let log = Log("eval")

    public init(mode: Mode) {
        self.mode = mode
    }

    public var isReplaying: Bool { if case .replaying = mode { true } else { false } }
    public var isRecording: Bool { if case .recording = mode { true } else { false } }

    /// Loads an existing cassette, or starts a new one for recording.
    public func open(provenance: Cassette.Provenance) throws {
        switch mode {
        case .live:
            return
        case .recording(let url):
            // Appends to an existing file when one is there, so three passes recorded in three
            // invocations accumulate rather than overwrite.
            cassette = (try? load(url)) ?? Cassette(provenance: provenance)
            cassette?.provenance = provenance
        case .replaying(let url):
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw CassetteError.missing(url)
            }
            cassette = try load(url)
            if let recordedProvenance = cassette?.provenance {
                let differences = Self.differences(between: recordedProvenance, and: provenance)
                if !differences.isEmpty {
                    throw CassetteError.stale(
                        url, recorded: recordedProvenance, current: provenance, differences)
                }
            }
            let recorded = cassette?.takes.values.reduce(0) { $0 + $1.count } ?? 0
            log.info(
                "replaying",
                [
                    "file": url.lastPathComponent,
                    "requests": "\(cassette?.takes.count ?? 0)",
                    "takes": "\(recorded)",
                    "recorded": cassette.map { ISO8601DateFormatter().string(from: $0.provenance.recordedAt) } ?? "?",
                ])
        }
    }

    /// Which parts of a replay disagree with what was recorded.
    ///
    /// Only fields hashed into the request key are compared, because only those can make a lookup
    /// miss. The provider is deliberately not one of them: a cassette recorded from one backend
    /// replays against another by design, since a replay re-checks this project's scoring rather
    /// than the backend's transcription.
    static func differences(
        between recorded: Cassette.Provenance, and current: Cassette.Provenance
    ) -> [String] {
        var differences: [String] = []
        if recorded.model != current.model {
            differences.append("model \(recorded.model) → \(current.model)")
        }
        if recorded.fidelity != current.fidelity {
            differences.append("fidelity \(recorded.fidelity) → \(current.fidelity)")
        }
        if recorded.promptDigest != current.promptDigest {
            differences.append("prompt \(recorded.promptDigest) → \(current.promptDigest)")
        }
        return differences
    }

    /// The next recorded answer for a request, in the order they were recorded.
    ///
    /// Reuses the last take once a key runs out rather than failing: a suite run with more passes
    /// than were recorded is a reasonable thing to do, and refusing would make `--repeat-count`
    /// silently incompatible with replay. It is reported rather than hidden — see
    /// `exhaustedKeys` — because a reader comparing per-pass spread has to know that some of it
    /// was manufactured.
    public func take(for key: String, hint: String) throws -> TranscriptionResult {
        guard let takes = cassette?.takes[key], !takes.isEmpty else {
            throw CassetteError.noTakeFor(key: key, caseHint: hint)
        }
        let cursor = cursors[key, default: 0]
        cursors[key] = cursor + 1

        if cursor >= takes.count {
            exhaustedKeys.insert(key)
            return takes[takes.count - 1].result
        }
        return takes[cursor].result
    }

    public func record(_ result: TranscriptionResult, for key: String) {
        guard case .recording = mode else { return }
        cassette?.takes[key, default: []].append(Cassette.Take(result: result))
    }

    /// Writes the cassette out. Sorted keys and pretty printing, because this file is committed and
    /// a reviewer should be able to read a diff of it.
    public func close() throws {
        guard case .recording(let url) = mode, let cassette else { return }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(cassette).write(to: url, options: .atomic)

        let takes = cassette.takes.values.reduce(0) { $0 + $1.count }
        log.info(
            "recorded",
            ["file": url.lastPathComponent, "requests": "\(cassette.takes.count)", "takes": "\(takes)"])
    }

    private func load(_ url: URL) throws -> Cassette {
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(Cassette.self, from: try Data(contentsOf: url))
        } catch {
            throw CassetteError.unreadable(url, error.localizedDescription)
        }
    }
}

/// How a request is identified in a cassette.
///
/// Deliberately computed from what goes *into* the request rather than from the bytes that leave:
/// the audio is Opus-compressed on the way out, and libopus does not promise byte-identical output
/// across versions or platforms, so keying on the encoded payload would make a cassette recorded on
/// one machine miss on another.
///
/// Everything that could change the answer is in the key. The system instruction is in it because a
/// replayed number must never be attributable to a prompt that did not produce it.
public enum CassetteKey {
    public static func make(
        model: String,
        fidelity: Fidelity,
        systemInstruction: String,
        context: ScreenContext?,
        keyterms: [String],
        audio: Data
    ) -> String {
        var hasher = SHA256()
        func absorb(_ text: String) {
            hasher.update(data: Data(text.utf8))
            hasher.update(data: Data([0]))  // separator, so "ab"+"c" and "a"+"bc" differ
        }

        absorb(model)
        absorb(fidelity.rawValue)
        absorb(systemInstruction)
        absorb(keyterms.joined(separator: "\u{1}"))
        // The context is hashed through its encoded form rather than its fields, so a change to the
        // context format — budgets, ordering, delimiters — misses the cassette. That is the same
        // rule as the prompt: it is a thing the numbers depend on.
        if let context {
            for part in ContextEncoder().encode(context) { absorb(part.description) }
            if case .some(let png) = context.screenshotPNG {
                hasher.update(data: png)
            }
        } else {
            absorb("no-context")
        }
        hasher.update(data: audio)

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// A short, human-readable digest, for provenance and error messages.
    public static func digest(of text: String) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(text.utf8))
        return hasher.finalize().prefix(6).map { String(format: "%02x", $0) }.joined()
    }
}
