using DoNotType.Core;
using Xunit;

namespace DoNotType.Core.Tests;

/// <summary>
/// The log has one job beyond being useful: being safe to paste into an issue.
///
/// Most of these are about that. A logger that leaks a key is worse than no logger, because the
/// leak only shows up once someone has already sent the file to a stranger.
/// </summary>
public sealed class LoggingTests : IDisposable
{
    private readonly MemoryLogSink _sink = new();

    public LoggingTests() => LogRouter.Install([_sink], LogLevel.Trace);

    public void Dispose() => LogRouter.Install([], LogLevel.Off);

    /// <summary>
    /// Only this class's own lines.
    ///
    /// `LogRouter` is process-wide and xUnit runs test classes in parallel, so a history test
    /// inserting a record lands a line in the same sink. Filtering by category keeps these
    /// assertions about the logger rather than about which tests happened to run alongside them.
    /// </summary>
    private IReadOnlyList<LogEvent> Mine =>
        _sink.Events.Where(e => e.Category is "test" or "dictation" or "hotkey").ToList();

    [Fact]
    public void LevelsFilterFromTheBottom()
    {
        LogRouter.SetLevel(LogLevel.Warn);
        var log = new Log("test");
        log.Debug(() => "invisible");
        log.Info(() => "also invisible");
        log.Warn(() => "visible");
        log.Error(() => "visible too");

        Assert.Equal(["visible", "visible too"], Mine.Select(e => e.Message));
    }

    [Fact]
    public void OffSilencesEvenErrors()
    {
        LogRouter.SetLevel(LogLevel.Off);
        new Log("test").Error(() => "nope");
        Assert.Empty(Mine);
    }

    /// <summary>The reason messages are delegates: a trace call in a hot path must not build one.</summary>
    [Fact]
    public void AFilteredMessageIsNeverConstructed()
    {
        LogRouter.SetLevel(LogLevel.Error);
        var built = false;
        new Log("test").Debug(() =>
        {
            built = true;
            return "expensive";
        });
        Assert.False(built, "a filtered message must not be constructed");
    }

    [Theory]
    [InlineData("warn", LogLevel.Warn)]
    [InlineData("WARNING", LogLevel.Warn)]
    [InlineData("silent", LogLevel.Off)]
    [InlineData(" Debug ", LogLevel.Debug)]
    public void LevelNamesAcceptTheSpellingsPeopleType(string input, LogLevel expected) =>
        Assert.Equal(expected, LogLevelExtensions.Parse(input));

    [Fact]
    public void UnknownLevelNamesAreRejected() => Assert.Null(LogLevelExtensions.Parse("chatty"));

    [Fact]
    public void ARegisteredSecretIsMaskedWhereverItAppears()
    {
        const string key = "AIzaSyD-Not-A-Real-Key-000000000000000";
        LogRouter.Redact(key);

        new Log("test").Error(
            () => $"HTTP 400 from https://example.com/v1?key={key}",
            new Dictionary<string, string> { ["body"] = $"invalid key {key}" });

        var entry = Mine[0];
        Assert.DoesNotContain(key, entry.Message);
        Assert.DoesNotContain(key, entry.Fields["body"]);
        Assert.Contains("redacted", entry.Message);
    }

    /// <summary>
    /// The case registration cannot cover: a key belonging to another tool, echoed back by a
    /// provider this process never authenticated to.
    /// </summary>
    [Fact]
    public void UnregisteredKeyShapesAreStillMasked()
    {
        new Log("test").Info(() => "using sk-abcdefghijklmnopqrstuvwxyz012345 for that call");
        Assert.DoesNotContain("sk-abcdefghijklmnopqrstuvwxyz012345", Mine[0].Message);
    }

    [Theory]
    // Every one of these has been mistaken for a secret by a naive length rule at some point.
    [InlineData("gemini-3.6-flash")]
    [InlineData("voxtral-mini-latest")]
    [InlineData("transcription")]
    [InlineData("550e8400-e29b-41d4")]
    [InlineData("CredentialUIBroker")]
    [InlineData("AudioChunker.WrapInWavContainer")]
    public void OrdinaryTextSurvivesRedaction(string text) =>
        Assert.False(Redaction.LooksSecret(text), $"{text} is not a credential");

    [Fact]
    public void ALongOpaqueTokenIsMasked() =>
        Assert.True(Redaction.LooksSecret("a1b2c3d4e5f6g7h8i9j0k1l2m3n4o5p6q7r8"));

    [Fact]
    public void UrlCredentialsAreStrippedBeforeLogging()
    {
        var redacted = ProviderHttp.RedactUrl(
            "https://api.example.com/v1/listen?key=supersecretvalue&model=nova-3");
        Assert.DoesNotContain("supersecretvalue", redacted);
        Assert.Contains("model=nova-3", redacted);
    }

    [Fact]
    public void ContentIsWithheldByDefaultButItsSizeIsNot()
    {
        new Log("test").Content("transcript", () => "the thing I actually said");

        var entry = Mine[0];
        Assert.Equal("25", entry.Fields["chars"]);
        Assert.False(entry.Fields.ContainsKey("text"), "transcripts must not be logged by default");
    }

