import CoreFoundation
import Foundation

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
