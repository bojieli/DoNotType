import Foundation
import XCTest

@testable import DoNotTypeCore

final class PerformanceStatsTests: XCTestCase {
    private func record(
        status: DictationRecord.Status = .completed,
        text: String = "one two three",
        latency: Double? = 3,
        request: Double? = 2,
        spoken: Double = 6,
        retries: Int = 0,
        audioTokens: Int? = nil,
        model: String = "gemini-3.6-flash"
    ) -> DictationRecord {
        DictationRecord(
            status: status, text: text, provider: "gemini", model: model, fidelity: .light,
            durationSeconds: spoken, retryCount: retries,
            latencySeconds: latency, requestSeconds: request,
            usage: audioTokens.map { TokenUsage(audioTokens: $0) })
    }

    func testEmptyHistoryProducesNoMisleadingZeroes() {
        let stats = PerformanceStats.compute(from: [])
        XCTAssertEqual(stats.total, 0)
        XCTAssertNil(stats.medianLatency)
        XCTAssertNil(stats.successRate, "0/0 is not a 0% success rate")
        XCTAssertNil(stats.realTimeFactor)
    }

    func testCountsByStatus() {
        let stats = PerformanceStats.compute(from: [
            record(), record(), record(status: .failed, latency: nil),
            record(status: .pending, latency: nil),
        ])
        XCTAssertEqual(stats.total, 4)
        XCTAssertEqual(stats.completed, 2)
        XCTAssertEqual(stats.failed, 1)
        XCTAssertEqual(stats.pending, 1)
        XCTAssertEqual(stats.successRate, 0.5)
    }

    /// A failure's latency measures how long an error took to arrive. Folding it into the median
    /// would make a fast app with a bad key look slow.
    func testFailedDictationsDoNotContributeTimings() {
        let stats = PerformanceStats.compute(from: [
            record(latency: 2), record(status: .failed, latency: 90),
        ])
        XCTAssertEqual(stats.medianLatency, 2)
    }

    /// The one outlier must not drag the typical figure, which is the entire reason for a median.
    func testMedianIsNotDraggedByAnOutlier() {
        let stats = PerformanceStats.compute(from: [
            record(latency: 2), record(latency: 2), record(latency: 3), record(latency: 3),
            record(latency: 120),
        ])
        XCTAssertEqual(stats.medianLatency, 3)
        XCTAssertEqual(stats.p95Latency, 120, "p95 is where the bad case is supposed to show up")
    }

    func testPercentileOfASingleSampleIsThatSample() {
        XCTAssertEqual(PerformanceStats.percentile([7], 0.5), 7)
        XCTAssertEqual(PerformanceStats.percentile([7], 0.95), 7)
    }

    func testPercentileOfNothingIsNil() {
        XCTAssertNil(PerformanceStats.percentile([], 0.5))
    }

    func testPercentileUsesNearestRank() {
        let values: [Double] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
        XCTAssertEqual(PerformanceStats.percentile(values, 0.5), 5)
        XCTAssertEqual(PerformanceStats.percentile(values, 0.95), 10)
        XCTAssertEqual(PerformanceStats.percentile(values, 1.0), 10)
    }

    /// Zero latency means "not measured" (an old record from before timings existed), not "instant".
    func testUnmeasuredRecordsAreExcludedRatherThanCountedAsInstant() {
        let stats = PerformanceStats.compute(from: [
            record(latency: nil), record(latency: 0), record(latency: 4),
        ])
        XCTAssertEqual(stats.medianLatency, 4)
    }

    func testWordsAndSpeechAccumulate() {
        let stats = PerformanceStats.compute(from: [
            record(text: "one two three", spoken: 6),
            record(text: "four five", spoken: 4),
        ])
        XCTAssertEqual(stats.words, 5)
        XCTAssertEqual(stats.spokenSeconds, 10)
    }

    /// The delivered text is what the user got, so a rewritten dictation counts its rewrite.
    func testWordCountFollowsWhatWasActuallyInserted() {
        let rewritten = DictationRecord(
            status: .completed, text: "um so ship it",
            styledText: "Please ship it.", style: .formal,
            provider: "gemini", model: "m", fidelity: .light, latencySeconds: 1)
        XCTAssertEqual(PerformanceStats.compute(from: [rewritten]).words, 3)
    }

    /// Below 1.0 the transcript arrives faster than it took to say. This is the number that
    /// decides whether dictation feels immediate.
    func testRealTimeFactorComparesWaitToSpeech() {
        let stats = PerformanceStats.compute(from: [record(latency: 3, spoken: 6)])
        XCTAssertEqual(stats.realTimeFactor ?? 0, 0.5, accuracy: 0.001)
    }

    func testRealTimeFactorIsNilWithoutSpeechDuration() {
        XCTAssertNil(PerformanceStats.compute(from: [record(spoken: 0)]).realTimeFactor)
    }

