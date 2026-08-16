import Foundation

/// Sends a second identical request when the first one has stalled, and keeps whichever answers.
///
/// ## Why
///
/// Transcription latency is *bimodal* rather than slow. Six sequential requests for one
/// three-second clip took 4.9, 61.6, 50.5, 5.8, 5.9 and 30.2 seconds, with zero thought tokens
/// throughout. A dictation tool that usually answers in five seconds and sometimes in sixty is
/// worse than one that always takes six, and the fix for a draw that landed in the tail is
/// another draw.
///
/// ## What that evidence was actually showing — read this before tuning anything here
///
/// The spread above was originally read as provider-side queueing. It was not, and the difference
/// decides whether this type can work at all.
///
/// Replaying one recording with its screen context 102 times over twenty minutes, on connections
/// that were being used continuously, gave p50 2.10 s, p95 2.62 s, worst 4.07 s, and no failures.
/// The bimodality disappears entirely when the connection is warm. What produced it was a pooled
/// TCP connection going bad while idle — see `ProviderTransport` for the measurements and the
/// mechanism.
///
/// That mattered here because a duplicate request used to be sent on the same `URLSession`, which
/// HTTP/2 multiplexed onto the same connection. So the "second draw" was the same draw. In the
/// history that motivated this file, the hedge fired three times and lost three times, each time
/// failing in the same millisecond as the request it was hedging — once at 51.8 s, without having
/// reached any timeout of its own, because the connection under it died.
///
/// A hedge is therefore only a hedge if it gets its own connection, which is what `isHedge` is
/// for: the caller turns it into `ConnectionPreference.fresh`. Anyone changing that back should
/// know they are turning this file into a way to spend twice as much on the same answer.
///
/// ## When a request counts as stalled
///
/// Two conditions, both of which must hold: it has been running for at least ``floorSeconds``,
/// *and* for at least ``audioFraction`` of the recording's own length. Equivalently, the deadline
/// is the larger of the two — see ``deadlineSeconds(audioSeconds:)``.
///
/// The floor exists because eight seconds is a normal response for a short clip and re-sending it
/// would double the bill on requests that were never in trouble. The share-of-audio term exists
/// because "slow" is relative to how much speech was sent: eight seconds is a stall for a
/// three-second clip and a good pace for a four-minute one, and a fixed floor alone would hedge
/// every long recording.
///
/// ## What it deliberately is not
///
/// **Not a timeout.** The first request is not abandoned at the deadline — it keeps running, and
/// if it answers first it wins. Cancelling it would throw away a request that has already paid its
/// queueing cost and might be one second from returning, so the same two requests would cost the
/// same money and take longer. First answer wins is never slower than starting over.
///
/// **Not a race from t=0.** A request answering normally is never second-guessed and never pays
/// for a duplicate. Only the tail is hedged, which is what keeps the cost of this bounded to the
/// fraction of requests that were going badly anyway.
///
/// **Not a retry.** ``TranscriptionService/transcribeWithRetry(audio:context:attempts:initialDelay:)``
/// handles requests that *failed*; this handles the case where nothing has failed and the request
/// is simply still running. The two compose: a failure before the deadline throws straight away
/// rather than sitting out the rest of it, because the retry ladder's backoff will try again
/// sooner than the hedge would.
///
/// **Not the provider fallback.** ``FallbackTranscriber`` reaches for a *different* backend on the
/// same symptom, and is off unless a second provider is configured. This one re-asks the backend
/// the user chose, so the transcript comes from the model they picked either way.
public enum StallHedge {
    /// No request is called stalled before this, however short the recording.
    public static let floorSeconds: Double = 8

    /// The share of the recording's own length a request may take before it counts as stalled.
    public static let audioFraction: Double = 0.25

    /// How long a request gets before a second one is sent alongside it.
    ///
    /// Unknown durations — a compressed file whose length is not readable without decoding it —
    /// get the floor, which is the same answer as for any recording under 32 seconds.
    public static func deadlineSeconds(audioSeconds: Double?) -> Double {
        max(floorSeconds, (audioSeconds ?? 0) * audioFraction)
    }

    /// Marks a failure as the duplicate's, so it can be told apart from the original's.
    ///
    /// Which of the two failed matters twice over: the original's error is the one the caller is
    /// shown, and only the original's says anything about whether there is a second request left
    /// to wait for.
    private struct HedgeFailure: Error {
        var underlying: any Error
    }

    /// Runs `attempt`, starting a second one if the first has not answered within the deadline.
    ///
    /// First success wins and the loser is cancelled. If both fail, the *original* request's
    /// failure is the one thrown — not whichever failed first. The duplicate is this type's idea
    /// rather than the caller's, so its error is a worse explanation of what is wrong: the two can
    /// differ, and it is the request the caller asked for whose failure describes their setup.
    ///
    /// `attempt` is called twice at most, so it must be safe to run concurrently with itself —
    /// which for an HTTP request it is, and for anything that writes to shared state it is not.
    ///
    /// It is told which of the two it is. The duplicate has to reach the backend by a route the
    /// original is not already stuck on, and only the caller knows what that means; passing the
    /// flag keeps this type from having to know anything about connections.
    public static func race<T: Sendable>(
        deadlineSeconds: Double,
        onHedge: @escaping @Sendable () -> Void = {},
        attempt: @escaping @Sendable (_ isHedge: Bool) async throws -> T
    ) async throws -> T {
        guard deadlineSeconds > 0 else { return try await attempt(false) }

        let deadline = Duration.seconds(deadlineSeconds)
        // Monotonic rather than wall-clock: the elapsed time below decides whether a second request
        // is in flight, and a clock that can step backwards would answer that wrongly.
        let started = ContinuousClock.now

        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await attempt(false) }
            group.addTask {
                // Sleeping inside the group rather than scheduling separately means cancelling the
                // winner's siblings also cancels a hedge that never fired, so a request that
                // answers normally costs nothing at all — not even a pending timer.
                try await Task.sleep(for: deadline)
                onHedge()
                do {
                    return try await attempt(true)
                } catch {
                    throw HedgeFailure(underlying: error)
                }
            }

            var originalFailure: (any Error)?
            var hedgeFailure: (any Error)?

            // Two chances: whichever answers first wins, and one failing lets the other keep going
            // rather than failing the whole thing.
            for _ in 0..<2 {
                do {
                    guard let value = try await group.next() else { break }
                    group.cancelAll()
                    return value
                } catch let failure as HedgeFailure {
                    hedgeFailure = failure.underlying
                } catch is CancellationError {
                    continue
                } catch {
                    originalFailure = error
                    // Before the deadline nothing else is running — the hedge is still asleep — so
                    // there is nothing to wait for and the caller gets its error now.
                    if started.duration(to: .now) < deadline {
                        group.cancelAll()
                        throw error
                    }
                }
            }

            group.cancelAll()
            throw originalFailure ?? hedgeFailure ?? CancellationError()
        }
    }
}
