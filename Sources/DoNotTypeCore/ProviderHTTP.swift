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
extension URLSession {
    func send(
        _ request: URLRequest, provider: String, model: String, category: String = "http"
    ) async throws -> (Data, HTTPURLResponse) {
        let log = Log(category)
        let started = Date()
        let outgoing = request.httpBody?.count ?? 0

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
            (data, response) = try await self.data(for: request)
        } catch {
            // The timing matters as much as the message: a connection refused in 4 ms and a read
            // timeout at 120 s are the same `NSError` domain and completely different problems.
            log.warning(
                "request failed",
                [
                    "provider": provider, "model": model,
                    "error": error.localizedDescription,
                    "ms": LogClock.ms(Date().timeIntervalSince(started)),
                ])
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
            ])

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
