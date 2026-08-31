import CoreFoundation
import DoNotTypeCore
import Foundation

/// Rejects UIKit's placeholder values before they cross the App Group as return targets.
///
/// Private host selectors can legitimately answer with strings such as `<null>` while their
/// connection is still being assembled. Treating one as a bundle identifier prevents the
/// resolver from continuing to the object that owns the real value.
enum KeyboardHostIdentifier {
    static func normalized(_ candidate: String?) -> String? {
        guard let candidate else { return nil }
        let value = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        let placeholder = value.lowercased()
        guard !["null", "<null>", "(null)", "nil", "<nil>"].contains(placeholder) else {
            return nil
        }

        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= 2,
            components.allSatisfy({ component in
                !component.isEmpty
                    && component.unicodeScalars.allSatisfy {
                        CharacterSet.alphanumerics.contains($0) || $0 == "-"
                    }
            })
        else { return nil }
        return value
    }
}

/// The live command channel between the iOS keyboard and its containing app.
///
/// A custom keyboard cannot own the microphone. The containing app keeps a short-lived audio
/// session warm instead; commands cross the App Group in `UserDefaults`, and Darwin notifications
/// wake whichever process is already running. When the session is cold, the keyboard deep-links
/// into the app and the persisted `waiting` phase makes the launch recoverable even if the
/// notification was posted before the app process existed.
public final class VoiceKeyboardBridge: @unchecked Sendable {
    public enum Phase: String, Sendable {
        case idle
        case waiting
        case recording
        case transcribing
        case failed
    }

    public enum Command: Sendable {
        case start
        case stop
        case cancel
    }

    public struct Snapshot: Sendable, Equatable {
        public let phase: Phase
        public let result: String?
        public let message: String?
        public let updatedAt: Date?

        public init(phase: Phase, result: String?, message: String?, updatedAt: Date?) {
            self.phase = phase
            self.result = result
            self.message = message
            self.updatedAt = updatedAt
        }
    }

    /// What the containing app can honestly know about keyboard setup.
    ///
    /// iOS does not expose the enabled-keyboard list to an app. The extension can, however,
    /// confirm that it has actually appeared and report the `hasFullAccess` value iOS gives it.
    public struct KeyboardSetupStatus: Sendable, Equatable {
        public let lastSeen: Date?
        public let hasFullAccess: Bool?

        public init(lastSeen: Date?, hasFullAccess: Bool?) {
            self.lastSeen = lastSeen
            self.hasFullAccess = hasFullAccess
        }
    }

    public static let sessionFreshness: TimeInterval = 3

    private enum Key {
        static let phase = "voiceKeyboard.phase"
        static let result = "voiceKeyboard.result"
        static let message = "voiceKeyboard.message"
        static let updatedAt = "voiceKeyboard.updatedAt"
        static let heartbeat = "voiceKeyboard.heartbeat"
        static let keyboardLastSeen = "voiceKeyboard.keyboardLastSeen"
        static let keyboardHasFullAccess = "voiceKeyboard.keyboardHasFullAccess"
        static let returnHostBundleIdentifier = "voiceKeyboard.returnHostBundleIdentifier"
        static let liveMode = "voiceKeyboard.liveMode"
        /// Written by builds before the mode picker. Read once, to migrate; never written.
        static let rewriteModeEnabled = "voiceKeyboard.rewriteModeEnabled"
        static let translationTarget = "voiceKeyboard.translationTarget"
        static let secondStageBlocker = "voiceKeyboard.secondStageBlocker"
    }

    private enum NotificationName {
        static let start = "app.donottype.voiceKeyboard.start"
        static let stop = "app.donottype.voiceKeyboard.stop"
        static let cancel = "app.donottype.voiceKeyboard.cancel"
        static let update = "app.donottype.voiceKeyboard.update"
    }

    private let defaults: UserDefaults?
    private let heartbeatLock = NSLock()
    private var lastHeartbeat: TimeInterval = 0

    public init(defaults: UserDefaults? = UserDefaults(suiteName: TranscriptStore.appGroup)) {
        self.defaults = defaults
    }

    public var snapshot: Snapshot {
        let rawPhase = defaults?.string(forKey: Key.phase) ?? ""
        let phase = Phase(rawValue: rawPhase) ?? .idle
        let timestamp = defaults?.double(forKey: Key.updatedAt) ?? 0
        return Snapshot(
            phase: phase,
            result: defaults?.string(forKey: Key.result),
            message: defaults?.string(forKey: Key.message),
            updatedAt: timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : nil)
    }

    public var isSessionWarm: Bool {
        let timestamp = defaults?.double(forKey: Key.heartbeat) ?? 0
        return timestamp > 0 && Date().timeIntervalSince1970 - timestamp < Self.sessionFreshness
    }

