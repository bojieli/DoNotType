import Foundation

/// The two cues that say a recording started and stopped, as 16-bit PCM in a WAV container.
///
/// Two notes rather than one, because a single sound only reports that *something* happened — which
/// of the two it was is then a question of memory. An interval has a direction, and the ear reads
/// direction before it identifies a timbre: rising to open, the same interval falling to close.
///
/// Here in the core, and not beside the code that plays it, for the reason `ContextEncoder` is:
/// the cue exists on more than one desktop, the ports are written by hand, and drift between them
/// would be silent — Windows would simply sound slightly different, and nothing would fail. What
/// each port owns is the handful of lines that hand these bytes to the platform's audio device.
public enum Tone {
    /// Both cues are anchored on G4 so they are heard as a pair rather than as two noises. Starting
    /// resolves a fourth up to C5, stopping the same fourth down to D4.
    private static let anchor = 392.00
    private static let opening = 523.25
    private static let closing = 293.66

    private static let sampleRate = 48_000.0
    /// The second note enters while the first is still ringing, so the pair reads as one gesture
    /// rather than two beeps; each note is then given a third of a second to decay into silence.
    private static let entry = 0.14
    private static let noteLength = 0.30
    /// Deliberately quiet: this marks a boundary underneath a keystroke, it does not announce an
    /// error. macOS's Tink peaks at 0.365 by comparison. Raise it if the cue gets lost in a room.
    private static let peak = 0.12

    public static func start() -> Data { pair(resolvingTo: opening) }
    public static func stop() -> Data { pair(resolvingTo: closing) }

    private static func pair(resolvingTo second: Double) -> Data {
        var samples = [Double](repeating: 0, count: Int((entry + noteLength) * sampleRate))
        strike(&samples, frequency: anchor, at: 0)
        strike(&samples, frequency: second, at: entry)
        return wav(samples)
    }

    /// A struck-bar voice — fundamental, a quiet octave, and a third partial for the edge that
    /// keeps it from sounding like a test tone — under a shared exponential decay. The four
    /// millisecond attack exists only to stop the onset clicking: a hard start on a sine wave is a
    /// step change in air pressure, and it is audible as one.
    private static func strike(_ samples: inout [Double], frequency: Double, at start: Double) {
        let partials: [(multiple: Double, gain: Double)] = [(1, 1.0), (2, 0.18), (3, 0.22)]
        let offset = Int(start * sampleRate)
        for index in 0..<Int(noteLength * sampleRate) where offset + index < samples.count {
            let time = Double(index) / sampleRate
            let envelope = min(1, time / 0.004) * exp(-time / 0.09)
            let value = partials.reduce(0.0) { sum, partial in
                sum + partial.gain * sin(2 * .pi * frequency * partial.multiple * time)
            }
            samples[offset + index] += value * envelope
        }
    }

    /// Mono 16-bit PCM at 48 kHz.
    ///
    /// A second header writer next to `AudioChunker`'s is deliberate: that one describes the 16 kHz
    /// mono recording every transcription backend is fed, and its rate is baked into callers all
    /// the way out to the decoder. A cue played through the speakers is a different consumer, and
    /// widening the recording path's header to carry it would put a sample rate into eight call
    /// sites to serve two.
    private static func wav(_ samples: [Double]) -> Data {
        // Summing three partials and two overlapping notes overshoots 1.0, so scale by what was
        // actually produced rather than by what the arithmetic was expected to produce.
        let loudest = samples.map(abs).max() ?? 0
        let scale = loudest > 0 ? peak / loudest : 0

        var body = Data(capacity: samples.count * 2)
        for sample in samples {
            let clamped = max(-1, min(1, sample * scale))
            withUnsafeBytes(of: Int16(clamped * 32767).littleEndian) { body.append(contentsOf: $0) }
        }

        var file = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { file.append(contentsOf: $0) }
        }
        file.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + body.count))
        file.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))                      // fmt chunk length
        append(UInt16(1))                       // PCM, uncompressed
        append(UInt16(1))                       // mono
        append(UInt32(sampleRate))
        append(UInt32(sampleRate) * 2)          // bytes per second
        append(UInt16(2))                       // block align
        append(UInt16(16))                      // bits per sample
        file.append(contentsOf: Array("data".utf8))
        append(UInt32(body.count))
        file.append(body)
        return file
    }
}
