import ArgumentParser
import DoNotTypeCore
import Foundation

/// Re-encodes a WAV fixture to Ogg Opus using the app's own encoder.
///
/// Exists so the container being tested is the one that ships, rather than something ffmpeg
/// produced that happens to look similar. A hand-written muxer that only its own tests accept is
/// worth nothing.
struct Encode: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Re-encode a WAV recording to Ogg Opus with the app's encoder.")

    @Argument(help: "Path to a 16 kHz mono WAV.")
    var input: String

    @Argument(help: "Where to write the .opus file.")
    var output: String

    mutating func run() async throws {
        let wav = try Data(contentsOf: URL(fileURLWithPath: input))
        let ogg = try OpusEncoder().encode(wav: wav)
        try ogg.write(to: URL(fileURLWithPath: output))

        let ratio = wav.count > 0 ? Double(ogg.count) / Double(wav.count) : 0
        print("\(wav.count) B wav → \(ogg.count) B ogg  (\(String(format: "%.1f", 1 / max(ratio, 0.0001)))× smaller)")
    }
}