    public var keyboardSetupStatus: KeyboardSetupStatus {
        let timestamp = defaults?.double(forKey: Key.keyboardLastSeen) ?? 0
        guard timestamp > 0 else {
            return KeyboardSetupStatus(lastSeen: nil, hasFullAccess: nil)
        }
        return KeyboardSetupStatus(
            lastSeen: Date(timeIntervalSince1970: timestamp),
            hasFullAccess: defaults?.bool(forKey: Key.keyboardHasFullAccess))
    }

    /// The application whose text field launched the keyboard dictation. The extension captures
    /// this before opening DoNotType so the containing app can return to the actual caller rather
    /// than merely suspending to the Home Screen.
    public var returnHostBundleIdentifier: String? {
        defaults?.string(forKey: Key.returnHostBundleIdentifier)
            .flatMap(KeyboardHostIdentifier.normalized)
    }

    /// The mode chip belongs to the keyboard, while the style and the target language belong to
    /// Settings. Optional distinguishes an existing install that has never made the choice from
    /// somebody who explicitly selected Dictate.
    public var liveMode: LiveMode? {
        if let raw = defaults?.string(forKey: Key.liveMode), let mode = LiveMode(rawValue: raw) {
            return mode
        }
        // A build with the two-state switch keeps whichever half of it the user had chosen. It
        // could not express Translate, so there is nothing to lose in that direction.
        guard defaults?.object(forKey: Key.rewriteModeEnabled) != nil else { return nil }
        return defaults?.bool(forKey: Key.rewriteModeEnabled) == true ? .rewrite : .dictate
    }

    /// The configured target language, or empty.
    ///
    /// The keyboard needs it only to name what it is about to do. It cannot translate anything
    /// itself — the containing app owns the request — but a chip reading "Rewrite" over a dictation
    /// that is going to come back in another language is worse than no chip at all.
    public var translationTarget: String {
        defaults?.string(forKey: Key.translationTarget) ?? ""
    }

    public func setTranslationTarget(_ language: String) {
        defaults?.set(language, forKey: Key.translationTarget)
        defaults?.synchronize()
        Self.post(NotificationName.update)
    }

    public func setLiveMode(_ mode: LiveMode) {
        defaults?.set(mode.rawValue, forKey: Key.liveMode)
        defaults?.synchronize()
        Self.post(NotificationName.update)
    }

    /// Why the second stage cannot run, as the containing app resolved it.
    ///
    /// The keyboard cannot answer this itself: the keys are in the app's Keychain and the extension
    /// has no business reading them. So the app resolves the shared rule and publishes only which
    /// case it landed on, and the keyboard builds the same sentence from it. Publishing the
    /// sentence instead would put the wording in two places and let it drift.
    public var secondStageBlocker: SecondStageBlocker {
        SecondStageBlocker(persisted: defaults?.string(forKey: Key.secondStageBlocker))
    }

    public func publishSecondStageBlocker(_ blocker: SecondStageBlocker) {
        defaults?.set(blocker.persistedValue, forKey: Key.secondStageBlocker)
        defaults?.synchronize()
        Self.post(NotificationName.update)
    }

    public func setReturnHostBundleIdentifier(_ bundleIdentifier: String?) {
        if let bundleIdentifier = KeyboardHostIdentifier.normalized(bundleIdentifier) {
            defaults?.set(bundleIdentifier, forKey: Key.returnHostBundleIdentifier)
        } else {
            defaults?.removeObject(forKey: Key.returnHostBundleIdentifier)
        }
        defaults?.synchronize()
    }

    /// Called by the extension when it actually appears. This turns setup's question marks into
    /// evidence rather than pretending the containing app can inspect Settings directly.
    public func publishKeyboardSetupStatus(hasFullAccess: Bool) {
        defaults?.set(Date().timeIntervalSince1970, forKey: Key.keyboardLastSeen)
        defaults?.set(hasFullAccess, forKey: Key.keyboardHasFullAccess)
        defaults?.synchronize()
        Self.post(NotificationName.update)
    }

    /// Returns whether the app reported a live session before the command was sent.
    @discardableResult
    public func requestStart() -> Bool {
        let warm = isSessionWarm
        write(phase: .waiting, result: nil, message: nil)
        Self.post(NotificationName.start)
        return warm
    }

    public func requestStop() {
        write(phase: .transcribing, result: nil, message: nil)
        Self.post(NotificationName.stop)
    }

    public func requestCancel() {
        write(phase: .idle, result: nil, message: nil)
        Self.post(NotificationName.cancel)
    }

    public func publishRecordingStarted() {
        write(phase: .recording, result: nil, message: nil)
    }

    public func publishTranscribing() {
        write(phase: .transcribing, result: nil, message: nil)
    }

    public func publishResult(_ text: String) {
        write(phase: .idle, result: text, message: nil)
    }

