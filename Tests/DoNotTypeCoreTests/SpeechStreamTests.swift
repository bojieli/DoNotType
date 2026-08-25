import XCTest

@testable import DoNotTypeCore

/// The streaming Silero session, which is the part of the boundary change that can go subtly wrong.
///
/// Silero is recurrent: every 512-sample window is evaluated with the state and the 64-sample
/// context left by the one before it. Feeding a live capture therefore means carrying that state
/// across calls rather than re-reading the buffer, and a bug in the carry produces probabilities
/// that are *plausible* rather than wrong-looking — which is exactly the kind of error a synthetic
/// fixture never catches.
final class SpeechStreamTests: XCTestCase {
    private func realSpeech() throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("eval/audio/real-acronym.wav")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: url.path), "eval fixture not present")
        let wav = try Data(contentsOf: url)
        return try XCTUnwrap(AudioChunker.pcmBody(of: wav))
    }

    /// The carry is correct if arrival size cannot change the answer.
    ///
    /// 85 ms is what the macOS recorder's tap actually delivers, and 1 s and 4 s bracket it either
    /// side. All three must produce identical speech segments, because the audio is identical.
    func testArrivalSizeDoesNotChangeTheResult() throws {
        let pcm = try realSpeech()
        var results: [[Range<Int>]] = []

        for chunkSeconds in [0.085, 1.0, 4.0] {
            let stream = try SpeechActivity.Stream()
            let step = max(2, Int(chunkSeconds * 16_000) * 2)
            var offset = 0
            while offset < pcm.count {
                let end = min(offset + step, pcm.count)
                try stream.append(pcm: pcm.subdata(in: offset..<end))
                offset = end
            }
            results.append(stream.speechSegments())
        }

        XCTAssertFalse(results[0].isEmpty, "no speech found in a real recording")
        XCTAssertEqual(results[0], results[1], "85 ms arrivals disagree with 1 s arrivals")
        XCTAssertEqual(results[1], results[2], "1 s arrivals disagree with 4 s arrivals")
    }

    /// A partial window must be held, not dropped. Feeding sizes that never align to 512 samples
    /// is the case that catches a leftover buffer that is discarded instead of carried.
    func testUnalignedArrivalsLoseNoAudio() throws {
        let pcm = try realSpeech()

        let aligned = try SpeechActivity.Stream()
        try aligned.append(pcm: pcm)

        let ragged = try SpeechActivity.Stream()
        var offset = 0
        var size = 999  // deliberately coprime with the 1024-byte window
        while offset < pcm.count {
            let end = min(offset + size, pcm.count)
            try ragged.append(pcm: pcm.subdata(in: offset..<end))
            offset = end
            size = size == 999 ? 1_237 : 999
        }

        XCTAssertEqual(aligned.speechSegments(), ragged.speechSegments())
        XCTAssertEqual(aligned.analysedSamples, ragged.analysedSamples)
    }

    /// A run still open when capture pauses is not a finalised segment: the speaker has not
    /// stopped, so its end is unknown and no gap may be inferred after it.
    func testAnOpenRunIsNotFinalised() throws {
        let pcm = try realSpeech()
        let stream = try SpeechActivity.Stream()
        try stream.append(pcm: pcm)
        for segment in stream.speechSegments() {
            XCTAssertLessThan(
                segment.upperBound, stream.analysedSamples,
                "a segment reaching the end of the analysed audio was finalised early")
        }
    }

    /// The whole reason the state is carried: cost must scale with audio, not with buffer size.
    ///
    /// The live segmenter asks for a boundary every 200 ms once a minute is pending. Re-running the
    /// model over the pending buffer each time costs about 0.19 s of CPU per call at that size —
    /// roughly a whole core, sustained, for as long as no qualifying pause appears. Feeding only
    /// the new samples is linear in the audio and effectively free.
    ///
    /// The bound is deliberately loose. It is here to catch a regression back to re-scanning, not
    /// to pin a throughput figure that will drift with the machine.
    func testStreamingCostScalesWithAudioAndNotBufferSize() throws {
        let clip = try realSpeech()
        var long = Data()
        for _ in 0..<15 { long.append(clip) }   // about five minutes
        let seconds = Double(long.count / 2) / 16_000

        let stream = try SpeechActivity.Stream()
        let step = Int(0.085 * 16_000) * 2      // what the recorder's tap actually delivers
        let began = Date()
        var offset = 0
        while offset < long.count {
            let end = min(offset + step, long.count)
            try stream.append(pcm: long.subdata(in: offset..<end))
            offset = end
        }
        let elapsed = Date().timeIntervalSince(began)

        XCTAssertGreaterThan(stream.analysedSamples, 0)
        XCTAssertLessThan(
            elapsed, seconds / 10,
            "streaming \(Int(seconds)) s of audio took \(elapsed) s — under 10x real time "
                + "suggests the buffer is being re-scanned rather than the state carried")
        print("streaming: \(Int(seconds)) s of audio in \(String(format: "%.2f", elapsed)) s "
            + "(\(Int(seconds / elapsed))x real time)")
    }

    /// Pauses are the gaps between finalised runs, so each one is flanked by real speech by
    /// construction — the property the energy finder has to check separately with a heuristic.
    func testPausesSitBetweenSpeechRuns() throws {
        let pcm = try realSpeech()
        let stream = try SpeechActivity.Stream()
        try stream.append(pcm: pcm)

        let segments = stream.speechSegments()
        try XCTSkipUnless(segments.count >= 2, "this clip has no finalised gap to test")
        let pauses = stream.pauses(from: 0, format: AudioChunker.Format())
        XCTAssertEqual(pauses.count, segments.count - 1)

        for pause in pauses {
            XCTAssertGreaterThan(pause.duration, 0)
            XCTAssertGreaterThanOrEqual(pause.depth, 0)
            XCTAssertLessThanOrEqual(pause.depth, 20)
            // The midpoint must land inside a gap, never inside a run.
            let sample = pause.cut / 2
            for segment in segments {
                XCTAssertFalse(segment.contains(sample), "a cut landed inside speech")
            }
        }
    }
}
