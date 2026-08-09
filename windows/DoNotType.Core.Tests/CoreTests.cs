using DoNotType.Core;
using Xunit;

namespace DoNotType.Core.Tests;

public class TokenBudgetTests
{
    [Fact]
    public void EstimateIsZeroForEmpty() => Assert.Equal(0, TokenBudget.Estimate(string.Empty));

    [Fact]
    public void ProseUsesWordAndCharBounds()
    {
        // 5 words, 25 chars -> max(6.5, 6.25) = 7
        Assert.Equal(7, TokenBudget.Estimate("the quick brown fox jumps"));
    }

    [Fact]
    public void CjkDenseTextUsesTheDenserBranch()
    {
        var han = new string('中', 100);
        Assert.Equal(77, TokenBudget.Estimate(han));
    }

    /// <summary>The caret is at the end, so the end is what we keep.</summary>
    [Fact]
    public void ClipKeepsTheTail()
    {
        Assert.Equal("fgh", TokenBudget.ClipKeepingTail("abcdefgh", 3));
        Assert.Equal("abc", TokenBudget.ClipKeepingHead("abcdefgh", 3));
        Assert.Equal("ab", TokenBudget.ClipKeepingTail("ab", 10));
    }
}

public class ContextEncoderTests
{
    private static string TextOf(InputPart part) => part is InputPart.Text text ? text.Value : string.Empty;

    [Fact]
    public void EmptyContextProducesNoParts() =>
        Assert.Empty(new ContextEncoder().Encode(new ScreenContext()));

    [Fact]
    public void ContextIsWrappedInDelimiters()
    {
        var parts = new ContextEncoder().Encode(new ScreenContext
        {
            AppName = "Notepad",
            VisibleText = string.Concat(Enumerable.Repeat("context ", 60)),
        });
        var joined = string.Join("\n", parts.Select(TextOf));

        Assert.Contains("REFERENCE ONLY, DO NOT TRANSCRIBE", joined);
        Assert.Contains("ONLY thing to transcribe", joined);
    }

    /// <summary>An empty labelled header costs tokens and invites the model to fill it in.</summary>
    [Fact]
    public void EmptySectionsAreOmittedEntirely()
    {
        var parts = new ContextEncoder().Encode(
            new ScreenContext { AppName = "cmd", TextBeforeCaret = "git comm" });
        var joined = string.Join("\n", parts.Select(TextOf));

        Assert.Contains("TEXT BEFORE CARET", joined);
        Assert.DoesNotContain("TEXT AFTER CARET", joined);
        Assert.DoesNotContain("SELECTED TEXT", joined);
    }

    [Fact]
    public void VisibleTextIsClippedKeepingTheTail()
    {
        var encoder = new ContextEncoder(visibleTextChars: 40, thinTextThreshold: 0);
        var joined = string.Join("\n", encoder
            .Encode(new ScreenContext { AppName = "X", VisibleText = new string('A', 100) + "CARET_END" })
            .Select(TextOf));

        Assert.Contains("CARET_END", joined);
        Assert.DoesNotContain(new string('A', 60), joined);
    }

    [Fact]
    public void ThinAccessibilityTextIsDetected()
    {
        Assert.True(new ScreenContext { VisibleText = "Layer 1" }.IsAccessibilityThin());
        Assert.False(new ScreenContext
        {
            VisibleText = string.Concat(Enumerable.Repeat("x ", 400)),
        }.IsAccessibilityThin());
    }
}

public class PromptBuilderTests
{
    private const string Template = """
        # PROMPT.md
        Preamble that must not be sent.

        <!-- BEGIN SYSTEM -->
        You are a transcription engine.
        5. {{FIDELITY_RULE}}
        <!-- END SYSTEM -->

        ### raw
        ```
        Fidelity is RAW.
        ```

        ### light
        ```
        Fidelity is LIGHT.
        ```

        ### tidy
        ```
        Fidelity is TIDY.
        ```
        """;

    [Fact]
    public void SystemInstructionExcludesEverythingOutsideTheMarkers()
    {
        var instruction = new PromptBuilder(Template).SystemInstruction(Fidelity.Raw);

        Assert.StartsWith("You are a transcription engine.", instruction);
        Assert.DoesNotContain("Preamble", instruction);
    }

    [Fact]
    public void ExactlyOneFidelityClauseIsSubstituted()
    {
        var light = new PromptBuilder(Template).SystemInstruction(Fidelity.Light);

        Assert.Contains("Fidelity is LIGHT.", light);
        Assert.DoesNotContain("RAW", light);
        Assert.DoesNotContain("{{FIDELITY_RULE}}", light);
    }

    [Fact]
    public void MissingMarkersThrowRatherThanProducingAnEmptyPrompt() =>
        Assert.Throws<InvalidOperationException>(
            () => new PromptBuilder("no markers here").SystemInstruction(Fidelity.Light));

