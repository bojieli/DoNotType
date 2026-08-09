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
    public var text: String
    public var errorMessage: String?

    /// Which backend produced it, so a change of provider is visible in the history.
    public var provider: String
    public var model: String
    public var fidelity: Fidelity

    /// Where it was dictated, for the history list.
    public var appName: String?
    public var windowTitle: String?

    public var durationSeconds: Double
    public var retryCount: Int

    /// Filename inside the history's `audio/` directory. Nil once the audio has been discarded.
    public var audioFileName: String?
    /// The exact context that was sent, so the inspector can show it and a retry can reuse it.
    public var context: ScreenContext?

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        status: Status,
        text: String = "",
        errorMessage: String? = nil,
        provider: String,
        model: String,
        fidelity: Fidelity,
        appName: String? = nil,
        windowTitle: String? = nil,
        durationSeconds: Double = 0,
        retryCount: Int = 0,
        audioFileName: String? = nil,
        context: ScreenContext? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.status = status
        self.text = text
        self.errorMessage = errorMessage
        self.provider = provider
        self.model = model
        self.fidelity = fidelity
        self.appName = appName
        self.windowTitle = windowTitle
        self.durationSeconds = durationSeconds
        self.retryCount = retryCount
        self.audioFileName = audioFileName
        self.context = context
    }

    /// Retryable only while the recording still exists.
    public var canRetry: Bool { status.isRetryable && audioFileName != nil }

    public var summary: String {
        switch status {
        case .completed: text
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
