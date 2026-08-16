import Foundation

/// The one place a provider request is made, and therefore the one place it can be logged.
///
/// Every backend used to open its own `URLSession.data(for:)` and repeat the same four lines
/// casting the response. That was fine until the question became "what did the app actually send,
/// and what came back?" — which is the first question of every transcription bug report and could
/// only be answered by a proxy or a rebuild. Now it is a log line per request, at `debug`, with no
/// bodies in it: endpoint, model, bytes each way, status and duration.
///
/// Bodies are deliberately absent. A request body is the user's audio and their screen contents,
/// and a response body is their transcript; those go through `Log.content`, which is off unless
/// someone asks for it. What is left is enough to tell a rejected key from a stalled network from
/// a model that answered instantly with nothing.
/// Collects one request's transport timings.
///
/// Attached per task rather than to the session, so this stays a property of `send` and no caller
/// has to build a session a particular way to get it.
final class TransportMetrics: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var collected: URLSessionTaskMetrics?

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        lock.lock()
        collected = metrics
        lock.unlock()
    }

    /// `connect=… ttfb=… reused=…`, or nothing when the system reported no metrics.
    ///
    /// The three numbers that separate the three ways a request can be slow: a handshake that took
    /// seconds, a backend that thought for a long time, and a connection that was reused when it
    /// should not have been. Without them a log line saying `ms=60013` cannot distinguish a dead
    /// connection from a busy model — which is exactly the question that mattered, and the reason
    /// diagnosing the latency tail needed a separate harness rather than this log.
    var summary: [String: String] {
        lock.lock()
        defer { lock.unlock() }
        guard let tx = collected?.transactionMetrics.last else { return [:] }
        func gap(_ a: Date?, _ b: Date?) -> String? {
            guard let a, let b else { return nil }
            return LogClock.ms(b.timeIntervalSince(a))
        }
        var fields = ["reused": tx.isReusedConnection ? "yes" : "no"]
        if let proto = tx.networkProtocolName { fields["proto"] = proto }
        if let connect = gap(tx.connectStartDate, tx.connectEndDate) { fields["connectMs"] = connect }
        if let ttfb = gap(tx.requestEndDate, tx.responseStartDate) { fields["ttfbMs"] = ttfb }
        return fields
    }
}

extension URLSession {
    func send(
        _ request: URLRequest, provider: String, model: String, category: String = "http"
    ) async throws -> (Data, HTTPURLResponse) {
        let log = Log(category)
        let started = Date()
        let outgoing = request.httpBody?.count ?? 0
        let metrics = TransportMetrics()

        log.debug(
            "request",
            [
                "provider": provider, "model": model,
                "url": request.url?.redactedForLog ?? "?",
                "bytes": "\(outgoing)",
            ])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await self.data(for: request, delegate: metrics)
        } catch {
            // The timing matters as much as the message: a connection refused in 4 ms and a read
            // timeout at 25 s are the same `NSError` domain and completely different problems. The
            // transport fields matter for the same reason — `reused=yes connectMs=–` on a request
            // that died at 60 s is a stale pooled connection, and says so without a packet capture.
            log.warning(
                "request failed",
                [
                    "provider": provider, "model": model,
                    "error": error.localizedDescription,
                    "ms": LogClock.ms(Date().timeIntervalSince(started)),
                ].merging(metrics.summary) { current, _ in current })
            throw error
        }

        guard let http = response as? HTTPURLResponse else {
            log.error("no HTTP response", ["provider": provider, "model": model])
            throw ProviderError.malformedResponse("no HTTP response")
        }

        let elapsed = LogClock.ms(Date().timeIntervalSince(started))
        log.debug(
            "response",
            [
                "provider": provider, "model": model, "status": "\(http.statusCode)",
                "bytes": "\(data.count)",
                "ms": elapsed,
            ].merging(metrics.summary) { current, _ in current })

        // A failed response gets its body logged, in full, at a level that is on by default.
        //
        // The rule above — no bodies — is about the user's audio, screen contents and transcript.
        // None of those is in a 4xx or 5xx body: what is in it is the provider saying which field
        // it rejected and why, which is the single most useful thing for diagnosing a failure and
        // the thing that is gone by the time anybody thinks to turn on debug logging. Registered
        // secrets are still redacted on the way out, as everywhere else.
        if !(200...299).contains(http.statusCode) {
            log.warning(
                "error response",
                [
                    "provider": provider, "model": model, "status": "\(http.statusCode)",
                    "url": request.url?.redactedForLog ?? "?",
                    "ms": elapsed,
                    "body": String(decoding: data, as: UTF8.self),
                ])
        }
        return (data, http)
    }
}

extension URL {
    /// The URL with any credential in it removed.
    ///
    /// Not hypothetical: several APIs take the key as `?key=…`, and one of this project's own
    /// providers is configured by pasting a base URL that may carry a token. `Redaction` would
    /// catch most of those by shape; stripping the query values outright catches the rest.
    var redactedForLog: String {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else {
            return absoluteString
        }
        components.queryItems = components.queryItems?.map { item in
            let sensitive = ["key", "api_key", "apikey", "token", "access_token", "auth"]
            return sensitive.contains(item.name.lowercased())
                ? URLQueryItem(name: item.name, value: "‹redacted›")
                : item
        }
        components.user = nil
        components.password = nil
        return components.string ?? absoluteString
    }
}