    /// A speaking rate computed from ten seconds of audio is noise dressed as a statistic.
    func testWordsPerMinuteNeedsEnoughSpeechToMeanAnything() {
        XCTAssertNil(PerformanceStats.compute(from: [record(spoken: 30)]).wordsPerMinute)

        let long = PerformanceStats.compute(from: [
            record(text: String(repeating: "word ", count: 120), spoken: 120)
        ])
        XCTAssertEqual(long.wordsPerMinute ?? 0, 60, accuracy: 0.5)
    }

    func testRetriesAreCountedPerDictationNotPerAttempt() {
        let stats = PerformanceStats.compute(from: [
            record(retries: 3), record(retries: 0), record(retries: 1),
        ])
        XCTAssertEqual(stats.retried, 2)
    }

    func testAudioTokensAccumulateAcrossDictations() {
        let stats = PerformanceStats.compute(from: [
            record(audioTokens: 100), record(audioTokens: 250), record(audioTokens: nil),
        ])
        XCTAssertEqual(stats.audioTokens, 350)
    }
}

final class ModelPerformanceTests: XCTestCase {
    private func record(model: String, provider: String = "gemini", latency: Double) -> DictationRecord {
        DictationRecord(
            status: .completed, text: "hello", provider: provider, model: model, fidelity: .light,
            durationSeconds: 5, latencySeconds: latency)
    }

    func testBreakdownGroupsByProviderAndModel() {
        let breakdown = ModelPerformance.breakdown(from: [
            record(model: "gemini-3.6-flash", latency: 2),
            record(model: "gemini-3.6-flash", latency: 4),
            record(model: "gemini-2.5-flash", latency: 9),
        ])
        XCTAssertEqual(breakdown.count, 2)
        XCTAssertEqual(breakdown.first?.model, "gemini-3.6-flash", "most-used model comes first")
        XCTAssertEqual(breakdown.first?.stats.total, 2)
        // Nearest-rank, so the median of two samples is the lower one.
        XCTAssertEqual(breakdown.first?.stats.medianLatency, 2)
    }

    /// The same model name at two providers is two different things to measure.
    func testSameModelAtDifferentProvidersIsNotMerged() {
        let breakdown = ModelPerformance.breakdown(from: [
            record(model: "gemini-3.6-flash", provider: "gemini", latency: 2),
            record(model: "gemini-3.6-flash", provider: "openrouter", latency: 5),
        ])
        XCTAssertEqual(breakdown.count, 2)
        XCTAssertEqual(Set(breakdown.map(\.provider)), ["gemini", "openrouter"])
    }

    func testBreakdownOfNothingIsEmpty() {
        XCTAssertTrue(ModelPerformance.breakdown(from: []).isEmpty)
    }
}

final class DurationFormattingTests: XCTestCase {
    func testSubSecondWaitsAreShownInMilliseconds() {
        XCTAssertEqual(PerformanceStats.formatDuration(0.42), "420 ms")
    }

    func testSecondsKeepOneDecimal() {
        XCTAssertEqual(PerformanceStats.formatDuration(3.46), "3.5 s")
    }

    func testMinutesAndHours() {
        XCTAssertEqual(PerformanceStats.formatDuration(125), "2m 5s")
        XCTAssertEqual(PerformanceStats.formatDuration(3_725), "1h 2m")
    }

    /// "—" rather than "0 s": an unmeasured value must not read as an instant one.
    func testMissingValuesAreShownAsUnknown() {
        XCTAssertEqual(PerformanceStats.formatDuration(nil), "—")
        XCTAssertEqual(PerformanceStats.formatDuration(.infinity), "—")
    }

    func testLargeCountsAreAbbreviated() {
        XCTAssertEqual(PerformanceStats.formatCount(12_500), "12.5k")
        XCTAssertEqual(PerformanceStats.formatCount(42), "42")
    }
}

final class AudioFileDurationTests: XCTestCase {
    func testDurationIsReadFromTheWavHeader() {
        let format = AudioChunker.Format(sampleRate: 16_000, channels: 1, bitsPerSample: 16)
        let pcm = Data(repeating: 0, count: 16_000 * 2 * 3)  // 3 seconds
        let file = AudioFile(
            data: AudioChunker.wrapInWavContainer(pcm, format: format), mimeType: "audio/wav")
        XCTAssertEqual(file.durationSeconds ?? 0, 3, accuracy: 0.001)
    }

    /// Compressed audio cannot be measured without decoding, and a wrong number is worse than none.
    func testCompressedAudioReportsNoDuration() {
        XCTAssertNil(AudioFile(data: Data([1, 2, 3, 4]), mimeType: "audio/flac").durationSeconds)
    }

    func testTruncatedWavDoesNotCrashOrLie() {
        XCTAssertNil(AudioFile(data: Data("RIFF".utf8), mimeType: "audio/wav").durationSeconds)
    }
}
