import XCTest

@testable import DoNotTypeCore

/// Every format a client is expected to read, decoded through the real path.
///
/// The fixtures are the same 1.5 seconds of speech in four containers, shared with the Windows and
/// Android suites rather than copied into each — see `eval/audio/formats/README.md`. Speech rather
/// than silence on purpose: a decoder that drops every sample still returns the right *length* of
/// silence, so a silent fixture cannot tell a working decoder from one that produced nothing.
final class AudioFormatTests: XCTestCase {

    /// Walks up from this source file rather than the working directory, which under `swift test`
    /// is wherever the runner was invoked from.
    private static func fixture(_ name: String) -> URL? {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = directory.appendingPathComponent("eval/audio/formats/\(name)")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            directory = directory.deletingLastPathComponent()
        }
        return nil
    }

    /// Loudest sample in the decoded PCM. Zero means the decoder produced silence from speech,
    /// which is the failure a length check alone would pass.
    private func peak(of wav: Data) -> Int {
        guard let body = AudioChunker.pcmBody(of: wav) else { return 0 }
        var loudest = 0
        for index in stride(from: 0, to: body.count - 1, by: 2) {
            let sample = Int(Int16(bitPattern: UInt16(body[index]) | (UInt16(body[index + 1]) << 8)))
            loudest = max(loudest, abs(sample))
        }
        return loudest
    }

    private func assertDecodes(
        _ name: String, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        guard let url = Self.fixture(name) else {
            return XCTFail("missing fixture \(name)", file: file, line: line)
        }

        let audio = try AudioDecoder.load(url)

        XCTAssertTrue(
            AudioDecoder.isAlreadyTarget(audio.data),
            "\(name) should come out as 16 kHz mono WAV", file: file, line: line)
        XCTAssertEqual(
            audio.durationSeconds ?? 0, 1.5, accuracy: 0.25,
            "\(name) lost or gained audio in the conversion", file: file, line: line)
        // A quarter of full scale. Speech at this level is unmistakably present, and no amount of
        // codec padding or resampling error reaches it from silence.
        XCTAssertGreaterThan(
            peak(of: audio.data), 8_000,
            "\(name) decoded to something inaudible — a decoder that returns silence would pass a "
                + "length check alone", file: file, line: line)
        XCTAssertNotNil(
            AudioChunker.pcmBody(of: audio.data),
            "the chunker must be able to find silence in the result", file: file, line: line)
    }

    func testWav() throws { try assertDecodes("speech.wav") }

    func testMp3() throws { try assertDecodes("speech.mp3") }

    func testM4a() throws { try assertDecodes("speech.m4a") }

    /// Ogg Opus, which is the one worth asserting rather than assuming: it is a container CoreAudio
    /// has not always read, and the platform this project encodes *to*. If a system update takes it
    /// away, this is where that shows up rather than in a user's file failing to open.
    func testOggOpus() throws { try assertDecodes("speech.opus") }

    /// The fast path: a file already in the target format is returned byte for byte, because a
    /// re-encode would be a lossy round trip that changes nothing.
    func testAlreadyTargetIsNotReEncoded() throws {
        let url = try XCTUnwrap(Self.fixture("speech.wav"))
        let original = try Data(contentsOf: url)
        XCTAssertEqual(try AudioDecoder.load(url).data, original)
    }

    /// Whatever the container went in, the pipeline downstream sees exactly one thing.
    func testEveryFormatProducesTheSameFormatChunk() throws {
        // Bytes 20..36 of a canonical WAV: format tag, channels, sample rate, byte rate, block
        // align, bits per sample. If two containers disagree here, something downstream — the
        // chunker, the duration, the Opus encoder — is being handed audio it assumed it would not
        // get.
        let formatChunks = try ["speech.wav", "speech.mp3", "speech.m4a", "speech.opus"]
            .compactMap(Self.fixture)
            .map { try AudioDecoder.load($0).data[20..<36] }

        XCTAssertEqual(formatChunks.count, 4, "every fixture should be present")
        XCTAssertEqual(
            Set(formatChunks).count, 1,
            "all four formats should decode to identical PCM parameters")
    }

    func testTheOfferedExtensionsCoverEveryFixture() {
        for name in ["speech.wav", "speech.mp3", "speech.m4a", "speech.opus"] {
            let ext = String(name.split(separator: ".").last!)
            XCTAssertTrue(
                AudioDecoder.openableExtensions.contains(ext),
                "\(ext) decodes, so a file picker should offer it")
        }
    }
}
