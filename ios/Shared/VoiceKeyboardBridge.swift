import CoreFoundation
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

/// Public URL routes for returning from the microphone-owning app to common keyboard hosts.
///
/// iOS does not provide a public API for foregrounding an arbitrary bundle identifier. Apps can,
/// however, publish URL schemes for interoperability. Keeping the bundle-to-scheme mapping here
/// lets the containing app use that supported route before trying the best-effort Launch Services
/// fallback. A scheme with its own path is preserved; every other entry opens the app's root.
enum KeyboardHostReturnURL {
    private static let schemes: [String: String] = [
        "com.apple.mobilemail": "mailto",
        "com.apple.mobilesafari": "x-safari-https",
        "com.apple.Maps": "maps",
        "com.apple.journal": "moments",
        "com.apple.mobilenotes": "mobilenotes",
        "com.apple.Notes": "mobilenotes",
        "com.tencent.xin": "weixin",
        "com.larksuite.lark": "lark",
        "com.openai.chat": "openai",
        "com.google.chrome.ios": "googlechrome",
        "com.anthropic.claude": "claude",
        "com.microsoft.copilot": "copilotn",
        "com.hammerandchisel.discord": "discord",
        "doordash.DoorDashConsumer": "doordash",
        "com.evernote.iPhone.Evernote": "evernote",
        "com.facebook.Facebook": "fb",
        "com.google.gemini": "googlegemini",
        "com.google.Gmail": "googlegmail",
        "com.google.Maps": "googlemaps",
        "ai.x.GrokApp": "com.grokapp",
        "com.burbn.instagram": "instagram",
        "com.atlassian.jira.app": "jira",
        "com.linear.ios": "linear",
        "com.facebook.Messenger": "fb-messenger",
        "com.monday.monday": "monday",
        "com.netflix.Netflix": "nflx",
        "notion.id": "notion",
        "com.microsoft.Office.Outlook": "ms-outlook",
        "ai.perplexity.app": "perplexity-app",
        "pinterest": "pinterest",
        "com.reddit.Reddit": "reddit",
        "org.whispersystems.signal": "sgnl",
        "com.tinyspeck.chatlyio": "slack",
        "com.toyopagroup.picaboo": "snapchat",
        "com.spotify.client": "spotify",
        "com.substack.Substack": "substack",
        "com.microsoft.skype.teams": "msteams",
        "ph.telegra.Telegraph": "telegram://resolve",
        "com.burbn.barcelona": "barcelona",
        "com.zhiliaoapp.musically": "tiktok",
        "com.fogcreek.trello": "trello",
        "com.ubercab.UberClient": "uber",
        "com.ubercab.UberEats": "ubereats",
        "com.walmart.electronics": "walmart",
        "net.whatsapp.WhatsApp": "whatsapp",
        "com.atebits.Tweetie2": "twitter",
        "com.google.ios.youtube": "youtube",
        "com.google.Docs": "googledocs",
        "com.amazon.Amazon": "amazonpay",
        "com.google.Drive": "googledrive",
    ]

    static func url(for bundleIdentifier: String) -> URL? {
        guard let scheme = schemes[bundleIdentifier] else { return nil }
        return URL(string: scheme.contains("://") ? scheme : "\(scheme):")
    }
}

/// Return behavior is more than a bundle-to-scheme dictionary. Some host processes are transient
/// system surfaces where launching the bundle is either meaningless or actively sends the user to
/// the wrong place. Keeping that policy beside the routes gives the app one answer for both the
/// automatic attempt and the fallback instructions.
struct KeyboardHostReturnPolicy: Sendable, Equatable {
    enum Guide: String, Sendable {
        case standard
        case appSwitcher
        case manual

        var title: String {
            switch self {
            case .standard: "Return to the app where you were typing"
            case .appSwitcher: "Return with the app switcher"
            case .manual: "Return to your text field"
            }
        }

        var instructions: String {
            switch self {
            case .standard:
                "Swipe across the bottom edge to the previous app, or open it manually. "
                    + "Keep speaking — dictation continues after you leave DoNotType."
            case .appSwitcher:
                "The system search screen cannot be reopened directly. Swipe across the bottom "
                    + "edge or choose the original app in the app switcher. Dictation continues."
            case .manual:
                "This embedded system screen cannot be reopened directly. Open the original app "
                    + "manually; dictation continues while DoNotType is in the background."
            }
        }
    }

