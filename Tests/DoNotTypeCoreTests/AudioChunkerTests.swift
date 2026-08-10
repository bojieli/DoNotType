import Foundation
import XCTest

@testable import DoNotTypeCore

final class AudioChunkerTests: XCTestCase {
    private let format = AudioChunker.Format(sampleRate: 16_000, channels: 1, bitsPerSample: 16)

    /// Builds a WAV whose loud passages are separated by true silence, so a correct splitter has
    /// somewhere obvious to cut and an incorrect one has somewhere obvious to be caught.
    private func speech(
        segments: [(loudSeconds: Double, silenceSeconds: Double)]
    ) -> Data {
        var pcm = Data()
        var phase = 0.0

        for segment in segments {
            for _ in 0..<Int(segment.loudSeconds * Double(format.sampleRate)) {
                phase += 2 * Double.pi * 220 / Double(format.sampleRate)
                let sample = Int16(sin(phase) * 12_000)
                pcm.append(UInt8(truncatingIfNeeded: sample))
                pcm.append(UInt8(truncatingIfNeeded: sample >> 8))
            }
            pcm.append(
                Data(
                    repeating: 0,
                    count: Int(segment.silenceSeconds * Double(format.sampleRate)) * 2))
        }
        return AudioChunker.wrapInWavContainer(pcm, format: format)
    }

    private func seconds(_ value: Double) -> Data {
        speech(segments: [(value, 0)])
    }

    // MARK: - Passthrough

