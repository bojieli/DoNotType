import Foundation

/// The gate on the way back, for audio that got past the gate on the way out.
///
/// `SpeechActivity` refuses to send silence, and it is the better defence because it costs nothing
/// and works for every backend. It is not sufficient. Measured on real dictations from this app: a
/// 0.68-second recording of room tone — a stray tap in a quiet room, 380 ms of transient 25 dB
/// above a −63 dB floor — passed the activity gate, and `gemini-3-flash-preview` answered it with
/// 876 characters of fluent, topically-plausible prose that the user had never said. It was not
/// copied off the screen either: the longest verbatim run shared with the screen context was nine
/// words. The model wrote an essay about what the screen appeared to be discussing.
///
/// That is the single worst thing this project can do, and rule 7 of the prompt does not stop it.
/// Rule 7 asks for "an empty transcript", which is an *omission* — a model already inventing has no
/// way to notice it is failing to omit something. So the prompt now asks for a token the model must
/// positively write, and this checks for it.
///
/// The rate ceiling is the backstop for models that ignore both. It is a physical claim rather than
/// a stylistic one: speech has a maximum rate, and text far above it did not come from the audio.
public enum HallucinationGuard {

    /// What the model writes when it heard nothing. A positive answer, so its absence is
    /// detectable — unlike an empty string, which is indistinguishable from a model that simply
    /// never addressed the question.
    public static let marker = "[NO_SPEECH]"

    /// Characters per second of audio above which the transcript did not come from the speech.
    ///
    /// Fast English narration is ~200 wpm, about 17 characters a second. Real dictations measured
    /// through this app run 7–15. The two fabrications that prompted this guard ran 822 and 1288.
    /// 25 leaves half again the headroom over the fastest plausible speaker and still catches the
    /// failure by a factor of thirty.
    public static let maximumCharactersPerSecond = 25.0

    /// Below this the ratio is not evidence, however extreme it looks.
    ///
    /// Short clips make the rate wild: a two-second recording answered with a single ordinary
    /// sentence is already 35 characters a second, and there is nothing wrong with it. Set at 60
    /// this rejected six of this project's own test fixtures, which is the warning shot — the same
    /// arithmetic would have deleted somebody's short sentence.
    ///
    /// 200 is chosen against the measured failures rather than against the ceiling: the three real
    /// fabrications ran 625, 646 and 876 characters, so the floor sits at a third of the smallest
    /// of them and still admits nothing a person can say quickly. A fabrication shorter than this
    /// is left to the prompt marker and to `SpeechActivity` — which is the right trade under this
    /// project's own rule that typing a stray sentence is annoying and dropping a real one is not.
    public static let minimumSuspiciousCharacters = 200

    /// Why a transcript was suppressed, for the log and for the caller.
    public enum Verdict: Equatable, Sendable {
        case kept
        case noSpeechMarker
        /// Carries the measurement, because "we deleted your words" needs to show its working.
        case impossibleRate(characters: Int, seconds: Double)

        public var summary: String {
            switch self {
            case .kept: "kept"
            case .noSpeechMarker: "model reported no speech"
            case .impossibleRate(let characters, let seconds):
                String(
                    format: "%d chars in %.2fs = %.0f chars/s, ceiling %.0f",
                    characters, seconds, Double(characters) / max(seconds, 0.001),
                    maximumCharactersPerSecond)
            }
        }
    }

    /// Exactly the token the prompt asks for, allowing only surrounding quotes, a full stop and
    /// whitespace.
    ///
    /// Deliberately strict. A looser match on the words "no speech" would silently delete a
    /// dictation of somebody saying them, and the model was told precisely what to write.
    public static func isNoSpeechMarker(_ text: String) -> Bool {
        let noise = CharacterSet(charactersIn: " \t\n\r\"'`.。").union(.whitespacesAndNewlines)
        let stripped = text.trimmingCharacters(in: noise)
        return stripped.caseInsensitiveCompare(marker) == .orderedSame
            || stripped.caseInsensitiveCompare("NO_SPEECH") == .orderedSame
    }

    /// More text than the audio could physically contain.
    ///
    /// `audioSeconds` of nil means the length is unknown — a compressed file whose duration would
    /// cost a decode to learn. Unknown is not suspicious: no measurement, no verdict.
    public static func exceedsPlausibleRate(_ text: String, audioSeconds: Double?) -> Bool {
        guard let audioSeconds, audioSeconds > 0 else { return false }
        let characters = text.trimmed.count
        guard characters >= minimumSuspiciousCharacters else { return false }
        return Double(characters) / audioSeconds > maximumCharactersPerSecond
    }

    /// The whole decision. Returns the transcript to use and why it changed, if it did.
    public static func inspect(_ transcript: Transcript, audioSeconds: Double?)
        -> (transcript: Transcript, verdict: Verdict)
    {
        if isNoSpeechMarker(transcript.transcript) {
            return (Transcript(transcript: "", language: transcript.language), .noSpeechMarker)
        }
        if exceedsPlausibleRate(transcript.transcript, audioSeconds: audioSeconds) {
            return (
                Transcript(transcript: "", language: transcript.language),
                .impossibleRate(
                    characters: transcript.transcript.trimmed.count, seconds: audioSeconds ?? 0)
            )
        }
        return (transcript, .kept)
    }
}