    /// <summary>The real file has to build, or the app ships with a broken contract.</summary>
    [Fact]
    public void ShippedPromptFileBuildsForEveryFidelity()
    {
        var path = PromptBuilder.FindPromptFile();
        if (path is null) return; // not running from the repo tree

        var builder = PromptBuilder.FromFile(path);
        foreach (var fidelity in Enum.GetValues<Fidelity>())
        {
            var instruction = builder.SystemInstruction(fidelity);
            Assert.Contains("Context corrects SPELLING, never CONTENT", instruction);
            Assert.DoesNotContain("{{", instruction);
        }
    }
}

public class TranscriptParsingTests
{
    [Fact]
    public void PlainJson()
    {
        var parsed = Transcript.Parse("""{"transcript":"hello there","language":"en"}""");
        Assert.Equal("hello there", parsed.Text);
        Assert.Equal("en", parsed.Language);
    }

    /// <summary>Observed from the model even with a schema set.</summary>
    [Fact]
    public void MarkdownFencedJsonIsTolerated()
    {
        var parsed = Transcript.Parse("```json\n{\"transcript\": \"Gemini 3.5 Flash\", \"language\": \"en\"}\n```");
        Assert.Equal("Gemini 3.5 Flash", parsed.Text);
    }

    /// <summary>A dictation is more useful than an error when the model ignores the schema.</summary>
    [Fact]
    public void BareProseFallsBackToBeingTheTranscript() =>
        Assert.Equal("just the words", Transcript.Parse("just the words").Text);
}

public class HistoryStoreTests : IDisposable
{
    private readonly string _directory =
        Path.Combine(Path.GetTempPath(), $"dnt-{Guid.NewGuid()}");

    public void Dispose()
    {
        if (Directory.Exists(_directory)) Directory.Delete(_directory, recursive: true);
        GC.SuppressFinalize(this);
    }

    private static DictationRecord Record(DictationStatus status) =>
        new() { Status = status, Text = "hello", Model = "gemini-3.6-flash" };

    /// <summary>Without the recording, Retry is a button that cannot work.</summary>
    [Fact]
    public void FailedRecordsKeepAudioEvenWhenRetentionOfCompletedIsOff()
    {
        var store = new HistoryStore(_directory);
        store.Configure(RetentionPolicy.Forever, keepAudioForCompleted: false);

        var stored = store.Insert(Record(DictationStatus.Failed), [1, 2, 3, 4]);

        Assert.NotNull(stored.AudioFileName);
        Assert.True(stored.CanRetry);
    }

    [Fact]
    public void CompletedRecordsDiscardAudioByDefault()
    {
        var store = new HistoryStore(_directory);
        store.Configure(RetentionPolicy.Forever, keepAudioForCompleted: false);

        var stored = store.Insert(Record(DictationStatus.Completed), [1, 2, 3]);

        Assert.Null(stored.AudioFileName);
        Assert.False(stored.CanRetry);
    }

    [Fact]
    public void SucceedingReleasesTheRetainedAudio()
    {
        var store = new HistoryStore(_directory);
        store.Configure(RetentionPolicy.Forever, keepAudioForCompleted: false);

        var record = store.Insert(Record(DictationStatus.Failed), [1, 2, 3]);
        Assert.True(store.AudioBytes() > 0);

        record.Status = DictationStatus.Completed;
        store.Update(record);

        Assert.Equal(0, store.AudioBytes());
    }

    [Fact]
    public void RetryableReturnsOldestFirst()
    {
        var store = new HistoryStore(_directory);
        store.Configure(RetentionPolicy.Forever, keepAudioForCompleted: false);

        var older = new DictationRecord
        {
            CreatedAt = DateTimeOffset.Now.AddHours(-2), Status = DictationStatus.Failed,
        };
        var newer = new DictationRecord
        {
            CreatedAt = DateTimeOffset.Now, Status = DictationStatus.Pending,
        };
        store.Insert(newer, [1]);
        store.Insert(older, [1]);

        Assert.Equal([older.Id, newer.Id], store.Retryable().Select(r => r.Id));
    }

    [Fact]
    public void NeverRetentionWritesNothingToDisk()
    {
        var store = new HistoryStore(_directory);
        store.Configure(RetentionPolicy.Never, keepAudioForCompleted: false);

        store.Insert(Record(DictationStatus.Completed), [1, 2, 3]);

        Assert.False(File.Exists(Path.Combine(_directory, "history.json")));
    }

    [Fact]
    public void RecordsSurviveAcrossInstances()
    {
        var first = new HistoryStore(_directory);
        first.Configure(RetentionPolicy.Forever, keepAudioForCompleted: false);
        first.Insert(Record(DictationStatus.Completed), null);

        var second = new HistoryStore(_directory);
        second.Configure(RetentionPolicy.Forever, keepAudioForCompleted: false);
        Assert.Single(second.All());
    }
}

public class RetryClassificationTests
{
    /// <summary>Retrying a bad key burns the user's time; retrying a 503 is the point.</summary>
    [Fact]
    public void AuthFailuresAreNotRetried() =>
        Assert.False(TranscriptionService.IsTransient(
            new ProviderException("HTTP 401") { IsTransient = false }));

    [Fact]
    public void ServerAndNetworkFailuresAreRetried()
    {
        Assert.True(TranscriptionService.IsTransient(new ProviderException("HTTP 503")));
        Assert.True(TranscriptionService.IsTransient(new HttpRequestException("dropped")));
    }
}
