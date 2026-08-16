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
///
/// ## Why modulation alone was not enough
///
/// Measured on real recordings this app stored: a single mouse click in a quiet room produced
/// **380 ms** above the floor and sailed through. The floor was −63 dB, so a −37 dB transient sat
/// 26 dB above it — in a silent room *any* sound clears a relative margin. The model then answered
/// that click with 876 characters of invented prose.
///
/// Everything structural was tried against it and failed, because a click and a one-word answer are
/// the same shape:
///
/// | | click | "Yes." | "Undo that." |
/// |---|---|---|---|
/// | detected | 380 ms | 320 ms | 600 ms |
/// | separate bursts | 1 | 1 | 1 |
///
/// A burst-count or duration rule that rejects the first rejects the other two, which is the
/// unforgivable failure rather than the annoying one. What does separate them is where the energy
/// sits: a voice puts a large share of its power at the fundamental and just above, and a click
/// puts almost none there. So a second test applies **only when the first has weak evidence** —
/// under `strongSpeechMilliseconds` — and asks whether the sound is shaped like a voice at all.
///
/// Being a ratio, it is level-independent, which is the property that matters: it cannot undo the
/// quiet-speech case the 200 ms threshold exists for.
///
/// | | voice band | verdict |
/// |---|---|---|
/// | mouse click, quiet room | 23–24% | blocked |
/// | "Yes." / "Okay." (higher-pitched voice) | 39–50% | sent |
/// | ordinary dictation | 47–60% | sent |
///
/// Calibrated on two voices and two clicks, so the margin — 11 points — is the whole of the
/// evidence. That is why it only ever vetoes short clips: a real dictation never reaches it.
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
        /// Share of the speaking frames' energy at and below `voiceBandHertz`, 0 when nothing was
        /// loud enough to measure. A voice sits high here; a click sits low.
        public let voiceBandRatio: Double

        public var hasSpeech: Bool {
            guard speechMilliseconds >= SpeechActivity.minimumSpeechMilliseconds else { return false }
            // Enough speech to be sure on duration alone. The spectral test is for the ambiguous
            // short clip and must never get the chance to veto a real dictation.
            if speechMilliseconds >= SpeechActivity.strongSpeechMilliseconds { return true }
            return voiceBandRatio >= SpeechActivity.minimumVoiceBandRatio
        }

        /// For the log, where a user who disagrees with the decision has to be able to see why.
        public var summary: String {
            String(
                format: "speech=%dms floor=%.1fdB peak=%.1fdB voice=%.0f%% of %.2fs",
                speechMilliseconds, noiseFloorDecibels, peakDecibels, voiceBandRatio * 100,
                durationSeconds)
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

    /// Above this, duration alone settles it and the spectral test is not consulted.
    ///
    /// Set above every ambiguous case measured and below every real dictation: the longest click
    /// produced 380 ms, the shortest genuine dictation 1320 ms. Sitting between them means the
    /// spectral test — the least-evidenced part of this file — can only ever affect clips that are
    /// already doubtful.
    public static let strongSpeechMilliseconds = 700

    /// The share of energy a voice puts at or below `voiceBandHertz`.
    ///
    /// Midway between the two populations measured: clicks at 23–24%, the quietest-scoring real
    /// speech at 39%. See the table above — this number is calibrated on two voices, so it is
    /// deliberately only reachable for short clips.
    public static let minimumVoiceBandRatio = 0.32

    /// Cutoff for the voice-band measurement.
    ///
    /// 250 Hz separated the two populations most widely of the cutoffs measured (100–500 Hz): it
    /// sits above a low male fundamental and below the point where a click's energy begins. Higher
    /// and both populations rise together; lower and the voice's own fundamental falls outside it.
    private static let voiceBandHertz = 250.0

    /// - Parameter pcm: 16 kHz mono 16-bit little-endian samples, without a WAV header.
    public static func measure(pcm: Data, sampleRate: Int = 16_000) -> Reading {
        let frameSamples = sampleRate * frameMilliseconds / 1_000
        let sampleCount = pcm.count / 2
        let duration = Double(sampleCount) / Double(sampleRate)

        guard sampleCount >= frameSamples else {
            return Reading(
                speechMilliseconds: 0, noiseFloorDecibels: -120, peakDecibels: -120,
                durationSeconds: duration, voiceBandRatio: 0)
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
                durationSeconds: duration, voiceBandRatio: 0)
        }

        // The tenth percentile rather than the minimum: one anomalously quiet frame should not
        // define the room, and speech contains real pauses that sit at the floor.
        let sorted = levels.sorted()
        let floor = sorted[min(sorted.count - 1, sorted.count / 10)]
        let peak = sorted[sorted.count - 1]

        let isSpeaking = levels.map { $0 > floor + marginDecibels && $0 > absoluteFloorDecibels }
        let speaking = isSpeaking.filter { $0 }
        return Reading(
            speechMilliseconds: speaking.count * frameMilliseconds,
            noiseFloorDecibels: floor,
            peakDecibels: peak,
            durationSeconds: duration,
            voiceBandRatio: voiceBandRatio(
                pcm: pcm, sampleRate: sampleRate, frameSamples: frameSamples,
                isSpeaking: isSpeaking))
    }

    /// Median share of frame energy surviving a low-pass at `voiceBandHertz`, over the frames that
    /// counted as speech.
    ///
    /// A one-pole filter rather than a transform: this needs to separate two populations that sit
    /// 11 points apart, which a 6 dB/octave roll-off does perfectly well, and it has to be
    /// hand-ported to three other languages without an FFT going subtly different in any of them.
    ///
    /// The filter runs across the whole recording, including the frames that are not speech, so its
    /// state is continuous — restarting it per frame would ring at every boundary and measure the
    /// discontinuity instead of the audio. The median rather than the mean, because one frame of a
    /// door closing should not decide what a sentence was.
    private static func voiceBandRatio(
        pcm: Data, sampleRate: Int, frameSamples: Int, isSpeaking: [Bool]
    ) -> Double {
        let alpha = 1 - exp(-2 * Double.pi * voiceBandHertz / Double(sampleRate))
        var ratios: [Double] = []
        ratios.reserveCapacity(isSpeaking.count)

        pcm.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            var filtered = 0.0
            for (frame, speaking) in isSpeaking.enumerated() {
                let start = frame * frameSamples
                var total = 0.0
                var low = 0.0
                for index in start..<(start + frameSamples) {
                    let value = Double(Int16(littleEndian: samples[index]))
                    filtered += alpha * (value - filtered)
                    guard speaking else { continue }
                    total += value * value
                    low += filtered * filtered
                }
                if speaking, total > 0 { ratios.append(low / total) }
            }
        }

        guard !ratios.isEmpty else { return 0 }
        let sorted = ratios.sorted()
        return sorted[sorted.count / 2]
    }

    /// - Parameter wav: a 16 kHz mono 16-bit WAV, header and all.
    public static func measure(wav: Data) -> Reading {
        guard let body = AudioChunker.pcmBody(of: wav) else {
            return Reading(
                speechMilliseconds: 0, noiseFloorDecibels: -120, peakDecibels: -120,
                durationSeconds: 0, voiceBandRatio: 0)
        }
        return measure(pcm: body)
    }
}
