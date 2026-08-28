import Foundation

/// One dictation, and everything needed to try it again.
///
/// Retry is the reason this type holds more than text. A transcript that failed because the
/// network dropped is not lost work — the recording and the screen context that went with it are
/// still on disk, so the request can simply be reissued. That means audio retention is not purely
/// a privacy setting: audio for a *failed* entry has to survive until it succeeds or the user
/// gives up on it.
public struct DictationRecord: Codable, Sendable, Identifiable, Equatable {
    public enum Status: String, Codable, Sendable {
        /// Uploaded and transcribed.
        case completed
        /// The request failed. Audio is retained so it can be retried.
        case failed
        /// Recorded but not yet sent — the app quit mid-flight, or the network was down.
        case pending

        public var isRetryable: Bool { self != .completed }
    }

    public let id: UUID
    public let createdAt: Date
    public var status: Status
    /// Always the verbatim transcript, whatever style was applied afterwards.
    ///
    /// Keeping this separate from `styledText` is the whole difference from the tool this project
    /// replaces: rewriting is allowed, but it is a derived artifact and what you actually said
    /// remains recoverable.
    public var text: String
    /// The rewritten version, when a style other than verbatim was used.
    public var styledText: String?
    public var style: RewriteStyle?
    /// What to tell the user: one sentence, from `FailureAdvice`.
    public var errorMessage: String?

    /// The failure exactly as it arrived, uncut.
    ///
    /// Separate from `errorMessage` because the two have different jobs and one string cannot do
    /// both. A list needs a sentence somebody can read at a glance; debugging needs the status, the
    /// whole response body and the exception type, with nothing dropped — a body cut at 400
    /// characters loses the `param` field that says which part of the request was wrong, and a
    /// half-message pasted into an issue cannot be searched for.
    public var errorDetail: String?

    /// A rewrite was asked for and did not happen, so what was delivered is the verbatim text.
    ///
    /// Recorded rather than inferred from a nil `styledText`, which is also what an ordinary
    /// verbatim dictation looks like. The difference matters: one is what was asked for, the other
    /// is a second request that failed, and only the second is worth telling somebody about.
    ///
    /// Optional because a non-optional `Bool` would make every history row written before this
    /// existed fail to decode — synthesised `Codable` requires the key. Nil means "written before
    /// anyone asked", which is not the same as false and is exactly as informative.
    public var rewriteFailed: Bool?

    /// Which backend produced it, so a change of provider is visible in the history.
    public var provider: String
    public var model: String
    public var fidelity: Fidelity

    /// Where it was dictated, for the history list.
    public var appName: String?
    public var windowTitle: String?

    public var durationSeconds: Double
    public var retryCount: Int

    /// Wall clock from the end of speech to text on screen — the number the user actually feels.
    ///
    /// Deliberately measured from key release rather than from the request, because everything
    /// between those two points (waiting on the screen-context read, falling back from a failed
    /// a retry) is time the user spends staring at the overlay. A latency figure that
    /// excluded it would be flattering and useless.
    public var latencySeconds: Double?
    /// Time inside the transcription request alone, for separating a slow model from a slow app.
    public var requestSeconds: Double?
    /// Time spent rewriting, when a style was applied. Part of the wait, but a separate choice.
    public var rewriteSeconds: Double?
    /// How many requests the audio was split across. 1 unless the dictation was long.
    public var chunkCount: Int?
    public var usage: TokenUsage?

    /// Filename inside the history's `audio/` directory. Nil once the audio has been discarded.
    public var audioFileName: String?
    /// The exact context that was sent, so the inspector can show it and a retry can reuse it.
    public var context: ScreenContext?

