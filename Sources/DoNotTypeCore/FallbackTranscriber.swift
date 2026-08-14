import Foundation

/// Runs a second backend when the first one is taking too long, and returns whichever answers.
///
/// ## Why this exists
///
/// The first-party Gemini API is the most accurate backend measured — 44/48 on the near-miss
/// suite with a single regression — and its latency is *bimodal* rather than slow. Six sequential
/// requests for one three-second clip took 4.9, 61.6, 50.5, 5.8, 5.9 and 30.2 seconds. Thought
/// tokens are zero at `thinking_level: minimal`, so this is queueing rather than model work.
///
/// A dictation tool that usually answers in five seconds and sometimes in sixty is worse than one
/// that always takes six: the unpredictability is the problem, not the mean. This turns the tail
/// into a bounded wait by starting a fast recogniser once the primary has clearly stalled.
///
/// ## What it deliberately is not
///
/// **Not a race from t=0.** Racing would mean the fast backend almost always wins, which is just
/// "use the fast backend" with double the cost. The hedge starts only after `hedgeAfter`, so a
/// primary that responds normally is never second-guessed and never pays for a second request.
///
/// **Not silent.** The result says which backend produced it, and callers record that in history.
/// A tool whose transcript quality varies invisibly between requests would undermine the thing
/// this project sells, so the variation has to be visible after the fact.
///
/// **Not a retry.** `TranscriptionService.transcribeWithRetry` already handles transient failure.
/// This handles the case where nothing has failed — the request is simply still running.
public struct FallbackTranscriber: Sendable {
    /// Which backend produced the transcript, so history and the UI can say so.
    public struct Attribution: Sendable, Equatable {
        public var provider: String
        public var model: String
        /// True when the primary stalled and the secondary answered first.
        public var wasFallback: Bool

        public init(provider: String, model: String, wasFallback: Bool) {
            self.provider = provider
            self.model = model
            self.wasFallback = wasFallback
        }
    }

    public struct Outcome: Sendable {
        public var result: TranscriptionResult
        public var attribution: Attribution
    }

    public var primary: TranscriptionService
    /// Nil disables hedging entirely, which is the default.
    public var secondary: TranscriptionService?
    /// How long the primary gets on its own before the secondary is started alongside it.
    ///
    /// This dial *is* the accuracy-against-latency trade, and it is exposed rather than tuned
    /// because the right value depends on which backends are paired and how bad the tail is. Long
    /// enough that a normal primary response is never hedged; short enough that the tail is
    /// bounded by roughly this plus the secondary's own latency.
    public var hedgeAfter: Duration

    static let log = Log("fallback")

    public init(
        primary: TranscriptionService,
        secondary: TranscriptionService? = nil,
        hedgeAfter: Duration = .seconds(8)
    ) {
        self.primary = primary
        self.secondary = secondary
        self.hedgeAfter = hedgeAfter
    }

    /// Transcribes, hedging to the secondary if the primary has not answered in time.
    ///
    /// First success wins. Once the hedge fires the faster backend usually does answer first,
    /// which is why `hedgeAfter` is the setting that matters: it decides how much of the primary's
    /// accuracy you are willing to wait for.
    ///
    /// A primary that *fails* rather than stalls hands over immediately — there is nothing left to
    /// wait for. If both fail the primary's error is thrown, because that is the backend the user
    /// chose and its error is the one that explains their configuration.
    public func transcribe(
        audio: AudioFile,
        context: ScreenContext?,
        audioPart: InputPart? = nil,
        verifyNumbers: Bool = false,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> Outcome {
        guard let secondary else {
            let result = try await primary.transcribeLong(
                audio: audio, context: context, audioPart: audioPart,
                verifyNumbers: verifyNumbers, onProgress: onProgress)
            return Outcome(result: result, attribution: attribution(primary, wasFallback: false))
        }

        return try await withThrowingTaskGroup(of: Outcome?.self) { group in
            group.addTask {
                Outcome(
                    result: try await primary.transcribeLong(
                        audio: audio, context: context, audioPart: audioPart,
                        verifyNumbers: verifyNumbers, onProgress: onProgress),
                    attribution: attribution(primary, wasFallback: false))
            }
            group.addTask {
                // The hedge. Sleeping inside the group rather than scheduling separately means
                // cancellation of the winner's siblings also cancels a hedge that never fired,
                // so a fast primary costs nothing at all — not even a pending timer.
                try? await Task.sleep(for: hedgeAfter)
                try Task.checkCancellation()
                // Logged at info: this is the app spending a second request on the user's behalf,
                // and a fallback that fires on every dictation is a misconfigured `hedgeAfter`
                // rather than a working feature. It should be visible without turning anything on.
                Self.log.info(
                    "primary stalled; starting the fallback",
                    [
                        "primary": primary.provider.name, "fallback": secondary.provider.name,
                        "after": "\(hedgeAfter)",
                    ])
                // The pre-uploaded reference is Google's Files API and means nothing to another
                // backend, so the hedge always sends inline bytes. Number verification is skipped
                // too: it spends a second screen-blind request, and the hedge exists because the
                // clock is already the problem.
                return Outcome(
                    result: try await secondary.transcribeLong(
                        audio: audio, context: context, audioPart: nil,
                        verifyNumbers: false, onProgress: nil),
                    attribution: attribution(secondary, wasFallback: true))
            }

            var primaryError: (any Error)?
            var secondaryError: (any Error)?

            // Two chances: whichever finishes first wins, and a failure lets the other keep going
            // rather than failing the dictation.
            for _ in 0..<2 {
                do {
                    if let outcome = try await group.next() ?? nil {
                        group.cancelAll()
                        if outcome.attribution.wasFallback {
                            Self.log.info(
                                "fallback answered first",
                                [
                                    "provider": outcome.attribution.provider,
                                    "model": outcome.attribution.model,
                                ])
                        }
                        return outcome
                    }
                } catch is CancellationError {
                    continue
                } catch {
                    if primaryError == nil { primaryError = error } else { secondaryError = error }
                }
            }
            group.cancelAll()
            _ = secondaryError
            throw primaryError ?? ProviderError.emptyOutput
        }
    }

    private func attribution(
        _ service: TranscriptionService, wasFallback: Bool
    ) -> Attribution {
        Attribution(
            provider: service.provider.name, model: service.model, wasFallback: wasFallback)
    }
}