    let bundleIdentifier: String?
    let publicURL: URL?
    let allowsBundleLaunch: Bool
    let guide: Guide

    static func resolve(_ bundleIdentifier: String?) -> Self {
        guard let bundleIdentifier = KeyboardHostIdentifier.normalized(bundleIdentifier) else {
            return Self(
                bundleIdentifier: nil, publicURL: nil, allowsBundleLaunch: false, guide: .manual)
        }
        switch bundleIdentifier {
        case "com.apple.Spotlight":
            return Self(
                bundleIdentifier: bundleIdentifier, publicURL: nil,
                allowsBundleLaunch: false, guide: .appSwitcher)
        case "com.apple.SafariViewService":
            return Self(
                bundleIdentifier: bundleIdentifier, publicURL: nil,
                allowsBundleLaunch: false, guide: .manual)
        default:
            return Self(
                bundleIdentifier: bundleIdentifier,
                publicURL: KeyboardHostReturnURL.url(for: bundleIdentifier),
                allowsBundleLaunch: true, guide: .standard)
        }
    }

    /// A stable key for showing the explanatory screen once per kind of handoff. A failed return
    /// may still present it again; this only suppresses the successful cold-launch flash.
    var guideKey: String { bundleIdentifier ?? "unavailable-host" }
}

/// The live command channel between the iOS keyboard and its containing app.
///
/// A custom keyboard cannot own the microphone. The containing app keeps a short-lived audio
/// session warm instead; commands cross the App Group in `UserDefaults`, and Darwin notifications
/// wake whichever process is already running. When the session is cold, the keyboard deep-links
/// into the app and the persisted `waiting` phase makes the launch recoverable even if the
/// notification was posted before the app process existed.
public final class VoiceKeyboardBridge: @unchecked Sendable {
    public enum WarmSessionDuration: String, CaseIterable, Sendable {
        case fiveMinutes
        case twelveHours
        case untilAppCloses

        public var label: String {
            switch self {
            case .fiveMinutes: "5 minutes"
            case .twelveHours: "12 hours"
            case .untilAppCloses: "Until DoNotType closes"
            }
        }

        public var seconds: TimeInterval? {
            switch self {
            case .fiveMinutes: 5 * 60
            case .twelveHours: 12 * 60 * 60
            case .untilAppCloses: nil
            }
        }
    }

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

    public enum MicrophoneAccess: String, Sendable {
        case unknown
        case granted
        case denied
    }

    public enum ActivationStatus: Sendable, Equatable {
        case noFullAccess
        case notConfigured
        case microphoneDenied
        case offline
        case opensContainingApp
        case ready
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

    /// The public editing context iOS exposes to a custom keyboard. Capturing it before a cold app
    /// switch lets Rewrite mean “edit this selection” and lets the extension verify it has returned
    /// to the same field before replacing anything.
    public struct InputContext: Codable, Sendable, Equatable {
        public enum SelectionLocation: Sendable, Equatable {
            case selected
            case cursorAtStart
            case cursorAtEnd
            case unavailable
        }

        public let documentIdentifier: String?
        public let textBeforeSelection: String?
        public let selectedText: String?
        public let textAfterSelection: String?
        public let keyboardType: Int?
        public let returnKeyType: Int?
        public let capturedAt: Date

        public init(
            documentIdentifier: String?, textBeforeSelection: String?, selectedText: String?,
            textAfterSelection: String?, keyboardType: Int?, returnKeyType: Int?,
            capturedAt: Date = Date()
        ) {
            self.documentIdentifier = documentIdentifier
            self.textBeforeSelection = textBeforeSelection
            self.selectedText = selectedText
            self.textAfterSelection = textAfterSelection
            self.keyboardType = keyboardType
            self.returnKeyType = returnKeyType
            self.capturedAt = capturedAt
        }

        public var hasSelection: Bool { !(selectedText ?? "").isEmpty }

