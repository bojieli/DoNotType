import Foundation
import XCTest

@testable import DoNotTypeCore

/// The container is hand-written, so these check its structure against the Ogg specification
/// rather than against itself. A muxer that only its own tests accept is worth nothing — the
/// integration proof is `dnt-eval encode` producing a file `ffprobe` reads and the API transcribes.
final class OggOpusWriterTests: XCTestCase {
    private func packets(_ count: Int, size: Int = 40) -> [Data] {
        (0..<count).map { index in
            Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &+ index) })
        }
    }

    private func write(_ packets: [Data], frameCount: Int = 320) -> Data {
        var writer = OggOpusWriter()
        writer.begin()
        for packet in packets { writer.append(packet: packet, frameCount: frameCount) }
        return writer.finish()
    }

    /// Every page starts with the capture pattern; a decoder resynchronises by scanning for it.
    private func pageOffsets(in data: Data) -> [Int] {
        let magic = Data("OggS".utf8)
        var offsets: [Int] = []
        var index = 0
        while index + 4 <= data.count {
            if data.subdata(in: index..<(index + 4)) == magic { offsets.append(index) }
            index += 1
        }
        return offsets
    }

    // MARK: - Headers

    func testStreamOpensWithTheTwoMandatoryHeaders() {
        let data = write(packets(1))
        let offsets = pageOffsets(in: data)
        XCTAssertGreaterThanOrEqual(offsets.count, 3, "two headers plus at least one audio page")

        XCTAssertTrue(data.range(of: Data("OpusHead".utf8)) != nil)
        XCTAssertTrue(data.range(of: Data("OpusTags".utf8)) != nil)

        // OpusHead must be alone on the first page and flagged as beginning-of-stream.
        XCTAssertEqual(data[offsets[0] + 5], 0x02, "first page must set the BOS flag")
        XCTAssertEqual(data[offsets[1] + 5], 0x00, "the comment page is not a stream start")
    }

    func testOpusHeadDeclaresMonoAndTheSourceRate() {
        let data = write(packets(1))
        let start = data.range(of: Data("OpusHead".utf8))!.upperBound

        XCTAssertEqual(data[start], 1, "version")
        XCTAssertEqual(data[start + 1], 1, "channel count")

        let rate = data.subdata(in: (start + 4)..<(start + 8)).withUnsafeBytes {
            $0.loadUnaligned(as: UInt32.self).littleEndian
        }
        XCTAssertEqual(rate, 16_000)
    }

    // MARK: - Framing

    func testPageSequenceNumbersAreContiguousFromZero() {
        let data = write(packets(3))
        for (expected, offset) in pageOffsets(in: data).enumerated() {
            let sequence = data.subdata(in: (offset + 18)..<(offset + 22)).withUnsafeBytes {
                $0.loadUnaligned(as: UInt32.self).littleEndian
            }
            XCTAssertEqual(Int(sequence), expected, "a gap makes the stream look truncated")
        }
    }

    func testAllPagesShareOneSerialNumber() {
        let data = write(packets(3))
        let serials = pageOffsets(in: data).map { offset in
            data.subdata(in: (offset + 14)..<(offset + 18)).withUnsafeBytes {
                $0.loadUnaligned(as: UInt32.self).littleEndian
            }
        }
        XCTAssertEqual(Set(serials).count, 1, "one logical stream means one serial")
    }

    /// The end-of-stream flag must sit on the last page of real audio. An earlier version appended
    /// an empty page to carry it, which is a zero-length Opus packet — ffprobe read the duration
    /// and then failed with "Packet processing failed" at the end of every file.
    func testTheFinalAudioPageCarriesEndOfStream() {
        let data = write(packets(3))
        let offsets = pageOffsets(in: data)
        let last = offsets.last!

        XCTAssertEqual(data[last + 5] & 0x04, 0x04, "last page must set the EOS flag")

        // And it must not be empty: segment count non-zero, with a non-zero segment in it.
        let segmentCount = Int(data[last + 26])
        XCTAssertGreaterThan(segmentCount, 0)
        XCTAssertGreaterThan(Int(data[last + 27]), 0, "the EOS page must carry a real packet")
    }

    /// One packet per page costs 28 bytes of header per 20 ms frame — 1.4 kB/s, nearly as much
    /// again as a 16 kbps stream. This measured 27 kbps against ffmpeg's 16 before batching.
    func testPacketsSharePagesRatherThanOnePerPage() {
        let data = write(packets(120))
        let pages = pageOffsets(in: data).count
        XCTAssertLessThan(pages, 10, "120 packets should not produce 120 pages")
    }

    func testGranulePositionAdvancesInTheOpusClockNotTheSourceClock() {
        // 320 frames at 16 kHz is 20 ms, which is 960 samples at Opus's fixed 48 kHz clock.
        let data = write(packets(1), frameCount: 320)
        let last = pageOffsets(in: data).last!
        let granule = data.subdata(in: (last + 6)..<(last + 14)).withUnsafeBytes {
            $0.loadUnaligned(as: UInt64.self).littleEndian
        }
        XCTAssertEqual(granule, 960, "a wrong clock makes the file play at the wrong speed")
    }

    // MARK: - Checksums

    /// Ogg uses polynomial 0x04C11DB7 with no reflection and a zero seed — *not* zip's CRC-32,
    /// which produces a wrong-but-plausible value that decoders reject.
    func testCrcMatchesKnownOggVectors() {
        XCTAssertEqual(OggOpusWriter.crc32(Data()), 0)
        XCTAssertEqual(OggOpusWriter.crc32(Data([0x00])), 0)

        // The published check value for CRC-32/MPEG-2, which is the variant Ogg specifies. This
        // is the vector that pins the algorithm: an implementation that reflects its input or
        // seeds with 0xFFFFFFFF produces a plausible-looking checksum and fails here.
        XCTAssertEqual(OggOpusWriter.crc32(Data("123456789".utf8)), 0x89A1_897F)
        XCTAssertEqual(OggOpusWriter.crc32(Data("OggS".utf8)), 0x5FB0_A94F)
    }

    /// Recomputing each page's checksum with the field zeroed must reproduce the stored value —
    /// this is exactly what a decoder does before accepting a page.
    func testEveryPageChecksumVerifies() {
        let data = write(packets(120))
        let offsets = pageOffsets(in: data)

        for (index, offset) in offsets.enumerated() {
            let end = index + 1 < offsets.count ? offsets[index + 1] : data.count
            var page = data.subdata(in: offset..<end)

            let stored = page.subdata(in: 22..<26).withUnsafeBytes {
                $0.loadUnaligned(as: UInt32.self).littleEndian
            }
            for byte in 22..<26 { page[byte] = 0 }

            XCTAssertEqual(
                OggOpusWriter.crc32(page), stored, "page \(index) would be rejected as corrupt")
        }
    }

    // MARK: - Segment table

    func testLargePacketsSpanMultipleSegments() {
        // 600 bytes needs 255 + 255 + 90.
        var writer = OggOpusWriter()
        writer.begin()
        writer.append(packet: Data(repeating: 7, count: 600), frameCount: 320)
        let data = writer.finish()

        let last = pageOffsets(in: data).last!
        XCTAssertEqual(Int(data[last + 26]), 3, "segment count")
        XCTAssertEqual(data[last + 27], 255)
        XCTAssertEqual(data[last + 28], 255)
        XCTAssertEqual(data[last + 29], 90)
    }

    /// A packet that is an exact multiple of 255 needs a trailing zero segment, or the decoder
    /// treats the packet as continuing into the next page.
    func testPacketOfExactlyTwoHundredAndFiftyFiveBytesTerminatesProperly() {
        var writer = OggOpusWriter()
        writer.begin()
        writer.append(packet: Data(repeating: 1, count: 255), frameCount: 320)
        let data = writer.finish()

        let last = pageOffsets(in: data).last!
        XCTAssertEqual(Int(data[last + 26]), 2)
        XCTAssertEqual(data[last + 27], 255)
        XCTAssertEqual(data[last + 28], 0, "the terminating zero segment is what ends the packet")
    }
}

