import Foundation

/// Turns captured samples into the bars the recording pill draws.
///
/// ## Why this is not a multiplier
///
/// The meter used to be `min(1, rms * 6)`: a linear scale, on a signal whose useful range spans
/// 50 dB. Measured over every speech fixture in `eval/audio/`, in the 20 ms frames that sit clearly
/// above each recording's own noise floor — the frames somebody is actually talking in:
///
/// | fixture | frames pinned at full scale |
/// |---|---|
/// | `port-number` | 77% |
/// | `novel-repo` | 77% |
/// | `jargon-spelling` | 75% |
/// | `git-command` | 64% |
/// | `speech` | 59% |
/// | `real-brand` | 35% |
/// | `real-jargon` | 10% |
/// | `real-mandarin` | 4% |
///
/// So on a normally-recorded voice the old bars spent most of their time flat against the ceiling,
/// and the rest of the time somewhere between a third and half height. That is a light that says
/// "on", not a meter: it cannot answer *how loud*, which is the question somebody looks at it to
/// ask. At the other end the same multiplier gives room tone — a fixture at −58 dBFS — a visible
/// 0.01 of a bar, and quiet speech barely more.
///
/// Decibels are how loudness is measured because they are how loudness is heard, so the scale is
/// decibels, and the span is chosen from the same measurements:
///
/// | input | dBFS | bar |
/// |---|---|---|
/// | digital silence | −240 | 0.00 |
/// | room tone | −58 | 0.04 |
/// | quiet speech (p10 of speaking frames) | −44 | 0.29 |
/// | conversational speech (median) | −21 | 0.72 |
/// | loud speech (p90) | −14 | 0.85 |
/// | the loudest frame in any fixture | −5 | 1.00 |
///
/// Speech now lands in the top third and moves visibly within it, silence is flat, and a full bar
/// means what a full bar should mean: the input is at the edge of clipping. `isClipping` marks the
/// frames that are actually there, because a meter that pins without saying why is the state the
/// old one was in permanently.
///
/// ## Why frames rather than a smoothed value
///
/// The pill draws a moving history, so each bar is a moment rather than a running average, and the
/// shape that walks across it is the envelope of the speech — syllables, pauses and all. Smoothing
/// would flatten exactly the detail that makes the meter read as *your voice* rather than as an
/// animation playing next to it. What silence looks like is a flat line still scrolling: the mic is
/// live and hearing nothing, which is a different report from a frozen meter, and the one somebody
/// who is not being heard needs to see.
public struct AudioLevelMeter: Sendable {
    /// One bar of the meter.
    public struct Bar: Sendable, Equatable {
        /// 0…1, ready to scale a bar height by.
        public let level: Double
        /// The input reached within `clippingDecibels` of full scale, where samples start being
        /// clamped and the recording is distorted before any backend sees it. Usually input gain
        /// set too high, which nothing else in the app would ever tell the user.
        ///
        /// Deliberately not the same threshold as a full bar. There is 3 dB between "using all of
        /// the meter", which a loud sentence should do, and "being damaged", which it should not,
        /// and a warning that fires on the first is a warning nobody reads by the second.
        public let isClipping: Bool

        public init(level: Double, isClipping: Bool) {
            self.level = level
            self.isClipping = isClipping
        }

        public static let silent = Bar(level: 0, isClipping: false)
    }

    /// An empty bar. Below room tone, so a quiet room reads as flat rather than as a low rumble.
    public static let floorDecibels = -60.0
    /// A full bar. Just under the loudest frame measured in any fixture, so a voice recorded at a
    /// sensible level uses the top of the meter without living there.
    public static let ceilingDecibels = -6.0
    /// Where a bar is marked as clipping.
    public static let clippingDecibels = -3.0

    /// Matches `SpeechActivity`, so the two agree about what a frame is.
    public static let frameMilliseconds = 20
    /// 60 ms a bar. Long enough that a full meter is a second and a half of speech rather than
    /// half a second of it, short enough to resolve individual syllables.
    public static let framesPerBar = 3

    /// The 0…1 height for one frame's level. Pure, so the table above can be asserted directly.
    public static func bar(decibels: Double) -> Bar {
        let span = ceilingDecibels - floorDecibels
        return Bar(
            level: min(1, max(0, (decibels - floorDecibels) / span)),
            isClipping: decibels >= clippingDecibels)
    }

    private let frameLength: Int
    private var frameEnergy = 0.0
    private var frameSamples = 0
    /// Bars peak-hold their frames: a transient that only exists for 20 ms is exactly the thing a
    /// meter must not average away, since it is what clips.
    private var barPeak = -Double.infinity
    private var barFrames = 0

    public init(sampleRate: Double = 16_000) {
        frameLength = max(1, Int(sampleRate * Double(Self.frameMilliseconds) / 1_000))
    }

    /// Feeds captured samples in and returns whatever bars they completed.
    ///
    /// Partial frames are carried across calls, because the caller hands over whatever the audio
    /// tap gave it and that is never a whole number of frames.
    ///
    /// - Parameter samples: 16-bit mono PCM at the rate this was initialised with.
    public mutating func append(_ samples: some Sequence<Int16>) -> [Bar] {
        var bars: [Bar] = []
        for sample in samples {
            let value = Double(sample) / 32_768.0
            frameEnergy += value * value
            frameSamples += 1
            guard frameSamples == frameLength else { continue }

            // The same epsilon as `SpeechActivity`: digital silence is a number rather than
            // negative infinity, and the number it is is −120 dBFS.
            let decibels = 10 * log10(frameEnergy / Double(frameLength) + 1e-12)
            frameEnergy = 0
            frameSamples = 0

            barPeak = max(barPeak, decibels)
            barFrames += 1
            guard barFrames == Self.framesPerBar else { continue }

            bars.append(Self.bar(decibels: barPeak))
            barPeak = -.infinity
            barFrames = 0
        }
        return bars
    }
}
