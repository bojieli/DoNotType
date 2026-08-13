import Foundation
import Network

/// Whether the network is usable, and a way to wait for it to become so.
///
/// This exists to change what happens *before* a request rather than after it. Discovering you are
/// offline by spending fifteen seconds on a timeout, then showing an error, is the worst version
/// of this experience: the user waited, got nothing, and has to remember to come back. Knowing
/// first means the dictation goes straight into the queue and the user is told it is safe.
public actor Reachability {
    public static let shared = Reachability()

    private let monitor = NWPathMonitor()
    private var isStarted = false
    private var currentPath: NWPath.Status = .requiresConnection
    /// Continuations waiting for the network to come back.
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public var isOnline: Bool {
        // Before the first path update the monitor reports `requiresConnection`, which would make
        // a freshly launched app believe it is offline. Treat "unknown" as online and let the
        // request itself find out.
        !isStarted || currentPath == .satisfied
    }

    public func start() {
        guard !isStarted else { return }
        isStarted = true

        monitor.pathUpdateHandler = { [weak self] path in
            Task { await self?.update(path.status) }
        }
        monitor.start(queue: DispatchQueue(label: "app.donottype.reachability"))
    }

    public func stop() {
        monitor.cancel()
        isStarted = false
        resumeWaiters()
    }

    /// Suspends until the network is usable. Returns immediately when it already is.
    public func waitUntilOnline() async {
        guard isStarted, currentPath != .satisfied else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func update(_ status: NWPath.Status) {
        let wasOffline = currentPath != .satisfied
        currentPath = status
        if status == .satisfied, wasOffline {
            onlineAgain?()
            resumeWaiters()
        }
    }

    private func resumeWaiters() {
        let pending = waiters
        waiters.removeAll()
        for continuation in pending { continuation.resume() }
    }

    /// Called when connectivity is restored, so a queue can drain itself.
    private var onlineAgain: (@Sendable () -> Void)?

    public func onOnlineAgain(_ handler: @escaping @Sendable () -> Void) {
        onlineAgain = handler
    }
}

/// Turns an error into something a person can act on.
///
/// Every message here answers "what do I do now?". "The operation couldn’t be completed" does not,
/// and neither does a raw 429.
public enum FailureAdvice {
    public struct Guidance: Sendable, Equatable {
        /// One line, shown in the overlay and the history row.
        public var message: String
        /// Whether the dictation is safe and will be sent later.
        public var isQueued: Bool
        /// Whether retrying now is worth it.
        public var isRetryable: Bool
        /// Whether the user has to change something before it can ever work.
        public var needsUserAction: Bool
    }

    public static func describe(_ error: any Error, isOnline: Bool = true) -> Guidance {
        if !isOnline {
            return Guidance(
                message: "Offline — saved, and it will send itself when you reconnect.",
                isQueued: true, isRetryable: true, needsUserAction: false)
        }

        if let providerError = error as? ProviderError {
            switch providerError {
            case .missingAPIKey(let envVar):
                return Guidance(
                    message: "No API key. Add one in Settings, or set \(envVar).",
                    isQueued: false, isRetryable: false, needsUserAction: true)

            case .audioSilentlyDropped:
                return Guidance(
                    message: "This provider accepted the audio but never processed it. Switch "
                        + "provider in Settings — the transcript would have been invented.",
                    isQueued: false, isRetryable: false, needsUserAction: true)

            // Reached by the rewrite hotkey while a speech recognition backend is selected. The
            // dictation itself is unaffected, so this is not a queued failure — there is nothing
            // to retry until the user picks a different provider.
            case .audioRequired:
                return Guidance(
                    message: "This provider only transcribes audio and cannot rewrite text. "
                        + "Choose a model provider in Settings to use rewriting.",
                    isQueued: false, isRetryable: false, needsUserAction: true)

            case .http(let status, let body):
                return describeHTTP(status, body)

            case .emptyOutput:
                return Guidance(
                    message: "Nothing was transcribed. If you did speak, retry from History.",
                    isQueued: true, isRetryable: true, needsUserAction: false)

            case .malformedResponse:
                return Guidance(
                    message: "The provider returned something unreadable — saved, retry from History.",
                    isQueued: true, isRetryable: true, needsUserAction: false)
            }
        }

        let code = (error as NSError).code
        if [
            NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost,
            NSURLErrorTimedOut, NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed,
        ].contains(code) {
            return Guidance(
                message: "Network trouble — saved, and it will send itself when you reconnect.",
                isQueued: true, isRetryable: true, needsUserAction: false)
        }

        return Guidance(
            message: error.localizedDescription, isQueued: true, isRetryable: true,
            needsUserAction: false)
    }

    private static func describeHTTP(_ status: Int, _ body: String = "") -> Guidance {
        // xAI answers a bad key with 400 and a sentence about it, not with 401. Read by status
        // alone that lands in the default branch below and becomes "saved, retry from History" —
        // advice that cannot ever work, offered for a request that will fail identically every
        // time it is retried. Observed live: `HTTP 400: Incorrect API key provided.`
        if status == 400, mentionsAPIKey(body) {
            return Guidance(
                message: "The API key was rejected. Check it in Settings.",
                isQueued: false, isRetryable: false, needsUserAction: true)
        }

        return switch status {
        case 401, 403:
            Guidance(
                message: "The API key was rejected. Check it in Settings.",
                isQueued: false, isRetryable: false, needsUserAction: true)
        case 402:
            Guidance(
                message: "Billing problem on the provider account — the key is valid but has no quota.",
                isQueued: false, isRetryable: false, needsUserAction: true)
        case 404:
            Guidance(
                message: "That model is not available on this account. Pick another in Settings.",
                isQueued: false, isRetryable: false, needsUserAction: true)
        case 429:
            Guidance(
                message: "Rate limited — saved, and it will retry shortly.",
                isQueued: true, isRetryable: true, needsUserAction: false)
        case 500...599:
            Guidance(
                message: "The provider is having trouble — saved, retry from History.",
                isQueued: true, isRetryable: true, needsUserAction: false)
        default:
            Guidance(
                message: "Request failed (HTTP \(status)) — saved, retry from History.",
                isQueued: true, isRetryable: true, needsUserAction: false)
        }
    }

    /// Deliberately narrow. A 400 is normally a request this app got wrong, which is not the
    /// user's problem to fix — only one that names the key is reattributed to the key.
    private static func mentionsAPIKey(_ body: String) -> Bool {
        let lowered = body.lowercased()
        return lowered.contains("api key") || lowered.contains("api_key")
            || lowered.contains("apikey")
    }
}