    /// The common case must not pay for machinery it does not need.
    func testShortRecordingsAreNotSplit() {
        let chunks = AudioChunker.split(wav: seconds(20), format: format)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].startSeconds, 0)
        XCTAssertEqual(chunks[0].durationSeconds, 20, accuracy: 0.05)
    }

    func testRecordingAtTheThresholdIsNotSplit() {
        XCTAssertEqual(AudioChunker.split(wav: seconds(89), format: format).count, 1)
    }

    /// Anything unparseable is passed through whole rather than mangled — a failure to split is
    /// slow, a failure to parse that still cuts would destroy the recording.
    func testNonWavDataIsPassedThroughUntouched() {
        let junk = Data("not a wav file at all".utf8)
        let chunks = AudioChunker.split(wav: junk, format: format)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].data, junk)
    }

    // MARK: - Splitting

    func testLongRecordingIsSplit() {
        let chunks = AudioChunker.split(wav: seconds(300), format: format, target: 60, window: 15)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(chunks.map(\.index), Array(0..<chunks.count))
    }

    /// Every sample must appear in exactly one chunk. A splitter that drops a second of audio
    /// loses a word, and nothing downstream would ever notice.
    func testNoAudioIsLostOrDuplicated() {
        let original = seconds(300)
        let chunks = AudioChunker.split(wav: original, format: format, target: 60, window: 15)

        let originalBody = AudioChunker.pcmBody(of: original)!
        let rejoined = chunks.compactMap { AudioChunker.pcmBody(of: $0.data) }
            .reduce(Data(), +)
        XCTAssertEqual(rejoined.count, originalBody.count)
        XCTAssertEqual(rejoined, originalBody, "chunks must reassemble into the original samples")
    }

    /// Offsets have to be contiguous, or a later feature that maps a transcript back to a
    /// timestamp would quietly point at the wrong moment.
    func testChunkOffsetsAreContiguous() {
        let chunks = AudioChunker.split(wav: seconds(300), format: format, target: 60, window: 15)
        for (previous, next) in zip(chunks, chunks.dropFirst()) {
            XCTAssertEqual(
                previous.startSeconds + previous.durationSeconds, next.startSeconds, accuracy: 0.01)
        }
    }

    /// The point of the whole exercise: cuts land in silence, not mid-word.
    func testCutsLandInSilence() {
        // Speech in 55-second bursts separated by 4 seconds of silence. With a 60-second target
        // and a 15-second window, each cut has a silent gap within reach.
        let wav = speech(segments: Array(repeating: (loudSeconds: 55, silenceSeconds: 4), count: 6))
        let chunks = AudioChunker.split(wav: wav, format: format, target: 60, window: 15)
        XCTAssertGreaterThan(chunks.count, 1)

        for chunk in chunks.dropLast() {
            let body = AudioChunker.pcmBody(of: chunk.data)!
            let tail = body.suffix(format.bytesPerSecond / 20)  // final 50 ms
            let peak = stride(from: 0, to: tail.count - 1, by: 2).map { offset -> Int in
                let index = tail.startIndex + offset
                return abs(Int(Int16(bitPattern: UInt16(tail[index]) | (UInt16(tail[index + 1]) << 8))))
            }.max() ?? 0
            XCTAssertLessThan(peak, 500, "chunk \(chunk.index) ends mid-speech")
        }
    }

    /// A trailing two-second fragment transcribes badly on its own, so the last cut is skipped.
    func testFinalChunkIsNotAStub() {
        let chunks = AudioChunker.split(wav: seconds(185), format: format, target: 60, window: 15)
        XCTAssertGreaterThan(chunks.last!.durationSeconds, 15)
    }

    /// Uniform noise has no silence to find; the splitter must still cut somewhere legal rather
    /// than give up and emit one enormous chunk.
    func testUniformlyLoudAudioStillSplitsAtSampleBoundaries() {
        let chunks = AudioChunker.split(wav: seconds(300), format: format, target: 60, window: 15)
        XCTAssertGreaterThan(chunks.count, 1)
        for chunk in chunks {
            let body = AudioChunker.pcmBody(of: chunk.data)!
            XCTAssertEqual(body.count % 2, 0, "a cut mid-sample produces a click")
        }
    }

    // MARK: - Container

    func testGeneratedChunksAreValidWavFiles() {
        let chunks = AudioChunker.split(wav: seconds(300), format: format, target: 60, window: 15)
        for chunk in chunks {
            XCTAssertEqual(chunk.data.prefix(4), Data("RIFF".utf8))
            XCTAssertEqual(chunk.data.subdata(in: 8..<12), Data("WAVE".utf8))

            // The RIFF size field must match the real length or strict decoders reject the file.
            let declared = chunk.data.subdata(in: 4..<8).withUnsafeBytes {
                $0.loadUnaligned(as: UInt32.self).littleEndian
            }
            XCTAssertEqual(Int(declared), chunk.data.count - 8)
        }
    }

    /// Real recorders emit LIST/INFO chunks before the data; scanning for `data` rather than
    /// assuming a 44-byte header is what makes those files work.
    func testDataChunkIsFoundPastExtraMetadataChunks() {
        let plain = seconds(2)
        let body = AudioChunker.pcmBody(of: plain)!

        var withMetadata = plain.prefix(36)  // RIFF + fmt
        withMetadata.append(contentsOf: Array("LIST".utf8))
        withMetadata.append(contentsOf: [4, 0, 0, 0])
        withMetadata.append(contentsOf: Array("INFO".utf8))
        withMetadata.append(contentsOf: Array("data".utf8))
        withUnsafeBytes(of: UInt32(body.count).littleEndian) { withMetadata.append(contentsOf: $0) }
        withMetadata.append(body)

        XCTAssertEqual(AudioChunker.pcmBody(of: Data(withMetadata))?.count, body.count)
    }

    // MARK: - Stitching

    /// Chunks are cut in silence, so joining with a space is right. Adding punctuation would be
    /// inventing content, which the fidelity rules forbid at a seam as much as anywhere.
    func testStitchJoinsWithASingleSpace() {
        XCTAssertEqual(AudioChunker.stitch(["one two", "three four"]), "one two three four")
    }

    func testStitchTrimsAndDropsEmptyPieces() {
        XCTAssertEqual(AudioChunker.stitch(["  one  ", "", "\n", " two"]), "one two")
    }

    func testStitchOfNothingIsEmpty() {
        XCTAssertEqual(AudioChunker.stitch([]), "")
        XCTAssertEqual(AudioChunker.stitch(["", "  "]), "")
    }
}

final class TokenUsageArithmeticTests: XCTestCase {
    func testUsageAddsAcrossChunks() {
        let total = TokenUsage(promptTokens: 10, completionTokens: 4, audioTokens: 100)
            + TokenUsage(promptTokens: 10, completionTokens: 6, audioTokens: 200)
        XCTAssertEqual(total, TokenUsage(promptTokens: 20, completionTokens: 10, audioTokens: 300))
    }

    /// Zero audio tokens is the signal that a provider dropped the audio. Summing two unreported
    /// values into zero would fire that alarm on a provider that simply does not report usage.
    func testUnreportedUsageStaysUnreportedRatherThanBecomingZero() {
        let total = TokenUsage() + TokenUsage()
        XCTAssertNil(total.audioTokens)
        XCTAssertNil(total.promptTokens)
    }

    func testAPartiallyReportingProviderContributesWhatItHas() {
        let total = TokenUsage(audioTokens: 100) + TokenUsage()
        XCTAssertEqual(total.audioTokens, 100)
    }
}
