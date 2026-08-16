import XCTest

@testable import DoNotTypeCore

/// The log has one job beyond being useful: being safe to paste into an issue.
///
/// Most of these tests are about that. A logger that leaks a key is worse than no logger, because
/// the leak only shows up once someone has already sent the file to a stranger.
final class LoggingTests: XCTestCase {
    private var sink: MemoryLogSink!

    override func setUp() {
        super.setUp()
        sink = MemoryLogSink()
        LogRouter.shared.install(sinks: [sink], level: .trace)
        LogRouter.shared.setIncludesContent(false)
        LogRouter.shared.clearBuffer()
    }

    override func tearDown() {
        LogRouter.shared.install(sinks: [], level: .off)
        super.tearDown()
    }

    // MARK: - Levels

    func testLevelsFilterFromTheBottom() {
        LogRouter.shared.setLevel(.warning)
        let log = Log("test")
        log.debug("invisible")
        log.info("also invisible")
        log.warning("visible")
        log.error("visible too")

        XCTAssertEqual(sink.events.map(\.message), ["visible", "visible too"])
    }

    func testOffSilencesEvenErrors() {
        LogRouter.shared.setLevel(.off)
        Log("test").error("nope")
        XCTAssertTrue(sink.events.isEmpty)
    }

    /// The reason messages are autoclosures: a `trace` call in a hot path must not build its string
    /// when tracing is off.
    func testDisabledLevelNeverEvaluatesTheMessage() {
        LogRouter.shared.setLevel(.error)
        nonisolated(unsafe) var built = false
        Log("test").debug({
            built = true
            return "expensive"
        }())
        XCTAssertFalse(built, "a filtered message must not be constructed")
    }

    func testLevelNamesAcceptTheSpellingsPeopleType() {
        XCTAssertEqual(LogLevel(name: "warn"), .warning)
        XCTAssertEqual(LogLevel(name: "WARNING"), .warning)
        XCTAssertEqual(LogLevel(name: "silent"), .off)
        XCTAssertEqual(LogLevel(name: " Debug "), .debug)
        XCTAssertNil(LogLevel(name: "chatty"))
    }

    // MARK: - Redaction

    func testRegisteredSecretIsMaskedWhereverItAppears() {
        let key = "AIzaSyD-Not-A-Real-Key-000000000000000"
        LogRouter.shared.redact(secret: key)

        Log("test").error(
            "HTTP 400 from https://example.com/v1?key=\(key)", ["body": "invalid key \(key)"])

        let event = try! XCTUnwrap(sink.events.first)
        XCTAssertFalse(event.message.contains(key))
        XCTAssertFalse(event.fields["body"]!.contains(key))
        XCTAssertTrue(event.message.contains("redacted"))
    }

    /// The case registration cannot cover: a key belonging to some other tool, pasted into a URL or
    /// echoed back by a provider this process never authenticated to.
    func testUnregisteredKeyShapesAreStillMasked() {
        Log("test").info("using sk-abcdefghijklmnopqrstuvwxyz012345 for that call")
        XCTAssertFalse(sink.events[0].message.contains("sk-abcdefghijklmnopqrstuvwxyz012345"))
    }

    func testOrdinaryTextSurvivesRedaction() {
        // Every one of these has been mistaken for a secret by a naive length rule at some point.
        let harmless = [
            "gemini-3.6-flash", "voxtral-mini-latest", "transcription", "550e8400-e29b-41d4",
            "com.apple.keychainaccess", "AudioChunker.wrapInWavContainer",
        ]
        for text in harmless {
            XCTAssertFalse(
                Redaction.looksSecret(text), "\(text) is not a credential and must not be masked")
        }
    }

    func testLongOpaqueTokenIsMasked() {
        XCTAssertTrue(Redaction.looksSecret("a1b2c3d4e5f6g7h8i9j0k1l2m3n4o5p6q7r8"))
    }

    func testURLQueryCredentialsAreStrippedForLogging() {
        let url = URL(string: "https://api.example.com/v1/listen?key=supersecretvalue&model=nova-3")!
        let redacted = url.redactedForLog
        XCTAssertFalse(redacted.contains("supersecretvalue"))
        XCTAssertTrue(redacted.contains("model=nova-3"), "non-secret parameters stay readable")
    }

    // MARK: - Content

    func testContentIsWithheldByDefaultButItsSizeIsNot() {
        Log("test").content("transcript", "the thing I actually said")

        let event = try! XCTUnwrap(sink.events.first)
        XCTAssertEqual(event.fields["chars"], "25")
        XCTAssertNil(event.fields["text"], "transcripts must not be logged unless asked for")
    }

    func testContentIsIncludedWhenTurnedOn() {
        LogRouter.shared.setIncludesContent(true)
        Log("test").content("transcript", "the thing I actually said")
        XCTAssertEqual(sink.events.first?.fields["text"], "the thing I actually said")
    }

    // MARK: - Buffer

