import Foundation
import XCTest

@testable import DoNotTypeCore

final class LiveTranscriptionSessionTests: XCTestCase {
    private let format = AudioChunker.Format()

    func testFirstPartIsRequestedBeforeRecordingFinishesAndResultsStayOrdered() async throws {
        let calls = LiveCallLog()
        let provider = LiveProbeProvider(calls: calls)
        let service = TranscriptionService(
            provider: provider, model: "live", systemInstruction: "transcribe",
            hedgeStalledRequests: false)
        let session = LiveTranscriptionSession(
            transcriber: FallbackTranscriber(primary: service), context: nil)
        let pipeline = LiveAudioPipeline(session: session)
        let body = pcm(segments: [(55, 4), (35, 0)])

        pipeline.append(pcm: body.subdata(in: 0..<(90 * format.bytesPerSecond)))
        pipeline.append(pcm: body.subdata(in: (90 * format.bytesPerSecond)..<body.count))

        // `finish` has deliberately not been called: part one must already reach the provider
        // while the tail is still an open recording.
        try await waitUntil { await calls.count == 1 }

        let outcome = try await pipeline.finish()
        let callCount = await calls.count
        XCTAssertEqual(callCount, 2)
        XCTAssertEqual(outcome.result.transcript.transcript, "part 1 part 2")
        XCTAssertEqual(outcome.result.chunkCount, 2)
    }

    private func pcm(segments: [(Double, Double)]) -> Data {
        var pcm = Data()
        var phase = 0.0
        var sampleNumber = 0
        for (loud, silence) in segments {
            for _ in 0..<Int(loud * Double(format.sampleRate)) {
                phase += 2 * Double.pi * 220 / Double(format.sampleRate)
                // Real speech is modulated. Alternating levels also keeps the whole-recording
                // speech guard from mistaking a laboratory tone for steady background noise.
                let amplitude = (sampleNumber / (format.sampleRate / 4)).isMultiple(of: 2)
                    ? 12_000.0 : 2_000.0
                let sample = Int16(sin(phase) * amplitude)
                pcm.append(UInt8(truncatingIfNeeded: sample))
                pcm.append(UInt8(truncatingIfNeeded: sample >> 8))
                sampleNumber += 1
            }
            pcm.append(Data(count: Int(silence * Double(format.bytesPerSecond))))
        }
        return pcm
    }

    private func waitUntil(
        timeout: Duration = .seconds(5), condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("condition did not become true before timeout")
    }
}

private actor LiveCallLog {
    private(set) var count = 0
    func next() -> Int {
        count += 1
        return count
    }
}

private struct LiveProbeProvider: TranscriptionProvider {
    let name = "live-probe"
    let calls: LiveCallLog

    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        let number = await calls.next()
        return TranscriptionResult(
            transcript: Transcript(transcript: "part \(number)", language: "en"),
            usage: TokenUsage(audioTokens: 1), rawOutput: "part \(number)")
    }
}