    /// Which mode produced `styledText`.
    ///
    /// `style` above cannot answer this on its own any more: it is a `RewriteStyle`, and a summary
    /// is deliberately not one. Nil on rows written before modes existed, which is why every reader
    /// goes through `resolvedMode` rather than this.
    public var mode: TranscriptMode?
    /// The recording this came from, when it was a file rather than the microphone.
    ///
    /// Its presence is what distinguishes an offline transcription from a dictation, and both live
    /// in the same history on purpose — "find that thing I said about the migration" should not
    /// depend on remembering which way it was captured.
    public var sourceFileName: String?

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        status: Status,
        text: String = "",
        styledText: String? = nil,
        style: RewriteStyle? = nil,
        errorMessage: String? = nil,
        errorDetail: String? = nil,
        rewriteFailed: Bool? = nil,
        provider: String,
        model: String,
        fidelity: Fidelity,
        appName: String? = nil,
        windowTitle: String? = nil,
        durationSeconds: Double = 0,
        retryCount: Int = 0,
        latencySeconds: Double? = nil,
        requestSeconds: Double? = nil,
        rewriteSeconds: Double? = nil,
        chunkCount: Int? = nil,
        usage: TokenUsage? = nil,
        audioFileName: String? = nil,
        context: ScreenContext? = nil,
        mode: TranscriptMode? = nil,
        sourceFileName: String? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.status = status
        self.text = text
        self.styledText = styledText
        self.style = style
        self.errorMessage = errorMessage
        self.errorDetail = errorDetail
        self.rewriteFailed = rewriteFailed
        self.provider = provider
        self.model = model
        self.fidelity = fidelity
        self.appName = appName
        self.windowTitle = windowTitle
        self.durationSeconds = durationSeconds
        self.retryCount = retryCount
        self.latencySeconds = latencySeconds
        self.requestSeconds = requestSeconds
        self.rewriteSeconds = rewriteSeconds
        self.chunkCount = chunkCount
        self.usage = usage
        self.audioFileName = audioFileName
        self.context = context
        self.mode = mode
        self.sourceFileName = sourceFileName
    }

    /// Retryable only while the recording still exists.
    public var canRetry: Bool { status.isRetryable && audioFileName != nil }

    /// Whether the transcription can be run again, and the recording saved out of the history.
    ///
    /// A superset of `canRetry`, and a different question. Retry is about words that never
    /// arrived; redoing is about words that arrived wrong — a name misheard, a provider that was
    /// the wrong one for the accent — and that case is a *completed* dictation, which keeps its
    /// audio only when the keep-audio setting was on when it was made.
    public var canRedo: Bool { audioFileName != nil }

    /// What to call the recording when it is saved somewhere the user chose.
    ///
    /// Named for when it was said. On disk it is the record's UUID, which is the right name for a
    /// file the store owns and a useless one in a downloads folder next to twenty others.
    public var audioExportName: String {
        "donottype-\(Self.exportStamp.string(from: createdAt)).wav"
    }

    private static let exportStamp: DateFormatter = {
        let formatter = DateFormatter()
        // Fixed format, so the name does not change shape with the user's region — a filename
        // with a slash in it is not a filename.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    /// What gets inserted: the styled version when one exists, otherwise the transcript.
    public var deliveredText: String { styledText ?? text }

    /// The mode, including for rows written before the field existed.
    ///
    /// Old rows recorded a `RewriteStyle` and nothing else, and every one of those was either a
    /// verbatim dictation or a rewrite — summaries did not exist yet — so the reconstruction is
    /// exact rather than a guess.
    public var resolvedMode: TranscriptMode {
        if let mode { return mode }
        if let style, style.isRewrite { return .rewrite(style) }
        return .verbatim
    }

    /// True when this came from a recording on disk rather than the microphone.
    public var isFromFile: Bool { sourceFileName != nil }

    public var summary: String {
        switch status {
        case .completed: deliveredText
        case .failed: errorMessage ?? "Failed"
        case .pending: "Waiting to send"
        }
    }
}

/// How long transcripts are kept. Mirrors the options Typeless offers, because they are the right
/// ones: people either want a searchable log or want nothing written down at all.
public enum RetentionPolicy: String, Codable, CaseIterable, Sendable {
    case never
    case oneDay
    case oneWeek
    case oneMonth
    case forever

    public var label: String {
        switch self {
        case .never: "Don't keep history"
        case .oneDay: "24 hours"
        case .oneWeek: "1 week"
        case .oneMonth: "1 month"
        case .forever: "Forever"
        }
    }

    var maximumAge: TimeInterval? {
        switch self {
        case .never: 0
        case .oneDay: 86_400
        case .oneWeek: 604_800
        case .oneMonth: 2_592_000
        case .forever: nil
        }
    }
}
