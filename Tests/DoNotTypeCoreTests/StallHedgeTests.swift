import XCTest

@testable import DoNotTypeCore

final class StallHedgeTests: XCTestCase {

    // MARK: - When a request counts as stalled

    /// The floor. Nothing shorter than 32 seconds of audio can produce a deadline below it, which
    /// is every ordinary dictation.
    func testShortRecordingsGetTheEightSecondFloor() {
        XCTAssertEqual(StallHedge.deadlineSeconds(audioSeconds: 0), 8)
        XCTAssertEqual(StallHedge.deadlineSeconds(audioSeconds: 3), 8)
        XCTAssertEqual(StallHedge.deadlineSeconds(audioSeconds: 20), 8)
    }

    /// Both conditions have to hold, so at the crossover the floor is still what binds: a quarter
    /// of 32 seconds *is* eight, and a hair under it is less.
    func testTheFloorBindsUntilAQuarterOfTheAudioOvertakesIt() {
        XCTAssertEqual(StallHedge.deadlineSeconds(audioSeconds: 31.9), 8)
        XCTAssertEqual(StallHedge.deadlineSeconds(audioSeconds: 32), 8)
        XCTAssertEqual(StallHedge.deadlineSeconds(audioSeconds: 32.4), 8.1, accuracy: 0.0001)
    }

    /// Past the crossover it is the audio that decides: eight seconds is a stall for a three-second
    /// clip and a perfectly good pace for a four-minute one.
    func testLongRecordingsGetAQuarterOfTheirOwnLength() {
        XCTAssertEqual(StallHedge.deadlineSeconds(audioSeconds: 60), 15)
        XCTAssertEqual(StallHedge.deadlineSeconds(audioSeconds: 240), 60)
    }

    /// A compressed file's length is not readable without decoding it, and a missing duration must
    /// not disable the hedge — it falls back to the floor.
    func testAnUnknownDurationGetsTheFloor() {
        XCTAssertEqual(StallHedge.deadlineSeconds(audioSeconds: nil), 8)
    }

    // MARK: - Racing

    /// The common case: the request answers normally, so no second one is ever sent.
    func testAFastRequestIsNeverDuplicated() async throws {
        let sent = Counter()

        let value = try await StallHedge.race(deadlineSeconds: 30) {
            await sent.increment()
            return "first"
        }

        XCTAssertEqual(value, "first")
        let count = await sent.value
        XCTAssertEqual(count, 1, "a request that answered in time must not be second-guessed")
    }

    /// The case this exists for: the first request is stuck in the tail and the second one lands.
    func testAStalledRequestIsOvertakenByItsDuplicate() async throws {
        let sent = Counter()
        let hedged = expectation(description: "the hedge fired")

        let value = try await StallHedge.race(
            deadlineSeconds: 0.02,
            onHedge: { hedged.fulfill() }
        ) {
            let attempt = await sent.increment()
            // The first request stalls for effectively ever; the second answers straight away.
            if attempt == 1 { try await Task.sleep(for: .seconds(30)) }
            return "attempt \(attempt)"
        }

        XCTAssertEqual(value, "attempt 2")
        await fulfillment(of: [hedged], timeout: 1)
    }

    /// Not a timeout: the first request is not abandoned at the deadline. If it answers while the
    /// duplicate is still working, it is the one that wins.
    func testTheFirstRequestStillWinsIfItAnswersAfterTheDeadline() async throws {
        let sent = Counter()

        let value = try await StallHedge.race(deadlineSeconds: 0.02) {
            let attempt = await sent.increment()
            if attempt == 1 { try await Task.sleep(for: .milliseconds(60)) }
            if attempt == 2 { try await Task.sleep(for: .seconds(30)) }
            return "attempt \(attempt)"
        }

        XCTAssertEqual(value, "attempt 1")
    }

    /// A failure is the retry ladder's problem, not the hedge's, and its backoff will try again
    /// sooner than sitting out the rest of the deadline would.
    func testAnEarlyFailureIsNotMadeToWaitOutTheDeadline() async {
        let started = ContinuousClock.now

        do {
            _ = try await StallHedge.race(deadlineSeconds: 30) {
                throw ProviderError.http(status: 500, body: "boom")
            }
            XCTFail("expected the failure to surface")
        } catch ProviderError.http(let status, _) {
            XCTAssertEqual(status, 500)
        } catch {
            XCTFail("expected the request's own error, got \(error)")
        }

        XCTAssertLessThan(
            started.duration(to: .now), .seconds(5),
            "a failed request must not sit out a deadline meant for a running one")
    }

    /// Once the duplicate is in flight, the first one failing costs nothing: the words can still
    /// arrive from the request that is still running.
    func testAFailureAfterTheHedgeWaitsForTheDuplicate() async throws {
        let sent = Counter()

        let value = try await StallHedge.race(deadlineSeconds: 0.02) {
            let attempt = await sent.increment()
            if attempt == 1 {
                // Long enough that the hedge has certainly started before this gives up.
                try await Task.sleep(for: .milliseconds(60))
                throw ProviderError.http(status: 503, body: "unavailable")
            }
            try await Task.sleep(for: .milliseconds(120))
            return "attempt \(attempt)"
        }

        XCTAssertEqual(value, "attempt 2")
    }

    /// When both fail the caller sees the *original* request's error even though the duplicate
    /// failed sooner: the duplicate was this type's idea, and the request the caller asked for is
    /// the one whose failure explains their configuration.
    func testWhenBothFailTheOriginalRequestsErrorSurfaces() async {
        let sent = Counter()

        do {
            _ = try await StallHedge.race(deadlineSeconds: 0.02) {
                let attempt = await sent.increment()
                if attempt == 1 {
                    try await Task.sleep(for: .milliseconds(60))
                    throw ProviderError.missingAPIKey(envVar: "FIRST_KEY")
                }
                throw ProviderError.http(status: 500, body: "boom")
            }
            XCTFail("expected a failure")
        } catch ProviderError.missingAPIKey(let envVar) {
            XCTAssertEqual(envVar, "FIRST_KEY")
        } catch {
            XCTFail("expected the first request's error, got \(error)")
        }
    }

    /// A deadline of zero or less disables hedging rather than duplicating everything instantly.
    func testANonPositiveDeadlineSendsOneRequest() async throws {
        let sent = Counter()

        let value = try await StallHedge.race(deadlineSeconds: 0) {
            let attempt = await sent.increment()
            try await Task.sleep(for: .milliseconds(30))
            return "attempt \(attempt)"
        }

        XCTAssertEqual(value, "attempt 1")
        let count = await sent.value
        XCTAssertEqual(count, 1)
    }
}

/// How many times the raced closure ran, which is the whole cost question.
private actor Counter {
    private(set) var value = 0

    @discardableResult
    func increment() -> Int {
        value += 1
        return value
    }
}
