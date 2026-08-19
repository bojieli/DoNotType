using DoNotType.Core;
using System.Text.Json;
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

/// <summary>
/// These run against the shipped prompt/, not a fixture.
/// </summary>
/// <remarks>
/// The previous version of this class parsed a synthetic template, and that is exactly why it
/// passed for as long as the contract was one file: the fixture mentioned each marker once, so a
/// first-match search could not go wrong in it. The real file documented its own markers and every
/// request carried eight lines of that documentation. A test that cannot see the shipped bytes
/// cannot catch what happens to them.
/// </remarks>
public class PromptBuilderTests
{
    private static PromptBuilder? Shipped() =>
        PromptBuilder.FindPromptDirectory() is { } path ? new PromptBuilder(path) : null;

    /// <summary>
    /// Every test below returns early when the tree is not there, which is right for a packaged
    /// run and useless if it silently becomes the normal case. This one fails instead, so a broken
    /// discovery path cannot turn the whole class into a no-op that still reports green.
    /// </summary>
    [Fact]
    public void TheShippedPromptIsFoundFromTheTestRun()
    {
        var path = PromptBuilder.FindPromptDirectory();
        Assert.NotNull(path);
        Assert.True(File.Exists(Path.Combine(path, PromptPart.System.RelativePath)));
    }

    [Fact]
    public void ShippedPromptBuildsForEveryFidelity()
    {
        if (Shipped() is not { } builder) return; // not running from the repo tree

        foreach (var fidelity in Enum.GetValues<Fidelity>())
        {
            var instruction = builder.SystemInstruction(fidelity);
            Assert.StartsWith("You are a transcription engine.", instruction);
            Assert.Contains("Context corrects SPELLING, never CONTENT", instruction);
            Assert.DoesNotContain("{{", instruction);
        }
    }

    [Fact]
    public void DefaultTranscriptionRemovesDisfluencies()
    {
        if (Shipped() is not { } builder) return;
        var instruction = builder.SystemInstruction(Fidelity.Light);
        foreach (var phrase in new[]
                 {
                     "vocal fillers", "\"um\"", "\"ah\"", "\"actually\"", "\"basically\"",
                     "repetitions", "self-corrections", "final wording", "superseded wording",
                     "when they add no meaning",
                 })
            Assert.Contains(phrase, instruction);

        var raw = builder.SystemInstruction(Fidelity.Raw);
        Assert.DoesNotContain("self-corrections", raw);
        Assert.DoesNotContain("superseded wording", raw);
    }

    /// <summary>
    /// The regression test for the bug the split ended: the assembled instruction must be the
    /// contract and nothing else.
    /// </summary>
    [Fact]
    public void NothingButTheContractIsSent()
    {
        if (Shipped() is not { } builder) return;

        var instruction = builder.SystemInstruction(Fidelity.Light);
        foreach (var leak in new[] { "BEGIN SYSTEM", "END SYSTEM", "PromptBuilder", "dnt-eval", "changelog" })
        {
            Assert.DoesNotContain(leak, instruction);
        }
    }

    /// <summary>
    /// Substituting a clause must place it once. The fidelity rule appearing twice is measurable
    /// harm, not cosmetic -- see the 2026-08-09 entry in docs/PROMPT.md, where restating it moved
    /// substitution from 11/19 to 15/18.
    /// </summary>
    [Fact]
    public void TheFidelityClauseAppearsExactlyOnce()
    {
        if (Shipped() is not { } builder) return;

        var clause = builder.TextFor(PromptPart.Of(Fidelity.Light));
        var instruction = builder.SystemInstruction(Fidelity.Light);

        Assert.Equal(1, instruction.Split(clause).Length - 1);
        Assert.DoesNotContain("Fidelity is RAW", instruction);
        Assert.DoesNotContain("Fidelity is TIDY", instruction);
    }

    /// <summary>A part file is sent in full, so annotation in one is a mistake.</summary>
    [Fact]
    public void NoPartContainsMarkupThatWasMeantToBeStripped()
    {
        if (Shipped() is not { } builder) return;

        foreach (var part in PromptPart.All)
        {
            var text = builder.TextFor(part);
            Assert.DoesNotContain("<!--", text);
            Assert.DoesNotContain("```", text);
            if (part.IsClause) Assert.DoesNotContain("\n", text);
        }
    }

    /// <summary>Every part a picker can reach must exist, or choosing it fails at request time.</summary>
    [Fact]
    public void EveryPartResolves()
    {
        if (Shipped() is not { } builder) return;

        builder.Validate();
        foreach (var mode in TranscriptMode.All.Where(m => m.NeedsSecondPass))
        {
            var instruction = builder.SecondStageInstruction(mode);
            Assert.NotNull(instruction);
            Assert.DoesNotContain("{{", instruction);
        }
    }

