import Foundation

/// The gate for a transcript that is *too short* for the audio.
///
/// `HallucinationGuard` catches a model that invented words. This catches the opposite, and until
/// it existed nothing did: a model that stopped early and returned fluent, plausible text with the
/// middle of the dictation missing. The two are not symmetric problems. Fabrication is loud once
/// you look for it — 822 characters against a 0.68-second recording. Truncation is silent, because
/// what comes back reads perfectly; it is only wrong in what it does not say.
///
/// ## The failure this was built from
///
/// Measured 2026-08-25 on a 90-second Mandarin recording. `gemini-3.5-flash` at `minimal` returned
/// roughly 100 characters of a 310-character transcript, stopping mid-sentence at the identical
/// point every time it failed, on **6 runs in 10**. `gemini-3.6-flash` did it 0 times in 20. It is
/// not the output-token cap: 310 characters is nowhere near `maxOutputTokens`.
///
/// It sailed past every existing check. `HallucinationGuard`'s rate ceiling is a *maximum*, and
/// 1.1 characters a second passes it by being below the floor of suspicion rather than above the
/// ceiling. The `[NO_SPEECH]` marker was not written, because the model did transcribe — just not
/// all of it. Nothing in the pipeline had an opinion about a transcript being too small.
///
/// ## Why the denominator is speech and not recording length
///
/// Characters per second of *recording* cannot separate the two cases. Across 350 real dictations
/// the legitimate minimum is 1.55 characters a second of audio, and the truncated transcript here
/// ran 1.09 — a margin of 1.4×, which is not a threshold, it is a coin toss. The confound is
/// silence: speech is 14% to 61% of a recording's length, so a thoughtful speaker with long pauses
/// looks exactly like a truncated transcript.
///
/// Against Silero-confirmed *speech* the two separate cleanly:
///
/// | | characters per second of speech |
/// |---|---|
/// | the truncated runs | 2.00, 2.27 |
/// | complete runs of the same recording | 6.31, 7.78 |
/// | **minimum across 350 real dictations** | **4.92** |
///
/// Both language groups sit well above the floor — Latin dictations bottom out at 8.81, Mandarin
/// at 4.92 — so one constant serves both, which a per-recording-second threshold could not do.
///
/// ## Why the threshold sits where it does
///
/// The costs either side are wildly asymmetric. A false positive spends one extra request the user
/// never sees. A false negative hands somebody a plausible transcript with their words deleted, and
/// they may not notice for a long time — which is the single worst outcome this project has. So the
/// floor is placed nearer the legitimate minimum than the observed failure: 1.4× below the lowest
/// real dictation measured, and 1.5× above the highest truncation measured.
public enum TruncationGuard {
    /// Characters per second of Silero-confirmed speech below which a transcript is suspect.
    public static let minimumCharactersPerSecond = 3.5

    /// Below this much speech the ratio is not evidence.
    ///
    /// Short clips make the rate wild in both directions, and truncation is a long-audio failure —
    /// 0 occurrences in 30 whole-file runs across six recordings under two minutes that did not
    /// reproduce it. The same reasoning as `HallucinationGuard.minimumSuspiciousCharacters`, from
    /// the other end.
    public static let minimumSpeechSeconds = 20.0

    /// Cheap pre-filter, so the expensive check runs only on plausible candidates.
    ///
    /// Characters per second of recording cannot *decide* anything — see above — but it bounds the
    /// question for free, from a WAV header rather than a model. The fifth percentile of real
    /// dictations is 3.16 and the median 7.57, so this admits roughly the bottom tenth for a
    /// second look and leaves the other nine tenths untouched.
    public static let screeningCharactersPerSecond = 4.0

    /// Why a transcript was flagged, carrying its measurement so the log can be argued with.
    public enum Verdict: Equatable, Sendable {
        case kept
        case suspectedTruncation(characters: Int, speechSeconds: Double)

        public var isSuspect: Bool {
            if case .suspectedTruncation = self { return true }
            return false
        }

        public var summary: String {
            switch self {
            case .kept: "kept"
            case .suspectedTruncation(let characters, let speechSeconds):
                String(
                    format: "%d chars in %.1fs of speech = %.2f chars/s, floor %.2f",
                    characters, speechSeconds,
                    Double(characters) / max(speechSeconds, 0.001),
                    minimumCharactersPerSecond)
            }
        }
    }

    /// Whether this transcript is worth measuring properly. Costs a subtraction.
    public static func warrantsInspection(_ text: String, audioSeconds: Double?) -> Bool {
        guard let audioSeconds, audioSeconds > 0 else { return false }
        return Double(text.trimmed.count) / audioSeconds < screeningCharactersPerSecond
    }

    /// The verdict, given how much speech the recording actually contains.
    ///
    /// Unknown speech length yields `.kept`: no measurement, no accusation. That matches
    /// `HallucinationGuard`, and it matters more here, because the remedy for a suspicion is to
    /// spend another request rather than to delete anything.
    public static func inspect(_ text: String, speechSeconds: Double?) -> Verdict {
        guard let speechSeconds, speechSeconds >= minimumSpeechSeconds else { return .kept }
        let characters = text.trimmed.count
        guard characters > 0 else { return .kept }
        let rate = Double(characters) / speechSeconds
        guard rate < minimumCharactersPerSecond else { return .kept }
        return .suspectedTruncation(characters: characters, speechSeconds: speechSeconds)
    }
}
