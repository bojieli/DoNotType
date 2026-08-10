import Foundation

/// Splits a long recording on silence so it can be transcribed in parallel.
///
/// A nine-minute dictation is roughly 17,000 audio tokens and a single request for it runs well
/// past any reasonable latency budget — the user has stopped talking and is waiting. Splitting on
/// silence and transcribing the pieces concurrently turns that into roughly the cost of the
/// slowest chunk.
///
/// Two rules make the seams survivable. Cuts land in silence, never mid-word, so no chunk begins
/// or ends on half a syllable. And every chunk is sent with the *same* screen context, which is
/// what keeps a name spelled consistently across a boundary — the alternative is chunk three
/// spelling something differently from chunk two for no reason the user can see.
public enum AudioChunker {
    /// Below this, one request is faster than the coordination.
    public static let threshold: TimeInterval = 90

    public struct Chunk: Sendable, Equatable {
        public let index: Int
        public let data: Data
        public let startSeconds: Double
        public let durationSeconds: Double
    }

    public struct Format: Sendable {
        public var sampleRate: Int
        public var channels: Int
        public var bitsPerSample: Int

        public init(sampleRate: Int = 16_000, channels: Int = 1, bitsPerSample: Int = 16) {
            self.sampleRate = sampleRate
            self.channels = channels
            self.bitsPerSample = bitsPerSample
        }

        var bytesPerSecond: Int { sampleRate * channels * bitsPerSample / 8 }
    }

    /// Splits 16-bit PCM WAV data, or returns a single chunk when it is short enough.
    ///
    /// - Parameters:
    ///   - target: preferred chunk length. Cuts are placed at the quietest point in a window
    ///     around it rather than exactly on it.
    ///   - window: how far either side of the target to search for silence.
    public static func split(
        wav: Data,
        format: Format = Format(),
        target: TimeInterval = 60,
        window: TimeInterval = 15
    ) -> [Chunk] {
        guard let body = pcmBody(of: wav) else {
            return [Chunk(index: 0, data: wav, startSeconds: 0, durationSeconds: 0)]
        }

        let duration = Double(body.count) / Double(format.bytesPerSecond)
        guard duration > threshold else {
            return [Chunk(index: 0, data: wav, startSeconds: 0, durationSeconds: duration)]
        }

        var chunks: [Chunk] = []
        var start = 0

        while start < body.count {
            let remaining = body.count - start
            let targetBytes = Int(target * Double(format.bytesPerSecond))

            // A final piece shorter than the search window is folded into this one rather than
            // left as a two-second fragment that transcribes badly on its own.
            if remaining <= targetBytes + Int(window * Double(format.bytesPerSecond)) {
                chunks.append(
                    makeChunk(
                        index: chunks.count, body: body, range: start..<body.count, format: format))
                break
            }

            let cut = quietestCut(
                in: body, around: start + targetBytes,
                window: Int(window * Double(format.bytesPerSecond)), format: format)
            chunks.append(
                makeChunk(index: chunks.count, body: body, range: start..<cut, format: format))
            start = cut
        }
        return chunks
    }

    // MARK: - Private

    private static func makeChunk(
        index: Int, body: Data, range: Range<Int>, format: Format
    ) -> Chunk {
        let samples = body.subdata(in: range)
        return Chunk(
            index: index,
            data: wrapInWavContainer(samples, format: format),
            startSeconds: Double(range.lowerBound) / Double(format.bytesPerSecond),
            durationSeconds: Double(samples.count) / Double(format.bytesPerSecond))
    }

    /// Finds the middle of the quietest 100 ms inside the search window.
    ///
    /// Quietest rather than "first below a threshold": an absolute threshold tuned for a quiet
    /// room finds no silence at all on a train, and would then cut mid-word.
    ///
    /// The *middle* rather than the start, so both neighbours keep a little silence. A chunk whose
    /// audio begins on the first sample of a word tends to lose that word's opening consonant, and
    /// one that ends flush against speech gives the model no cue that the utterance finished.
    static func quietestCut(in body: Data, around centre: Int, window: Int, format: Format) -> Int {
        let bytesPerSample = format.bitsPerSample / 8 * format.channels
        let probe = max(bytesPerSample, format.bytesPerSecond / 10)  // 100 ms

        let low = max(0, centre - window)
        let high = min(body.count - probe, centre + window)
        guard low < high else { return min(centre, body.count) }

        var quietest = centre
        var quietestEnergy = Double.greatestFiniteMagnitude
        var position = low

        // Coarse stride: sample energy every 20 ms rather than at every offset. The cut only has
        // to land somewhere quiet, not at the single quietest byte.
        let stride = max(bytesPerSample, format.bytesPerSecond / 50)
        while position < high {
            let energy = meanEnergy(of: body, at: position, length: probe)
            if energy < quietestEnergy {
                quietestEnergy = energy
                quietest = position
            }
            position += stride
        }
        // Align to a sample boundary; a cut mid-sample produces a click.
        let middle = min(quietest + probe / 2, body.count)
        return middle - (middle % bytesPerSample)
    }

    private static func meanEnergy(of body: Data, at offset: Int, length: Int) -> Double {
        var total = 0.0
        var count = 0
        var index = offset
        let end = min(offset + length, body.count - 1)

        while index < end {
            let sample = Int16(bitPattern: UInt16(body[index]) | (UInt16(body[index + 1]) << 8))
            total += Double(sample) * Double(sample)
            count += 1
            index += 2
        }
        return count == 0 ? .greatestFiniteMagnitude : total / Double(count)
    }

    /// Locates the `data` chunk, so a WAV with extra metadata chunks is handled correctly.
    static func pcmBody(of wav: Data) -> Data? {
        guard wav.count > 44, wav.prefix(4) == Data("RIFF".utf8) else { return nil }

        var cursor = 12
        while cursor + 8 <= wav.count {
            let id = wav.subdata(in: cursor..<(cursor + 4))
            let size = Int(
                UInt32(wav[cursor + 4]) | (UInt32(wav[cursor + 5]) << 8)
                    | (UInt32(wav[cursor + 6]) << 16) | (UInt32(wav[cursor + 7]) << 24))

            if id == Data("data".utf8) {
                let start = cursor + 8
                let end = min(start + size, wav.count)
                return start < end ? wav.subdata(in: start..<end) : nil
            }
            cursor += 8 + size + (size % 2)  // chunks are word-aligned
        }
        return nil
    }

    static func wrapInWavContainer(_ pcm: Data, format: Format) -> Data {
        var header = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) }
        }

        header.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + pcm.count))
        header.append(contentsOf: Array("WAVE".utf8))
        header.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))  // PCM
        append(UInt16(format.channels))
        append(UInt32(format.sampleRate))
        append(UInt32(format.bytesPerSecond))
        append(UInt16(format.channels * format.bitsPerSample / 8))
        append(UInt16(format.bitsPerSample))
        header.append(contentsOf: Array("data".utf8))
        append(UInt32(pcm.count))
        return header + pcm
    }

    /// Joins transcribed chunks.
    ///
    /// Chunks are cut in silence, so a plain join with a space is right — inserting punctuation
    /// would be inventing content, and the fidelity rules forbid that as firmly at a seam as
    /// anywhere else.
    public static func stitch(_ pieces: [String]) -> String {
        pieces
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