    /// <summary>
    /// A checkout with CRLF must send the same bytes as one with LF.
    /// </summary>
    /// <remarks>
    /// Git rewrites these files on Windows under the default autocrlf, so without normalisation the
    /// Windows app shipped a different contract than macOS did -- four platforms sending four
    /// prompts, which is the drift the shared file exists to prevent, and it shows up in nothing a
    /// person reads. This is the test that caught it, on the Windows runner.
    /// </remarks>
    [Fact]
    public void LineEndingsInTheCheckoutDoNotChangeWhatIsSent()
    {
        if (PromptBuilder.FindPromptDirectory() is not { } shipped) return;

        var directory = Path.Combine(Path.GetTempPath(), "prompt-crlf-" + Guid.NewGuid().ToString("N"));
        try
        {
            foreach (var part in PromptPart.All)
            {
                var destination = Path.Combine(directory, part.RelativePath);
                Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
                var text = File.ReadAllText(Path.Combine(shipped, part.RelativePath))
                    .Replace("\r\n", "\n").Replace("\n", "\r\n");
                File.WriteAllText(destination, text);
            }

            var lf = new PromptBuilder(shipped);
            var crlf = new PromptBuilder(directory);
            foreach (var fidelity in Enum.GetValues<Fidelity>())
            {
                Assert.Equal(lf.SystemInstruction(fidelity), crlf.SystemInstruction(fidelity));
            }
            foreach (var part in PromptPart.All)
            {
                Assert.Equal(lf.TextFor(part), crlf.TextFor(part));
            }
        }
        finally
        {
            if (Directory.Exists(directory)) Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public void AMissingPartNamesTheFileAndThePart()
    {
        var builder = new PromptBuilder(Path.Combine(Path.GetTempPath(), "nonexistent-prompt-dir"));
        var error = Assert.Throws<InvalidOperationException>(
            () => builder.SystemInstruction(Fidelity.Light));

        Assert.Contains("system.md", error.Message);
        Assert.Contains("nonexistent-prompt-dir", error.Message);
    }
}

/// <summary>Per-part overrides, and the one-time split of the single-file format they replaced.</summary>
public class PromptStoreTests : IDisposable
{
    private readonly string _directory = Path.Combine(
        Path.GetTempPath(), "prompt-store-" + Guid.NewGuid().ToString("N"));

    public void Dispose()
    {
        if (Directory.Exists(_directory)) Directory.Delete(_directory, recursive: true);
        GC.SuppressFinalize(this);
    }

    /// <summary>The reason for splitting, as a test: editing one part must not freeze the others.</summary>
    [Fact]
    public void EditingOnePartLeavesTheRestShipped()
    {
        if (PromptBuilder.FindPromptDirectory() is not { } bundled) return;

        var store = new PromptStore(_directory);
        store.Save("Fidelity is MINE.", PromptPart.Of(Fidelity.Light));

        Assert.Equal([PromptPart.Of(Fidelity.Light)], store.CustomParts);

        var instruction = store.Builder(bundled).SystemInstruction(Fidelity.Light);
        Assert.Contains("Fidelity is MINE.", instruction);
        Assert.StartsWith("You are a transcription engine.", instruction);

        var raw = store.Builder(bundled).SystemInstruction(Fidelity.Raw);
        Assert.Contains("Fidelity is RAW", raw);
    }

    [Fact]
    public void APartThatWouldDropItsClauseIsRejectedAndNotWritten()
    {
        var store = new PromptStore(_directory);
        var error = Assert.Throws<InvalidOperationException>(
            () => store.Save("No placeholder in here.", PromptPart.System));

        Assert.Contains("{{FIDELITY_RULE}}", error.Message);
        Assert.False(store.IsCustom(PromptPart.System));
        Assert.Throws<InvalidOperationException>(() => store.Save("   ", PromptPart.Rewrite));
    }

    [Fact]
    public void RestoringOnePartLeavesTheOthersEdited()
    {
        var store = new PromptStore(_directory);
        store.Save("MINE. {{FIDELITY_RULE}}", PromptPart.System);
        store.Save("Fidelity is MINE.", PromptPart.Of(Fidelity.Tidy));

        store.Restore(PromptPart.System);
        Assert.Equal([PromptPart.Of(Fidelity.Tidy)], store.CustomParts);

        store.RestoreAll();
        Assert.Empty(store.CustomParts);
    }

    /// <summary>
    /// Migrating a copy of the shipped file must produce no overrides at all -- not twelve pinned
    /// to whatever the contract said the day it was copied.
    /// </summary>
    [Fact]
    public void MigratingAnUnchangedCopyProducesNoOverrides()
    {
        if (PromptBuilder.FindPromptDirectory() is not { } bundled) return;

        var store = new PromptStore(_directory);
        Directory.CreateDirectory(_directory);
        File.WriteAllText(store.LegacyPath, LegacyFile(bundled));

        var migration = store.MigrateLegacyPrompt(bundled);
        Assert.NotNull(migration);
        Assert.Empty(migration.Migrated);
        Assert.False(File.Exists(store.LegacyPath));
        Assert.True(File.Exists(migration.ArchivedAt));
    }

    [Fact]
    public void MigrationKeepsOnlyTheEditedParts()
    {
        if (PromptBuilder.FindPromptDirectory() is not { } bundled) return;

        var store = new PromptStore(_directory);
        Directory.CreateDirectory(_directory);
        File.WriteAllText(
            store.LegacyPath,
            LegacyFile(bundled).Replace("Fidelity is TIDY.", "Fidelity is CUSTOM."));

        var migration = store.MigrateLegacyPrompt(bundled);
        Assert.NotNull(migration);
        Assert.Equal([PromptPart.Of(Fidelity.Tidy)], migration.Migrated);
        Assert.Contains(
            "Fidelity is CUSTOM.", store.Builder(bundled).SystemInstruction(Fidelity.Tidy));
    }

    /// <summary>
    /// The migrator must not repeat the bug it is migrating away from: a user's custom prompt was
    /// usually a copy of the shipped file, which quoted the marker in a sentence above the real one.
    /// </summary>
    [Fact]
    public void MigrationIgnoresAMarkerQuotedInProse()
    {
        if (PromptBuilder.FindPromptDirectory() is not { } bundled) return;

        var store = new PromptStore(_directory);
        Directory.CreateDirectory(_directory);
        File.WriteAllText(store.LegacyPath, """
            # PROMPT.md

            `PromptBuilder` reads everything below the `<!-- BEGIN SYSTEM -->` marker, substitutes
            `{{FIDELITY_RULE}}` with the active fidelity clause.

            <!-- BEGIN SYSTEM -->
            You are a transcription engine.
            5. {{FIDELITY_RULE}}
            <!-- END SYSTEM -->

            ### light
            ```
            Fidelity is LIGHT.
            ```
            """);

        store.MigrateLegacyPrompt(bundled);

        var system = File.ReadAllText(store.PathFor(PromptPart.System));
        Assert.StartsWith("You are a transcription engine.", system);
        Assert.DoesNotContain("PromptBuilder", system);
        Assert.DoesNotContain("BEGIN SYSTEM", system);
    }

    [Fact]
    public void NothingToMigrateIsNotAnError()
    {
        if (PromptBuilder.FindPromptDirectory() is not { } bundled) return;
        Assert.Null(new PromptStore(_directory).MigrateLegacyPrompt(bundled));
    }

    /// <summary>Rebuilds the old single-file format out of the shipped parts.</summary>
    private static string LegacyFile(string bundled)
    {
        var source = new PromptSource(bundled);
        string Fenced(string heading, PromptPart part) =>
            $"### {heading}\n```\n{source.EditableTextFor(part)}\n```\n\n";

        var text = "# PROMPT.md\n\nPreamble.\n\n";
        text += $"<!-- BEGIN SYSTEM -->\n{source.EditableTextFor(PromptPart.System)}\n<!-- END SYSTEM -->\n\n";
        text += $"<!-- BEGIN REWRITE -->\n{source.EditableTextFor(PromptPart.Rewrite)}\n<!-- END REWRITE -->\n\n";
        text += $"<!-- BEGIN SUMMARY -->\n{source.EditableTextFor(PromptPart.Summary)}\n<!-- END SUMMARY -->\n\n";
        foreach (var fidelity in Enum.GetValues<Fidelity>())
        {
            text += Fenced(fidelity.Id(), PromptPart.Of(fidelity));
        }
        foreach (var style in Enum.GetValues<RewriteStyle>().Where(s => s != RewriteStyle.Verbatim))
        {
            text += Fenced($"style: {style.Id()}", PromptPart.Of(style));
        }
        foreach (var style in Enum.GetValues<SummaryStyle>())
        {
            text += Fenced($"summary: {style.Id()}", PromptPart.Of(style));
        }
        return text;
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
            CreatedAt = DateTimeOffset.Now.AddHours(-2),
            Status = DictationStatus.Failed,
        };
        var newer = new DictationRecord
        {
            CreatedAt = DateTimeOffset.Now,
            Status = DictationStatus.Pending,
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

        Assert.Empty(store.All());
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
        Assert.False(File.Exists(Path.Combine(_directory, "history.json.tmp")));
    }

    [Fact]
    public void PersistedAudioNamesCannotEscapeTheHistoryDirectory()
    {
        Directory.CreateDirectory(_directory);
        var outside = Path.Combine(_directory, "outside.wav");
        File.WriteAllBytes(outside, [1, 2, 3]);
        var store = new HistoryStore(_directory);
        store.Configure(RetentionPolicy.Forever, keepAudioForCompleted: true);
        var record = store.Insert(Record(DictationStatus.Failed), [4, 5, 6]);
        record.AudioFileName = "../outside.wav";
        store.Update(record);

        Assert.Null(store.AudioFor(record));
        store.Delete(record.Id);
        Assert.True(File.Exists(outside));
    }

    [Fact]
    public void FailedIndexReplacementDoesNotDeleteRetryAudio()
    {
        var store = new HistoryStore(_directory);
        store.Configure(RetentionPolicy.Forever, keepAudioForCompleted: false);
        var record = store.Insert(Record(DictationStatus.Failed), [1, 2, 3]);
        Assert.NotNull(store.AudioFor(record));

        // A directory at the temporary filename deterministically makes the replacement fail.
        Directory.CreateDirectory(Path.Combine(_directory, "history.json.tmp"));
        store.Delete(record.Id);

        Assert.NotNull(store.AudioFor(record));
        Assert.Single(store.All());
        Assert.Single(new HistoryStore(_directory).All());
    }

    [Fact]
    public void RecordsCannotMutateTheStoreWithoutAnUpdate()
    {
        var store = new HistoryStore(_directory);
        var returned = store.Insert(
            new DictationRecord
            {
                Status = DictationStatus.Completed,
                Text = "durable",
                Model = "test",
            },
            null);

        returned.Text = "changed outside";
        var fromList = store.All().Single();
        fromList.Text = "also changed outside";

        Assert.Equal("durable", store.All().Single().Text);
        Assert.Equal("durable", new HistoryStore(_directory).All().Single().Text);
    }

    [Fact]
    public void RestartRemovesOnlyUnreferencedManagedAudio()
    {
        var first = new HistoryStore(_directory);
        var retained = first.Insert(Record(DictationStatus.Failed), [1, 2, 3]);
        var audioDirectory = Path.Combine(_directory, "audio");
        var orphan = Path.Combine(audioDirectory, $"{Guid.NewGuid()}.wav");
        var unrelated = Path.Combine(audioDirectory, "notes.wav");
        File.WriteAllBytes(orphan, [4, 5, 6]);
        File.WriteAllBytes(unrelated, [7, 8, 9]);

        var restarted = new HistoryStore(_directory);
        _ = restarted.All();

        Assert.NotNull(restarted.AudioFor(retained));
        Assert.False(File.Exists(orphan));
        Assert.True(File.Exists(unrelated));
    }

    [Fact]
    public void UnreadableIndexPreservesUnreferencedAudioForRecovery()
    {
        var audioDirectory = Path.Combine(_directory, "audio");
        Directory.CreateDirectory(audioDirectory);
        var recoverable = Path.Combine(audioDirectory, $"{Guid.NewGuid()}.wav");
        File.WriteAllBytes(recoverable, [1, 2, 3]);
        File.WriteAllText(Path.Combine(_directory, "history.json"), "not json");

        _ = new HistoryStore(_directory).All();

        Assert.True(File.Exists(recoverable));
    }
}

public class AtomicFileTests : IDisposable
{
    private readonly string _directory =
        Path.Combine(Path.GetTempPath(), $"dnt-atomic-{Guid.NewGuid()}");

    public void Dispose()
    {
        if (Directory.Exists(_directory)) Directory.Delete(_directory, recursive: true);
        GC.SuppressFinalize(this);
    }

    [Fact]
    public void RepeatedReplacementsAreCompleteAndLeaveNoTemporaryFiles()
    {
        var path = Path.Combine(_directory, "settings.json");
        for (var index = 0; index < 40; index++)
        {
            AtomicFile.ReplaceText(path, JsonSerializer.Serialize(new { index }));
            using var document = JsonDocument.Parse(File.ReadAllText(path));
            Assert.Equal(index, document.RootElement.GetProperty("index").GetInt32());
        }

        Assert.Empty(Directory.GetFiles(_directory, "*.tmp"));
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

public class HistoryQueryTests
{
    private static DictationRecord Record(
        string text, DictationStatus status = DictationStatus.Completed,
        string? app = null, string? error = null, int minutesAgo = 0) =>
        new()
        {
            CreatedAt = DateTimeOffset.Now.AddMinutes(-minutesAgo),
            Status = status,
            Text = text,
            ErrorMessage = error,
            AppName = app,
        };

    private static readonly List<DictationRecord> Corpus =
    [
        Record("Ship the pricing page today", app: "Slack", minutesAgo: 5),
        Record("Refactor the ContextEncoder", app: "Notepad", minutesAgo: 60),
        Record("", DictationStatus.Failed, app: "Slack", error: "Rate limited — saved", minutesAgo: 10),
        Record("", DictationStatus.Pending, app: "Notepad", error: "Offline when recorded.", minutesAgo: 1),
    ];

    [Fact]
    public void EmptyQueryReturnsEverythingNewestFirst()
    {
        var results = new HistoryQuery().Apply(Corpus);
        Assert.Equal(Corpus.Count, results.Count);
        Assert.Equal("Notepad", results[0].AppName); // the 1-minute-old pending one
    }

    [Fact]
    public void TextSearchIsCaseInsensitive() =>
        Assert.Single(new HistoryQuery { Text = "PRICING" }.Apply(Corpus));

    /// <summary>When hunting a failure the message is what you remember, not the transcript.</summary>
    [Fact]
    public void SearchCoversErrorMessages()
    {
        var results = new HistoryQuery { Text = "rate limited" }.Apply(Corpus);
        Assert.Single(results);
        Assert.Equal(DictationStatus.Failed, results[0].Status);
    }

    [Fact]
    public void NeedsAttentionFiltersToRetryableStates()
    {
        var results = new HistoryQuery
        {
            Status = HistoryQuery.StatusFilter.NeedsAttention,
        }.Apply(Corpus);

        Assert.Equal(2, results.Count);
        Assert.All(results, r => Assert.NotEqual(DictationStatus.Completed, r.Status));
    }

    [Fact]
    public void FiltersCombine()
    {
        var results = new HistoryQuery
        {
            AppName = "Slack",
            Status = HistoryQuery.StatusFilter.NeedsAttention,
        }.Apply(Corpus);

        Assert.Single(results);
    }

    [Fact]
    public void AppNamesAreDeduplicatedAndSorted() =>
        Assert.Equal(["Notepad", "Slack"], HistoryQuery.AppNames(Corpus));
}

/// <summary>
/// The same invariants the Swift and Kotlin suites assert. Three ports of one calculation are
/// three chances for it to disagree with itself, and a stats screen that reports different numbers
/// on different platforms is worse than no stats screen.
/// </summary>
public class PerformanceStatsTests
{
    private static DictationRecord Record(
        DictationStatus status = DictationStatus.Completed,
        string text = "one two three",
        double? latency = 3,
        double spoken = 6,
        int retries = 0,
        string model = "gemini-3.6-flash") => new()
        {
            Status = status,
            Text = text,
            LatencySeconds = latency,
            DurationSeconds = spoken,
            RetryCount = retries,
            Model = model,
        };

    [Fact]
    public void EmptyHistoryProducesNoMisleadingZeroes()
    {
        var stats = PerformanceStats.Compute([]);
        Assert.Equal(0, stats.Total);
        Assert.Null(stats.MedianLatency);
        Assert.Null(stats.SuccessRate); // 0/0 is not a 0% success rate
        Assert.Null(stats.RealTimeFactor);
    }

    [Fact]
    public void CountsByStatus()
    {
        var stats = PerformanceStats.Compute([
            Record(), Record(),
            Record(status: DictationStatus.Failed, latency: null),
            Record(status: DictationStatus.Pending, latency: null),
        ]);
        Assert.Equal(4, stats.Total);
        Assert.Equal(2, stats.Completed);
        Assert.Equal(1, stats.Failed);
        Assert.Equal(1, stats.Pending);
        Assert.Equal(0.5, stats.SuccessRate);
    }

    /// <summary>
    /// A failure's latency measures how long an error took to arrive. Folding it in would make a
    /// fast app with a bad key look slow.
    /// </summary>
    [Fact]
    public void FailedDictationsDoNotContributeTimings()
    {
        var stats = PerformanceStats.Compute([
            Record(latency: 2), Record(status: DictationStatus.Failed, latency: 90),
        ]);
        Assert.Equal(2, stats.MedianLatency);
    }

    [Fact]
    public void MedianIsNotDraggedByAnOutlier()
    {
        var stats = PerformanceStats.Compute([
            Record(latency: 2), Record(latency: 2), Record(latency: 3), Record(latency: 3),
            Record(latency: 120),
        ]);
        Assert.Equal(3, stats.MedianLatency);
        Assert.Equal(120, stats.P95Latency); // p95 is where the bad case is meant to show up
    }

    [Fact]
    public void PercentileUsesNearestRank()
    {
        double[] values = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10];
        Assert.Equal(5, PerformanceStats.Percentile(values, 0.5));
        Assert.Equal(10, PerformanceStats.Percentile(values, 0.95));
        Assert.Null(PerformanceStats.Percentile([], 0.5));
        Assert.Equal(7, PerformanceStats.Percentile([7], 0.95));
    }

    /// <summary>Zero means "not measured", like null does — never "instant".</summary>
    [Fact]
    public void UnmeasuredRecordsAreExcludedRatherThanCountedAsInstant()
    {
        var stats = PerformanceStats.Compute([
            Record(latency: null), Record(latency: 0), Record(latency: 4),
        ]);
        Assert.Equal(4, stats.MedianLatency);
    }

    [Fact]
    public void RealTimeFactorComparesWaitToSpeech()
    {
        var stats = PerformanceStats.Compute([Record(latency: 3, spoken: 6)]);
        Assert.Equal(0.5, stats.RealTimeFactor!.Value, 3);
    }

    [Fact]
    public void RetriesAreCountedPerDictationNotPerAttempt()
    {
        var stats = PerformanceStats.Compute([
            Record(retries: 3), Record(retries: 0), Record(retries: 1),
        ]);
        Assert.Equal(2, stats.Retried);
    }

    [Fact]
    public void WordsAndSpeechAccumulate()
    {
        var stats = PerformanceStats.Compute([
            Record(text: "one two three", spoken: 6), Record(text: "four five", spoken: 4),
        ]);
        Assert.Equal(5, stats.Words);
        Assert.Equal(10, stats.SpokenSeconds);
    }

    [Fact]
    public void DurationFormattingMatchesTheOtherPorts()
    {
        Assert.Equal("420 ms", PerformanceStats.FormatDuration(0.42));
        Assert.Equal("3.5 s", PerformanceStats.FormatDuration(3.46));
        Assert.Equal("2m 5s", PerformanceStats.FormatDuration(125));
        Assert.Equal("1h 2m", PerformanceStats.FormatDuration(3_725));
        Assert.Equal("—", PerformanceStats.FormatDuration(null));
    }

    [Fact]
    public void BreakdownGroupsByModelMostUsedFirst()
    {
        var breakdown = ModelPerformance.Breakdown([
            Record(model: "gemini-3.6-flash"), Record(model: "gemini-3.6-flash"),
            Record(model: "gemini-2.5-flash"),
        ]);
        Assert.Equal(2, breakdown.Count);
        Assert.Equal("gemini-3.6-flash", breakdown[0].Model);
        Assert.Equal(2, breakdown[0].Stats.Total);
    }
}

/// <summary>
/// Mirrors <c>AudioChunkerTests.swift</c>. Getting the WAV arithmetic subtly wrong would silently
/// corrupt audio, and nothing downstream would notice a missing second of speech.
/// </summary>
public class AudioChunkerTests
{
    /// <summary>
    /// Builds a WAV whose loud passages are separated by true silence, so a correct splitter has
    /// somewhere obvious to cut and an incorrect one has somewhere obvious to be caught.
    /// </summary>
    private static byte[] Speech(params (double Loud, double Silence)[] segments)
    {
        var pcm = new List<byte>();
        var phase = 0.0;

        foreach (var (loud, silence) in segments)
        {
            for (var i = 0; i < (int)(loud * 16_000); i++)
            {
                phase += 2 * Math.PI * 220 / 16_000;
                var sample = (short)(Math.Sin(phase) * 12_000);
                pcm.Add((byte)(sample & 0xFF));
                pcm.Add((byte)((sample >> 8) & 0xFF));
            }
            pcm.AddRange(new byte[(int)(silence * 16_000) * 2]);
        }
        return AudioChunker.WrapInWavContainer(pcm.ToArray());
    }

    private static byte[] Seconds(double value) => Speech((value, 0));

    [Fact]
    public void ShortRecordingsAreNotSplit()
    {
        var chunks = AudioChunker.Split(Seconds(20));
        Assert.Single(chunks);
        Assert.Equal(20, chunks[0].DurationSeconds, 1);
    }

    /// <summary>Unparseable data is passed through whole rather than mangled.</summary>
    [Fact]
    public void NonWavDataIsPassedThroughUntouched()
    {
        var junk = "not a wav file at all"u8.ToArray();
        var chunks = AudioChunker.Split(junk);
        Assert.Single(chunks);
        Assert.Equal(junk, chunks[0].Data);
    }

    /// <summary>
    /// Every sample must appear in exactly one chunk. A splitter that drops a second of audio loses
    /// a word, and nothing downstream would ever notice.
    /// </summary>
    [Fact]
    public void NoAudioIsLostOrDuplicated()
    {
        var original = Speech(Enumerable.Repeat((55.0, 4.0), 6).ToArray());
        var chunks = AudioChunker.Split(original);

        var rejoined = chunks.SelectMany(chunk => AudioChunker.PcmBody(chunk.Data)!).ToArray();
        Assert.Equal(AudioChunker.PcmBody(original)!, rejoined);
    }

    [Fact]
    public void ChunkOffsetsAreContiguous()
    {
        var chunks = AudioChunker.Split(Speech(Enumerable.Repeat((55.0, 4.0), 6).ToArray()));
        Assert.True(chunks.Count > 1);
        for (var i = 1; i < chunks.Count; i++)
        {
            Assert.Equal(
                chunks[i - 1].StartSeconds + chunks[i - 1].DurationSeconds,
                chunks[i].StartSeconds, 2);
        }
    }

    /// <summary>The point of the whole exercise: cuts land in silence, not mid-word.</summary>
    [Fact]
    public void CutsLandInSilence()
    {
        var segments = Enumerable.Repeat((55.0, 4.0), 6).ToArray();
        var chunks = AudioChunker.Split(Speech(segments));
        Assert.True(chunks.Count > 1);

        foreach (var chunk in chunks.SkipLast(1))
        {
            var body = AudioChunker.PcmBody(chunk.Data)!;
            var tail = body[^1600..]; // final 50 ms
            var peak = 0;
            for (var i = 0; i + 1 < tail.Length; i += 2)
            {
                peak = Math.Max(peak, Math.Abs((short)(tail[i] | (tail[i + 1] << 8))));
            }
            Assert.True(peak < 500, $"chunk {chunk.Index} ends mid-speech (peak {peak})");
        }
    }

    /// <summary>A trailing two-second fragment transcribes badly, so the last cut is skipped.</summary>
    [Fact]
    public void FinalChunkIsNotAStub()
    {
        var chunks = AudioChunker.Split(Speech((55, 4), (55, 4), (63, 0)));
        Assert.True(chunks[^1].DurationSeconds > 15);
    }

    [Fact]
    public void ContinuousSpeechWithoutVadPauseIsNotSplit() =>
        Assert.Single(AudioChunker.Split(Seconds(300)));

    [Fact]
    public void ShortDipIsNotAWordBoundary() =>
        Assert.Single(AudioChunker.Split(Speech((55, 0.2), (65, 0))));

    [Fact]
    public void StreamingWaitsForThresholdAndEmitsDuringCapture()
    {
        var body = AudioChunker.PcmBody(Speech((55, 4), (35, 0)))!;
        var segmenter = new AudioChunker.StreamingSegmenter();
        Assert.Empty(segmenter.Append(body[..(90 * 32_000)]));
        var ready = segmenter.Append(body[(90 * 32_000)..]);
        Assert.Single(ready);
        Assert.Equal(57, ready[0].DurationSeconds, 1);
        Assert.Equal(37, segmenter.Finish()!.Value.DurationSeconds, 1);
    }

    [Fact]
    public void GeneratedChunksAreValidWavFiles()
    {
        foreach (var chunk in AudioChunker.Split(
            Speech(Enumerable.Repeat((55.0, 4.0), 6).ToArray())))
        {
            Assert.Equal("RIFF"u8.ToArray(), chunk.Data[..4]);
            Assert.Equal("WAVE"u8.ToArray(), chunk.Data[8..12]);

            // The RIFF size field must match the real length or strict decoders reject the file.
            var declared = BitConverter.ToInt32(chunk.Data, 4);
            Assert.Equal(chunk.Data.Length - 8, declared);
            Assert.Equal(0, AudioChunker.PcmBody(chunk.Data)!.Length % 2);
        }
    }

    /// <summary>Real recorders emit LIST/INFO chunks before the data.</summary>
    [Fact]
    public void DataChunkIsFoundPastExtraMetadataChunks()
    {
        var plain = Seconds(2);
        var body = AudioChunker.PcmBody(plain)!;

        var withMetadata = new List<byte>(plain[..36]);
        withMetadata.AddRange("LIST"u8.ToArray());
        withMetadata.AddRange(BitConverter.GetBytes(4));
        withMetadata.AddRange("INFO"u8.ToArray());
        withMetadata.AddRange("data"u8.ToArray());
        withMetadata.AddRange(BitConverter.GetBytes(body.Length));
        withMetadata.AddRange(body);

        Assert.Equal(body.Length, AudioChunker.PcmBody(withMetadata.ToArray())!.Length);
    }

    [Fact]
    public void StitchJoinsWithASingleSpaceAndDropsEmptyPieces()
    {
        Assert.Equal("one two three four", AudioChunker.Stitch(["one two", "three four"]));
        Assert.Equal("one two", AudioChunker.Stitch(["  one  ", "", "\n", " two"]));
        Assert.Equal(string.Empty, AudioChunker.Stitch([]));
    }

    /// <summary>
    /// Zero audio tokens is the signal a provider dropped the audio. Summing two unreported values
    /// into zero would fire that alarm on a provider that simply does not report usage.
    /// </summary>
    [Fact]
    public void UsageAddsAcrossChunksWithoutInventingZeroes()
    {
        var total = TokenUsage.Add(new TokenUsage(10, 4, 100), new TokenUsage(10, 6, 200));
        Assert.Equal(new TokenUsage(20, 10, 300), total);

        Assert.Null(TokenUsage.Add(new TokenUsage(), new TokenUsage()).AudioTokens);
        Assert.Equal(100, TokenUsage.Add(new TokenUsage(AudioTokens: 100), new TokenUsage()).AudioTokens);
    }
}

/// <summary>
/// Checks this port of the Ogg container against the Swift reference, byte for byte.
/// </summary>
/// <remarks>
/// The container is the part most likely to be subtly wrong in a way that still produces a file
/// decoders mostly accept — the Swift version shipped two such bugs before these suites existed,
/// one visible only as a message at the very end of ffprobe's output. "It decodes on my machine" is
/// not the same as "it is the same stream".
///
/// Regenerate with <c>swift run dnt-eval ogg-golden eval/conformance/ogg-reference.bin</c>.
/// </remarks>
public class OggOpusWriterTests
{
    private static string? ReferenceFile()
    {
        var directory = new DirectoryInfo(Directory.GetCurrentDirectory());
        for (var depth = 0; depth < 10 && directory is not null; depth++)
        {
            var candidate = Path.Combine(directory.FullName, "eval", "conformance", "ogg-reference.bin");
            if (File.Exists(candidate))
            {
                return candidate;
            }
            directory = directory.Parent;
        }
        return null;
    }

    /// <summary>The same input the Swift <c>ogg-golden</c> command uses.</summary>
    private static byte[] WriteReferenceStream()
    {
        var writer = new OggOpusWriter();
        writer.Begin();
        for (var index = 0; index < 120; index++)
        {
            var packet = new byte[40];
            for (var i = 0; i < 40; i++)
            {
                packet[i] = (byte)(i + index);
            }
            writer.Append(packet, 320);
        }
        return writer.Finish();
    }

    [Fact]
    public void OutputIsByteIdenticalToTheSwiftReference()
    {
        var reference = ReferenceFile();
        if (reference is null)
        {
            return; // eval/ not reachable from this working directory
        }

        Assert.Equal(File.ReadAllBytes(reference), WriteReferenceStream());
    }

    /// <summary>
    /// 0x89A1897F is the published check value for CRC-32/MPEG-2, which is the variant Ogg
    /// specifies. An implementation that reflects its input or seeds with 0xFFFFFFFF produces a
    /// plausible-looking checksum and fails here rather than in the field.
    /// </summary>
    [Fact]
    public void CrcMatchesThePublishedCheckValue()
    {
        Assert.Equal(0u, OggOpusWriter.Crc32([]));
        Assert.Equal(0u, OggOpusWriter.Crc32([0]));
        Assert.Equal(0x89A1897Fu, OggOpusWriter.Crc32("123456789"u8));
        Assert.Equal(0x5FB0A94Fu, OggOpusWriter.Crc32("OggS"u8));
    }

    private static List<int> PageOffsets(byte[] data)
    {
        var offsets = new List<int>();
        for (var index = 0; index <= data.Length - 4; index++)
        {
            if (data[index] == 'O' && data[index + 1] == 'g'
                && data[index + 2] == 'g' && data[index + 3] == 'S')
            {
                offsets.Add(index);
            }
        }
        return offsets;
    }

    [Fact]
    public void StreamOpensWithBothHeadersAndEndsWithTheEosFlag()
    {
        var data = WriteReferenceStream();
        var offsets = PageOffsets(data);

        Assert.Equal(0x02, data[offsets[0] + 5]);
        Assert.Equal(0x04, data[offsets[^1] + 5] & 0x04);
        Assert.True(
            data[offsets[^1] + 27] != 0,
            "the EOS page must carry a real packet, not a zero-length one");
    }

    [Fact]
    public void EveryPageChecksumVerifies()
    {
        var data = WriteReferenceStream();
        var offsets = PageOffsets(data);

        for (var index = 0; index < offsets.Count; index++)
        {
            var end = index + 1 < offsets.Count ? offsets[index + 1] : data.Length;
            var page = data[offsets[index]..end];

            var stored = BitConverter.ToUInt32(page, 22);
            for (var byteIndex = 22; byteIndex < 26; byteIndex++)
            {
                page[byteIndex] = 0;
            }

            Assert.Equal(stored, OggOpusWriter.Crc32(page));
        }
    }
}

/// <summary>
/// Exercises the libopus binding. These run wherever libopus is installed, which is the point of
/// resolving the library name at load time rather than hard-coding <c>opus.dll</c> — a P/Invoke
/// layer that can only be tested by shipping it to Windows is not tested.
/// </summary>
public class OpusEncoderTests
{
    private static byte[] SpeechWav(double seconds)
    {
        var pcm = new List<byte>();
        var phase = 0.0;
        for (var index = 0; index < (int)(seconds * 16_000); index++)
        {
            phase += 2 * Math.PI * 220 / 16_000;
            var sample = (short)(Math.Sin(phase) * 12_000);
            pcm.Add((byte)(sample & 0xFF));
            pcm.Add((byte)((sample >> 8) & 0xFF));
        }
        return AudioChunker.WrapInWavContainer(pcm.ToArray());
    }

    [Fact]
    public void EncodesToASubstantiallySmallerOggStream()
    {
        if (!OpusEncoder.IsAvailable)
        {
            return; // no libopus on this machine
        }

        var wav = SpeechWav(3);
        var ogg = OpusEncoder.Encode(wav);

        Assert.NotNull(ogg);
        Assert.Equal("OggS"u8.ToArray(), ogg![..4]);
        Assert.True(ogg.Length < wav.Length / 4, $"{ogg.Length} vs {wav.Length}");
    }

    /// <summary>Anything unencodable comes back as null so the caller sends the WAV. A compression
    /// optimisation must never be able to cost someone their words.</summary>
    [Fact]
    public void UnparseableInputFallsBackRatherThanThrowing()
    {
        Assert.Null(OpusEncoder.Encode("not a wav"u8.ToArray()));
    }
}

/// <summary>Fails loudly if libopus did not load, so the encoder tests above cannot pass by
/// silently skipping. A test that reports success because it did nothing is worse than no test.</summary>
public class OpusAvailabilityTests
{
    [Fact]
    public void LibopusIsLoadableWhereverItIsInstalled()
    {
        var installed =
            File.Exists("/opt/homebrew/lib/libopus.dylib")
            || File.Exists("/usr/local/lib/libopus.dylib")
            || File.Exists("/usr/lib/x86_64-linux-gnu/libopus.so.0");

        if (!installed)
        {
            return;
        }
        Assert.True(
            OpusEncoder.IsAvailable,
            "libopus is installed but the import resolver did not find it");
    }
}

/// <summary>Writes the encoder's output so it can be checked with a real decoder.</summary>
/// <remarks>
/// Structural assertions cannot catch a container that is well-formed but wrong. This dumps the
/// bytes to a temp file; <c>ffprobe</c> and <c>ffmpeg</c> are run against it from the shell as part
/// of verifying the port, exactly as the Swift version was.
/// </remarks>
public class OpusRoundTripTests
{
    [Fact]
    public void WriteEncodedSampleForExternalVerification()
    {
        if (!OpusEncoder.IsAvailable)
        {
            return;
        }

        var pcm = new List<byte>();
        var phase = 0.0;
        for (var index = 0; index < 48_000; index++)
        {
            phase += 2 * Math.PI * 220 / 16_000;
            var sample = (short)(Math.Sin(phase) * 12_000);
            pcm.Add((byte)(sample & 0xFF));
            pcm.Add((byte)((sample >> 8) & 0xFF));
        }

        var wav = AudioChunker.WrapInWavContainer(pcm.ToArray());
        var ogg = OpusEncoder.Encode(wav);

        Assert.NotNull(ogg);
        Assert.True(ogg!.Length < wav.Length / 4, $"{ogg.Length} vs {wav.Length}");

        var path = Environment.GetEnvironmentVariable("DNT_OPUS_DUMP");
        if (!string.IsNullOrEmpty(path))
        {
            File.WriteAllBytes(path, ogg);
        }
    }
}