    [Fact]
    public void ContentIsIncludedWhenTurnedOn()
    {
        LogRouter.SetIncludesContent(true);
        new Log("test").Content("transcript", () => "the thing I actually said");
        Assert.Equal("the thing I actually said", Mine[0].Fields["text"]);
    }

    [Fact]
    public void RecentFiltersByLevelAndSearch()
    {
        var log = new Log("dictation");
        log.Info(() => "started recording");
        log.Error(() => "upload failed", new Dictionary<string, string> { ["provider"] = "gemini" });
        new Log("hotkey").Info(() => "key down");

        Assert.Single(LogRouter.Recent(containing: "hotkey"));
        Assert.Single(LogRouter.Recent(containing: "gemini"));
        Assert.Equal(2, LogRouter.Recent(containing: "dictation").Count);
        Assert.Single(
            LogRouter.Recent(minimumLevel: LogLevel.Error, containing: "dictation"));
    }

    /// <summary>
    /// A line that says <c>12:04:31.512</c> cannot say which day it happened on, and the log file
    /// rotates on size rather than on the date, so one file holds however many days it takes to
    /// fill. Matches `LoggingTests.testAPersistedLineCarriesTheDateAndNotJustTheTime` in Swift.
    /// </summary>
    [Fact]
    public void APersistedLineCarriesTheDateAndNotJustTheTime()
    {
        var entry = new LogEvent(
            1, new DateTimeOffset(2026, 8, 16, 12, 4, 31, 512, TimeSpan.Zero), LogLevel.Warn,
            "fallback", "primary stalled", new Dictionary<string, string>());

        Assert.StartsWith("2026-08-16T12:04:31.512 ", entry.Render());
    }

    /// <summary>
    /// The level is found by splitting the line on spaces and taking the second column, and an
    /// unparseable line is kept rather than dropped — so a stamp with a space in it would not
    /// fail, it would silently stop the filter filtering.
    /// </summary>
    [Fact]
    public void TheStampIsOneColumnSoTheLevelStaysTheSecond()
    {
        var line = new LogEvent(
            1, DateTimeOffset.Now, LogLevel.Warn, "fallback", "primary stalled",
            new Dictionary<string, string>()).Render();

        var columns = line.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        Assert.Equal("WARN", columns[1]);
    }

    [Fact]
    public void FieldsRenderSortedSoTwoRunsCompare()
    {
        var entry = new LogEvent(
            1, DateTimeOffset.Now, LogLevel.Info, "http", "response",
            new Dictionary<string, string>
            {
                ["status"] = "200",
                ["ms"] = "412",
                ["provider"] = "gemini",
            });
        Assert.EndsWith("ms=412 provider=gemini status=200", entry.Render(includeTime: false));
    }

    [Fact]
    public void TheFileSinkAppendsAndRotates()
    {
        var directory = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString());
        Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, "test.log");

        var sink = FileLogSink.TryCreate(path, maximumBytes: 400);
        Assert.NotNull(sink);

        for (var i = 0; i < 60; i++)
        {
            sink!.Write(new LogEvent(
                i, DateTimeOffset.Now, LogLevel.Info, "test", $"line {i}",
                new Dictionary<string, string>()));
        }

        Assert.Contains("line 59", File.ReadAllText(path));
        Assert.True(File.Exists(path + ".1"), "the previous generation is kept");
        Assert.False(File.Exists(path + ".1.1"), "and exactly one of them");

        Directory.Delete(directory, recursive: true);
    }

    [Fact]
    public void EnvironmentOverridesEveryConfigurationField()
    {
        var configuration = LogRouter.Configuration.App("C:\\logs").ApplyingEnvironment(
            new Dictionary<string, string?>
            {
                ["DNT_LOG_LEVEL"] = "trace",
                ["DNT_LOG_FILE"] = "C:\\elsewhere.log",
                ["DNT_LOG_STDERR"] = "1",
                ["DNT_LOG_CONTENT"] = "true",
            });

        Assert.Equal(LogLevel.Trace, configuration.Level);
        Assert.Equal("C:\\elsewhere.log", configuration.FilePath);
        Assert.True(configuration.WritesToStandardError);
        Assert.True(configuration.IncludesContent);
    }

    [Fact]
    public void FileLoggingCanBeTurnedOffEntirely()
    {
        var configuration = LogRouter.Configuration.App("C:\\logs")
            .ApplyingEnvironment(new Dictionary<string, string?> { ["DNT_LOG_FILE"] = "none" });
        Assert.Null(configuration.FilePath);
    }

    [Fact]
    public void CommandLineDefaultsKeepStdoutClean()
    {
        var configuration = LogRouter.Configuration.CommandLine()
            .ApplyingEnvironment(new Dictionary<string, string?>());
        Assert.True(configuration.WritesToStandardError);
        Assert.Null(configuration.FilePath);
        Assert.Equal(LogLevel.Warn, configuration.Level);
    }
}
