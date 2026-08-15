import Foundation

/// Whether a recording contains anything worth sending.
///
/// ## Why this exists
///
/// A speech model handed silence does not reliably return silence. Asked to transcribe three
/// seconds of room tone it will often produce a plausible sentence — the well-documented case is a
/// stock phrase like "Thank you." or a subtitle credit — and a dictation tool that types that into
/// somebody's document has invented words they never said. That is the single failure this project
/// exists to prevent, so a rule in `PROMPT.md` is not enough on its own:
///
/// - **`PROMPT.md` rule 7 only reaches model providers.** Deepgram, xAI and Mistral Voxtral are
///   speech recognition endpoints with no system instruction at all, so the rule that says "silent
///   or unintelligible audio returns an empty transcript" is never sent to them. Whisper-family
///   recognisers are exactly the ones most documented for this behaviour.
/// - **An instruction is a request, not a guarantee**, even where it is delivered.
///
/// A backend cannot hallucinate audio it never received. So the audio is checked here, before the
/// request, and that check is the only defence that holds for every backend.
///
/// ## How it decides
///
/// Not by loudness. A quiet room and quiet speech have similar absolute levels, and gating on
/// volume would discard somebody dictating in an open-plan office — a much worse failure than the
/// one being prevented. What separates speech from noise is *modulation*: speech has syllables,
/// pauses and plosives, so its frame energies vary; a fan, a hum or a mains buzz does not.
///
/// So each 20 ms frame is compared against the recording's own noise floor, and what is counted is
/// how much audio sits clearly above that floor. Measured on the fixtures in
/// `eval/audio/silence/`, with real speech from `eval/audio/formats/`:
///
/// | audio | detected |
/// |---|---|
/// | digital silence | 0 ms |
/// | room tone | 0 ms |
/// | a fan or air conditioning | 0 ms |
/// | 50 Hz mains hum | 0 ms |
/// | one keyboard click | 20 ms |
/// | speech | 1160 ms |
/// | speech at −32 dB | 1160 ms |
/// | speech at −46 dB | 800 ms |
/// | speech at −52 dB | 240 ms |
///
/// The threshold is 200 ms: ten times the loudest non-speech fixture, and a quarter of speech so
/// attenuated it is barely audible. The margin is deliberately lopsided — a stray "Thank you." is
/// annoying, and dropping a sentence somebody actually said is unforgivable, so when the two risks
/// trade off this errs towards sending.
public enum SpeechActivity {
    /// What the audio looked like, kept whole so a wrong decision can be argued with.
    public struct Reading: Sendable, Equatable {
        /// How much audio sat clearly above the recording's own noise floor.
        public let speechMilliseconds: Int
        /// The recording's own floor, in dBFS. Roughly the room.
        public let noiseFloorDecibels: Double
        /// The loudest 20 ms in the recording, in dBFS.
        public let peakDecibels: Double
        public let durationSeconds: Double

        public var hasSpeech: Bool { speechMilliseconds >= SpeechActivity.minimumSpeechMilliseconds }

        /// For the log, where a user who disagrees with the decision has to be able to see why.
        public var summary: String {
            String(
                format: "speech=%dms floor=%.1fdB peak=%.1fdB of %.2fs",
                speechMilliseconds, noiseFloorDecibels, peakDecibels, durationSeconds)
        }
    }

    /// Below this, nothing is sent. See the table above for where it came from.
    public static let minimumSpeechMilliseconds = 200

    /// How far above the recording's own floor a frame has to sit to count as speech.
    ///
    /// 8 dB is roughly the difference between a room and somebody talking in it. Steady noise —
    /// which has no dynamics at all — never reaches it, whatever its absolute level.
    private static let marginDecibels = 8.0

    /// A floor below which nothing counts, however far above the noise it is.
    ///
    /// Guards the degenerate case: in a recording of digital silence with a single dithered
    /// sample, that sample is infinitely above the floor. Set low enough that real speech never
    /// reaches it — the quietest speech measured above still peaks well over this.
    private static let absoluteFloorDecibels = -65.0

    private static let frameMilliseconds = 20

    /// - Parameter pcm: 16 kHz mono 16-bit little-endian samples, without a WAV header.
    public static func measure(pcm: Data, sampleRate: Int = 16_000) -> Reading {
        let frameSamples = sampleRate * frameMilliseconds / 1_000
        let sampleCount = pcm.count / 2
        let duration = Double(sampleCount) / Double(sampleRate)

        guard sampleCount >= frameSamples else {
            return Reading(
                speechMilliseconds: 0, noiseFloorDecibels: -120, peakDecibels: -120,
                durationSeconds: duration)
        }

        var levels: [Double] = []
        levels.reserveCapacity(sampleCount / frameSamples)

        pcm.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            var start = 0
            while start + frameSamples <= sampleCount {
                var energy = 0.0
                for index in start..<(start + frameSamples) {
                    let value = Double(Int16(littleEndian: samples[index]))
                    energy += value * value
                }
                let mean = energy / Double(frameSamples)
                // dBFS, with a floor so digital silence is a number rather than negative infinity.
                levels.append(10 * log10(mean / (32_768.0 * 32_768.0) + 1e-12))
                start += frameSamples
            }
        }

        guard !levels.isEmpty else {
            return Reading(
                speechMilliseconds: 0, noiseFloorDecibels: -120, peakDecibels: -120,
                durationSeconds: duration)
        }

        // The tenth percentile rather than the minimum: one anomalously quiet frame should not
        // define the room, and speech contains real pauses that sit at the floor.
        let sorted = levels.sorted()
        let floor = sorted[min(sorted.count - 1, sorted.count / 10)]
        let peak = sorted[sorted.count - 1]

        let speaking = levels.filter { $0 > floor + marginDecibels && $0 > absoluteFloorDecibels }
        return Reading(
            speechMilliseconds: speaking.count * frameMilliseconds,
            noiseFloorDecibels: floor,
            peakDecibels: peak,
            durationSeconds: duration)
    }

    /// - Parameter wav: a 16 kHz mono 16-bit WAV, header and all.
    public static func measure(wav: Data) -> Reading {
        guard let body = AudioChunker.pcmBody(of: wav) else {
            return Reading(
                speechMilliseconds: 0, noiseFloorDecibels: -120, peakDecibels: -120,
                durationSeconds: 0)
        }
        return measure(pcm: body)
    }
}