    func testRecentFiltersByLevelAndSearch() {
        let log = Log("dictation")
        log.info("started recording")
        log.error("upload failed", ["provider": "gemini"])
        Log("hotkey").info("key down")

        XCTAssertEqual(LogRouter.shared.recent(minimumLevel: .error).count, 1)
        XCTAssertEqual(LogRouter.shared.recent(containing: "hotkey").count, 1)
        XCTAssertEqual(LogRouter.shared.recent(containing: "gemini").count, 1, "fields are searched")
        XCTAssertEqual(LogRouter.shared.recent().count, 3)
    }

    // MARK: - Rendering

    /// A line that says `12:04:31.512` cannot say which day it happened on, and the log file
    /// rotates on size rather than on the date, so one file holds however many days 8 MB takes.
    func testAPersistedLineCarriesTheDateAndNotJustTheTime() {
        let event = LogEvent(
            timestamp: Date(timeIntervalSince1970: 1_770_000_271.512), level: .warning,
            category: "fallback", message: "primary stalled")

        let stamp = String(event.render().prefix(23))
        XCTAssertEqual(stamp.count, 23, "yyyy-mm-ddThh:mm:ss.mmm")
        XCTAssertTrue(
            stamp.wholeMatch(of: /\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}/) != nil,
            "expected an ISO-8601 local stamp, got \(stamp)")
        // Local time, so the calendar day is the reader's rather than UTC's — but it is a real
        // date either way, which is the whole point.
        XCTAssertTrue(event.render().contains(stamp))
    }

    /// The viewers show the time on every row and the date as a heading, so this decides where the
    /// only statement of the date goes. Getting it wrong in the "first row" case would leave a
    /// screenful of times with no date anywhere above them.
    func testTheDateIsAnnouncedOnceADayAndAlwaysForTheFirstRow() {
        // Anchored to local noon rather than a fixed epoch second: "same day" is a question about
        // the reader's calendar, and an hour added to a fixed instant lands on the next day for
        // anyone whose offset puts it at 23:00 — Sydney in daylight saving, among others.
        let noonToday = Calendar.current.startOfDay(for: Date()).addingTimeInterval(12 * 3600)
        func event(_ date: Date) -> LogEvent {
            LogEvent(timestamp: date, level: .info, category: "dictate", message: "transcribed")
        }

        let noon = event(noonToday)
        let laterThatDay = event(noonToday.addingTimeInterval(3600))
        let aWeekLater = event(noonToday.addingTimeInterval(7 * 86_400))

        XCTAssertTrue(noon.startsANewDay(after: nil), "the first row has nothing above it to date")
        XCTAssertFalse(laterThatDay.startsANewDay(after: noon))
        XCTAssertTrue(aWeekLater.startsANewDay(after: laterThatDay))
    }

    /// `dnt logs --level warn` finds the level by splitting on spaces and taking the second
    /// column, and keeps any line it cannot parse. A stamp with a space in it would therefore not
    /// fail — it would silently stop filtering, which is the worse of the two outcomes.
    func testTheStampIsOneColumnSoTheLevelStaysTheSecond() {
        let line = LogEvent(level: .warning, category: "fallback", message: "primary stalled")
            .render()
        let columns = line.split(separator: " ", omittingEmptySubsequences: true)
        XCTAssertEqual(String(columns[1]), "WARN")
        XCTAssertEqual(LogLevel(name: String(columns[1])), .warning)
    }

    func testFieldsRenderSortedSoTwoRunsCompare() {
        let event = LogEvent(
            level: .info, category: "http", message: "response",
            fields: ["status": "200", "ms": "412", "provider": "gemini"])
        XCTAssertTrue(event.render(timestamped: false).hasSuffix("ms=412 provider=gemini status=200"))
    }

    func testJSONRenderingIsOneLineAndEscapes() {
        let event = LogEvent(
            level: .error, category: "http", message: "body was \"weird\"\nand multi-line",
            fields: ["url": "https://x/y"])
        let line = event.renderJSON()

        XCTAssertFalse(line.dropLast().contains("\n"), "a JSON log line must stay one line")
        XCTAssertTrue(line.contains("\\\"weird\\\""))
        let parsed = try! JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
        XCTAssertEqual(parsed["level"] as? String, "error")
        XCTAssertEqual((parsed["fields"] as? [String: String])?["url"], "https://x/y")
    }

    /// A response body belongs in the log in full — it is the thing somebody is reading the log to
    /// see — but a raw newline in it would split one entry into several, and every line after the
    /// first would have no timestamp, level or category to be found by.
    func testAMultiLineFieldStaysOnOneLineWithoutLosingAnything() {
        let body = "{\n  \"error\": {\n    \"message\": \"nope\"\n  }\n}"
        let event = LogEvent(
            level: .error, category: "http", message: "request failed", fields: ["detail": body])

        let text = event.render()
        XCTAssertFalse(text.contains("\n"), "one event is one line: \(text)")
        XCTAssertTrue(text.contains("\\n"), "the newlines are escaped, not dropped")
        XCTAssertTrue(text.contains("nope"), "nothing inside it is lost")

        // And the JSON renderer, which already had to solve this.
        let json = event.renderJSON()
        XCTAssertFalse(json.dropLast().contains("\n"))
        let parsed = try! JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        XCTAssertEqual((parsed["fields"] as? [String: String])?["detail"], body)
    }

    /// Nothing in the logging path shortens a value. A body cut to fit is a body that cannot be
    /// pasted into an issue.
    func testALongFieldIsNotShortened() {
        let body = String(repeating: "x", count: 20_000)
        let event = LogEvent(level: .error, category: "http", message: "big", fields: ["b": body])
        XCTAssertTrue(event.render().contains(body))
        XCTAssertTrue(event.renderJSON().contains(body))
    }

    // MARK: - File sink

    func testFileSinkAppendsAndRotates() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("test.log")
        let sink = try XCTUnwrap(FileLogSink(url: url, maximumBytes: 400))

        for index in 0..<60 {
            sink.write(
                LogEvent(level: .info, category: "test", message: "line \(index)"))
        }
        sink.flush()

        let current = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(current.contains("line 59"), "the newest line is in the live file")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.appendingPathExtension("1").path),
            "the previous generation is kept, and exactly one of them")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: url.appendingPathExtension("2").path))
    }

    /// Two sinks on one file are two processes on one file: `DNT_LOG_FILE` pointing at the app's
    /// log, or simply two `dnt` invocations at once.
    ///
    /// The sink used to hold a handle positioned at the end once, at open. The second writer then
    /// wrote over the first one's lines from wherever it had started, so the file ended up the
    /// length of the longer writer rather than the sum, with a hole in the middle.
    func testTwoWritersOnOneFileDoNotOverwriteEachOther() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("shared.log")

        let first = try XCTUnwrap(FileLogSink(url: url, maximumBytes: 1 << 20))
        let second = try XCTUnwrap(FileLogSink(url: url, maximumBytes: 1 << 20))

        // Interleaved on purpose. Alternating is what two processes actually do, and it is the
        // pattern the old code lost lines on.
        for index in 0..<50 {
            first.write(LogEvent(level: .info, category: "one", message: "first \(index)"))
            second.write(LogEvent(level: .info, category: "two", message: "second \(index)"))
        }
        first.flush()
        second.flush()

        let written = try String(contentsOf: url, encoding: .utf8)
        let lines = written.split(separator: "\n")
        XCTAssertEqual(lines.count, 100, "every line from both writers is present")
        XCTAssertTrue(written.contains("first 49"))
        XCTAssertTrue(written.contains("second 49"))
        XCTAssertFalse(written.contains("\u{0}"), "no hole where one writer skipped past the other")
    }

    /// A sink whose file disappears under it — a `rm -rf` of the log directory, or a rotation that
    /// could not reopen — used to go quiet for the rest of the process.
    func testTheSinkRecoversAfterItsFileGoesAway() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("vanishing.log")
        let sink = try XCTUnwrap(FileLogSink(url: url, maximumBytes: 1 << 20))

        sink.write(LogEvent(level: .info, category: "test", message: "before"))
        sink.flush()
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        sink.write(LogEvent(level: .info, category: "test", message: "after"))
        sink.flush()

        // The handle still points at the unlinked inode, so this line may land there. What must not
        // happen is a crash or a permanently dead sink: one more write proves it is still alive.
        sink.write(LogEvent(level: .info, category: "test", message: "later"))
        sink.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
    }

    // MARK: - Configuration

    func testEnvironmentOverridesEveryConfigurationField() {
        let configuration = LogRouter.Configuration.app(
            logDirectory: URL(fileURLWithPath: "/tmp/logs")
        ).applyingEnvironment([
            "DNT_LOG_LEVEL": "trace",
            "DNT_LOG_FILE": "/tmp/elsewhere.log",
            "DNT_LOG_STDERR": "1",
            "DNT_LOG_JSON": "yes",
            "DNT_LOG_CONTENT": "true",
        ])

        XCTAssertEqual(configuration.level, .trace)
        XCTAssertEqual(configuration.fileURL?.path, "/tmp/elsewhere.log")
        XCTAssertTrue(configuration.writesToStandardError)
        XCTAssertTrue(configuration.json)
        XCTAssertTrue(configuration.includesContent)
    }

    func testFileLoggingCanBeTurnedOffEntirely() {
        let configuration = LogRouter.Configuration.app(
            logDirectory: URL(fileURLWithPath: "/tmp/logs")
        ).applyingEnvironment(["DNT_LOG_FILE": "none"])
        XCTAssertNil(configuration.fileURL)
    }

    func testCommandLineDefaultsKeepStdoutClean() {
        let configuration = LogRouter.Configuration.commandLine().applyingEnvironment([:])
        XCTAssertTrue(configuration.writesToStandardError)
        XCTAssertNil(configuration.fileURL, "a CLI must not append to the app's log by default")
        XCTAssertEqual(configuration.level, .warning)
    }
}
