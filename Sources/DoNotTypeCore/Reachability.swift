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

        // What the provider itself said, when it said something readable. A status code cannot
        // express "this model does not accept audio input"; the provider can, and it knows what it
        // refused. Appended rather than replacing the advice, because the provider explains what
        // happened and only this app knows what to do about it.
        let detail = message(in: body).map { " \($0)" } ?? ""

        return switch status {
        case 401, 403:
            Guidance(
                message: "The API key was rejected. Check it in Settings.\(detail)",
                isQueued: false, isRetryable: false, needsUserAction: true)
        case 402:
            Guidance(
                message: "Billing problem on the provider account — the key is valid but has no "
                    + "quota.\(detail)",
                isQueued: false, isRetryable: false, needsUserAction: true)
        case 404:
            Guidance(
                message: "That model is not available on this account. Pick another in "
                    + "Settings.\(detail)",
                isQueued: false, isRetryable: false, needsUserAction: true)
        case 413:
            Guidance(
                message: "The recording was too large for the provider. Long ones are normally "
                    + "split automatically, so this is worth reporting.\(detail)",
                isQueued: false, isRetryable: false, needsUserAction: true)
        case 408, 429:
            Guidance(
                message: status == 429
                    ? "Rate limited — saved, and it will retry shortly.\(detail)"
                    : "The provider took too long to answer — saved, retry from History.\(detail)",
                isQueued: true, isRetryable: true, needsUserAction: false)
        case 500...599:
            Guidance(
                message: "The provider is having trouble — saved, retry from History.\(detail)",
                isQueued: true, isRetryable: true, needsUserAction: false)
        default:
            // A 4xx is a request this app got wrong and will get wrong again in exactly the same
            // way, so it is kept but not offered as a retry — that is the argument made above the
            // 400 case, and the default branch was ignoring it and promising a retry for every
            // 4xx it did not specifically handle.
            //
            // `needsUserAction` stays false all the same. There is nothing in Settings that fixes
            // a malformed request, and telling somebody to go and change something when nothing
            // they can change will help is worse than telling them it is not their fault.
            Guidance(
                message: (400..<500).contains(status)
                    ? "The provider rejected the request (HTTP \(status)). Retrying will not "
                        + "change it — this is likely a fault here, and worth reporting.\(detail)"
                    : "Request failed (HTTP \(status)) — saved, retry from History.\(detail)",
                isQueued: true,
                isRetryable: !(400..<500).contains(status),
                needsUserAction: false)
        }
    }

    /// The human-readable part of an error body, if there is one.
    ///
    /// Every OpenAI-compatible provider answers with `{"error": {"message": "…"}}`, and that
    /// sentence is routinely the most useful thing available. It was being read only to sniff for
    /// the words "api key" and then thrown away, so a provider that had explained itself precisely
    /// — "this model does not accept audio input" — produced "Request failed (HTTP 400)".
    ///
    /// Parsed rather than printed raw, so a body that is *not* a sentence (a trace ID, an HTML
    /// error page, a wall of JSON) is dropped instead of shown.
    static func message(in body: String) -> String? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let data = trimmed.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data)
        {
            return message(inJSON: object).flatMap(tidy)
        }

        // Not JSON. A short plain-text body is usually a gateway saying something useful; a long
        // one, or one starting a tag, is an error page.
        guard trimmed.count <= 200, !trimmed.hasPrefix("<") else { return nil }
        return tidy(trimmed)
    }

    /// The shapes providers actually use: `error.message`, a bare `message`, `error` as a string.
    private static func message(inJSON object: Any) -> String? {
        if let text = object as? String { return text.isEmpty ? nil : text }
        guard let dictionary = object as? [String: Any] else { return nil }

        for key in ["message", "error_description", "detail"] {
            if let text = dictionary[key] as? String, !text.isEmpty { return text }
        }
        for key in ["error", "err", "failure"] {
            if let nested = dictionary[key], let found = message(inJSON: nested) { return found }
        }
        return nil
    }

    /// One line, ending in a full stop, short enough to sit in a pill in the corner of a screen.
    private static func tidy(_ text: String) -> String? {
        let flattened = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !flattened.isEmpty else { return nil }

        let capped = flattened.count <= 140
            ? flattened
            : String(flattened.prefix(137)).trimmingCharacters(in: .whitespaces) + "…"
        return capped.hasSuffix(".") || capped.hasSuffix("…") ? capped : capped + "."
    }

    /// Deliberately narrow. A 400 is normally a request this app got wrong, which is not the
    /// user's problem to fix — only one that names the key is reattributed to the key.
    private static func mentionsAPIKey(_ body: String) -> Bool {
        let lowered = body.lowercased()
        return lowered.contains("api key") || lowered.contains("api_key")
            || lowered.contains("apikey")
    }
}