    public func publishFailure(_ message: String) {
        write(phase: .failed, result: nil, message: message)
    }

    public func acknowledgeResult() {
        write(phase: .idle, result: nil, message: nil)
    }

    /// Called from the audio callback. Throttling here avoids writing shared defaults per buffer.
    public func touchSession() {
        let now = Date().timeIntervalSince1970
        let shouldWrite = heartbeatLock.withLock { () -> Bool in
            guard now - lastHeartbeat >= 1 else { return false }
            lastHeartbeat = now
            return true
        }
        guard shouldWrite else { return }
        defaults?.set(now, forKey: Key.heartbeat)
    }

    public func endSession() {
        heartbeatLock.withLock { lastHeartbeat = 0 }
        defaults?.removeObject(forKey: Key.heartbeat)
        defaults?.synchronize()
        Self.post(NotificationName.update)
    }

    public static func observeCommands(_ handler: @escaping @Sendable (Command) -> Void) {
        observe(NotificationName.start) { handler(.start) }
        observe(NotificationName.stop) { handler(.stop) }
        observe(NotificationName.cancel) { handler(.cancel) }
    }

    public static func observeUpdates(_ handler: @escaping @Sendable () -> Void) {
        observe(NotificationName.update, handler: handler)
    }

    private func write(phase: Phase, result: String?, message: String?) {
        defaults?.set(phase.rawValue, forKey: Key.phase)
        if let result { defaults?.set(result, forKey: Key.result) }
        else { defaults?.removeObject(forKey: Key.result) }
        if let message { defaults?.set(message, forKey: Key.message) }
        else { defaults?.removeObject(forKey: Key.message) }
        defaults?.set(Date().timeIntervalSince1970, forKey: Key.updatedAt)
        // The Darwin notification is the other process's cue to read. Flush these few control
        // writes first so it never wakes against an older cached phase or result.
        defaults?.synchronize()
        Self.post(NotificationName.update)
    }

    private static func post(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString), nil, nil, true)
    }

    private static func observe(_ name: String, handler: @escaping @Sendable () -> Void) {
        final class Box: @unchecked Sendable {
            let handler: @Sendable () -> Void
            init(_ handler: @escaping @Sendable () -> Void) { self.handler = handler }
        }
        let box = Box(handler)
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passRetained(box).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                Unmanaged<Box>.fromOpaque(observer).takeUnretainedValue().handler()
            },
            name as CFString, nil, .deliverImmediately)
    }
}

/// What the containing app found when it asked whether a second stage can run.
///
/// A three-value summary of `RewriteAvailability` minus the job, because the job is whichever mode
/// the keyboard is asking about and the requirements are the same for both. The keyboard turns it
/// back into the shared type — and therefore the shared sentence — rather than carrying text over
/// the bridge.
public enum SecondStageBlocker: Equatable, Sendable {
    /// A configured backend can take text and give text back.
    case none
    /// No key for the selected backend, so nothing runs at all.
    case noKey
    /// The selected backend only transcribes, and no other configured one can do more.
    case backend(ProviderKind)

    public init(persisted: String?) {
        switch persisted {
        case .some(Self.noKeyValue): self = .noKey
        case .some(let raw) where !raw.isEmpty:
            self = ProviderKind(rawValue: raw).map(Self.backend) ?? .none
        default: self = .none
        }
    }

    /// Resolved by the app, published for the keyboard.
    public init(_ availability: RewriteAvailability) {
        switch availability {
        // `.noTargetLanguage` is the mode's own problem rather than a backend's, and the picker
        // already shows it where the mode is chosen — so there is nothing for the keyboard to say
        // about the backend here.
        case .available, .noTargetLanguage: self = .none
        case .noKey: self = .noKey
        case .backendCannotRewrite(let kind, _): self = .backend(kind)
        }
    }

    private static let noKeyValue = "no-key"

    var persistedValue: String {
        switch self {
        case .none: ""
        case .noKey: Self.noKeyValue
        case .backend(let kind): kind.rawValue
        }
    }

    /// Whether the given mode can run, and what to say when it cannot — the same answer
    /// `LiveMode.availability` gives on Android, reached without the keys the extension cannot see.
    public func availability(for mode: LiveMode, translationTarget: String) -> RewriteAvailability {
        switch mode {
        case .dictate:
            return .available
        case .rewrite:
            return availability(for: .rewriting)
        case .translate:
            guard !TranslationTarget.sanitized(translationTarget).isEmpty else {
                return .noTargetLanguage
            }
            return availability(for: .translating)
        }
    }

    private func availability(for job: SecondStageJob) -> RewriteAvailability {
        switch self {
        case .none: .available
        case .noKey: .noKey(job)
        case .backend(let kind): .backendCannotRewrite(kind, job)
        }
    }
}