        public func locateSelection(
            documentIdentifier currentDocumentIdentifier: String?,
            selectedText currentSelection: String?, textBeforeCursor: String?,
            textAfterCursor: String?
        ) -> SelectionLocation {
            guard let selection = selectedText, !selection.isEmpty,
                documentIdentifier == currentDocumentIdentifier
            else { return .unavailable }
            if currentSelection == selection { return .selected }

            let beforeAnchor = String((textBeforeSelection ?? "").suffix(64))
            let afterAnchor = String((textAfterSelection ?? "").prefix(64))
            let before = textBeforeCursor ?? ""
            let after = textAfterCursor ?? ""

            if after.hasPrefix(selection) {
                let remainder = String(after.dropFirst(selection.count))
                if (beforeAnchor.isEmpty || before.hasSuffix(beforeAnchor))
                    && (afterAnchor.isEmpty || remainder.hasPrefix(afterAnchor))
                {
                    return .cursorAtStart
                }
            }

            if before.hasSuffix(selection) {
                let remainder = String(before.dropLast(selection.count))
                if (beforeAnchor.isEmpty || remainder.hasSuffix(beforeAnchor))
                    && (afterAnchor.isEmpty || after.hasPrefix(afterAnchor))
                {
                    return .cursorAtEnd
                }
            }
            return .unavailable
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
        static let rewriteModeEnabled = "voiceKeyboard.rewriteModeEnabled"
        static let appHasAPIKey = "voiceKeyboard.appHasAPIKey"
        static let microphoneAccess = "voiceKeyboard.microphoneAccess"
        static let returnGuidesShown = "voiceKeyboard.returnGuidesShown"
        static let warmSessionDuration = "voiceKeyboard.warmSessionDuration"
        static let inputContext = "voiceKeyboard.inputContext"
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

    public func activationStatus(hasFullAccess: Bool, isOnline: Bool?) -> ActivationStatus {
        guard hasFullAccess else { return .noFullAccess }
        if defaults?.object(forKey: Key.appHasAPIKey) != nil,
            defaults?.bool(forKey: Key.appHasAPIKey) == false
        {
            return .notConfigured
        }
        if defaults?.string(forKey: Key.microphoneAccess) == MicrophoneAccess.denied.rawValue {
            return .microphoneDenied
        }
        if isOnline == false { return .offline }
        return isSessionWarm ? .ready : .opensContainingApp
    }

    /// Published by the containing app so the extension can explain a setup problem before it
    /// switches applications. The app does not publish credentials themselves.
    public func publishAppReadiness(hasAPIKey: Bool, microphoneAccess: MicrophoneAccess) {
        defaults?.set(hasAPIKey, forKey: Key.appHasAPIKey)
        defaults?.set(microphoneAccess.rawValue, forKey: Key.microphoneAccess)
        defaults?.synchronize()
        Self.post(NotificationName.update)
    }

    func shouldPresentReturnGuide(for policy: KeyboardHostReturnPolicy) -> Bool {
        let shown = Set(defaults?.stringArray(forKey: Key.returnGuidesShown) ?? [])
        return !shown.contains(policy.guideKey)
    }

    func markReturnGuidePresented(for policy: KeyboardHostReturnPolicy) {
        var shown = Set(defaults?.stringArray(forKey: Key.returnGuidesShown) ?? [])
        shown.insert(policy.guideKey)
        defaults?.set(shown.sorted(), forKey: Key.returnGuidesShown)
        defaults?.synchronize()
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

    /// The small Dictate/Rewrite switch belongs to the keyboard, while the selected rewrite style
    /// belongs to Settings. Optional distinguishes an existing install that has never made the
    /// new choice from somebody who explicitly selected Dictate.
    public var rewriteModeEnabled: Bool? {
        guard defaults?.object(forKey: Key.rewriteModeEnabled) != nil else { return nil }
        return defaults?.bool(forKey: Key.rewriteModeEnabled)
    }

    public var warmSessionDuration: WarmSessionDuration {
        get {
            defaults?.string(forKey: Key.warmSessionDuration)
                .flatMap(WarmSessionDuration.init(rawValue:)) ?? .fiveMinutes
        }
        set {
            defaults?.set(newValue.rawValue, forKey: Key.warmSessionDuration)
            defaults?.synchronize()
            Self.post(NotificationName.update)
        }
    }

    public var inputContext: InputContext? {
        guard let data = defaults?.data(forKey: Key.inputContext) else { return nil }
        return try? JSONDecoder().decode(InputContext.self, from: data)
    }

    public func setInputContext(_ context: InputContext?) {
        if let context, let data = try? JSONEncoder().encode(context) {
            defaults?.set(data, forKey: Key.inputContext)
        } else {
            defaults?.removeObject(forKey: Key.inputContext)
        }
        defaults?.synchronize()
    }

    public func setRewriteModeEnabled(_ enabled: Bool) {
        defaults?.set(enabled, forKey: Key.rewriteModeEnabled)
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
        setInputContext(nil)
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
        setInputContext(nil)
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