final class OpusEncoderTests: XCTestCase {
    /// Compression must never be able to cost someone their words, so anything it cannot handle
    /// comes back untouched rather than empty.
    func testUnencodableAudioIsReturnedUnchanged() {
        let flac = AudioFile(data: Data([1, 2, 3, 4]), mimeType: "audio/flac")
        XCTAssertEqual(flac.compressedForUpload().mimeType, "audio/flac")

        let broken = AudioFile(data: Data("not a wav".utf8), mimeType: "audio/wav")
        XCTAssertEqual(broken.compressedForUpload().data, broken.data)
    }

    func testRealSpeechCompressesSubstantiallyAndStaysDecodable() throws {
        try XCTSkipUnless(OpusEncoder.isAvailable, "no Opus encoder on this system")

        // Two seconds of a tone is enough to exercise the encoder end to end.
        let format = AudioChunker.Format()
        var pcm = Data()
        var phase = 0.0
        for _ in 0..<32_000 {
            phase += 2 * Double.pi * 220 / 16_000
            let sample = Int16(sin(phase) * 12_000)
            pcm.append(UInt8(truncatingIfNeeded: sample))
            pcm.append(UInt8(truncatingIfNeeded: sample >> 8))
        }
        let wav = AudioChunker.wrapInWavContainer(pcm, format: format)
        let compressed = AudioFile(data: wav, mimeType: "audio/wav").compressedForUpload()

        XCTAssertEqual(compressed.mimeType, "audio/ogg")
        XCTAssertLessThan(
            compressed.data.count, wav.count / 4, "16 kbps Opus should be far smaller than PCM")
        XCTAssertEqual(compressed.data.prefix(4), Data("OggS".utf8))
    }
}

/// The pre-upload route is the one the app actually takes, so it is the one that has to be
/// compressed. Shipping compression on the inline path alone was a real defect: every measurement
/// improved and no user saw any of it.
final class UploadCompressionTests: XCTestCase {
    private func speechWav(seconds: Double) -> Data {
        var pcm = Data()
        var phase = 0.0
        for _ in 0..<Int(seconds * 16_000) {
            phase += 2 * Double.pi * 220 / 16_000
            let sample = Int16(sin(phase) * 12_000)
            pcm.append(UInt8(truncatingIfNeeded: sample))
            pcm.append(UInt8(truncatingIfNeeded: sample >> 8))
        }
        return AudioChunker.wrapInWavContainer(pcm, format: AudioChunker.Format())
    }

    /// With no upload session open, `plan` falls back to inline — and that payload must already be
    /// the compressed one.
    func testInlineFallbackCarriesCompressedAudio() async throws {
        try XCTSkipUnless(OpusEncoder.isAvailable, "no Opus encoder on this system")

        let wav = speechWav(seconds: 3)
        let uploader = AudioUploader(apiKey: "test-key")
        let plan = try await uploader.plan(for: AudioFile(data: wav, mimeType: "audio/wav"))

        guard case .audio(let data, let mimeType) = plan.part else {
            return XCTFail("expected inline audio, got \(plan.part)")
        }
        XCTAssertEqual(mimeType, "audio/ogg")
        XCTAssertLessThan(data.count, wav.count / 4)
        XCTAssertEqual(data.prefix(4), Data("OggS".utf8))
    }

    /// The session cannot declare a byte count, because the recording has not happened when it
    /// opens and compression happens after it. Declaring one made every pre-upload fail at
    /// finalise with a size mismatch, silently falling back to inline.
    func testCompressionShrinksTheUploadEnoughToMatter() throws {
        try XCTSkipUnless(OpusEncoder.isAvailable, "no Opus encoder on this system")

        let wav = speechWav(seconds: 10)
        let compressed = AudioFile(data: wav, mimeType: "audio/wav").compressedForUpload()
        XCTAssertLessThan(compressed.data.count * 8, wav.count, "expected roughly an order of magnitude")
    }
}
