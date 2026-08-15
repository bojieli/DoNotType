using System.Text.Json;
using DoNotType.Core;
using Xunit;

namespace DoNotType.Core.Tests;

/// <summary>
/// The screen context on a history row: what the inspector reads, and what a retry reuses.
/// </summary>
public sealed class ContextPersistenceTests
{
    private static ScreenContext Sample() => new()
    {
        AppName = "Mail",
        WindowTitle = "Re: the 4240 figure",
        BrowserUrl = "https://example.test/thread",
        Role = "AXTextArea",
        IsEditable = true,
        VisibleText = "the quarterly number is 4240",
        TextBeforeCaret = "as discussed, ",
        TextAfterCaret = " — please confirm",
        SelectedText = "4240",
    };

    /// <summary>A temporary history directory, written and re-read the way the app does.</summary>
    private static string TempDirectory()
    {
        var path = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString());
        Directory.CreateDirectory(path);
        return path;
    }

    /// <summary>
    /// Through the real store rather than a bare serializer: the store has its own converter
    /// options, and a test that supplies its own proves nothing about the file on disk.
    /// </summary>
    [Fact]
    public void EveryFieldSurvivesARoundTripThroughTheHistoryFile()
    {
        var directory = TempDirectory();
        new HistoryStore(directory).Insert(
            new DictationRecord { Text = "hello", Context = Sample() }, audio: null);

        var reloaded = new HistoryStore(directory).All().Single();

        Assert.NotNull(reloaded.Context);
        Assert.Equal("Mail", reloaded.Context!.AppName);
        Assert.Equal("Re: the 4240 figure", reloaded.Context.WindowTitle);
        Assert.Equal("https://example.test/thread", reloaded.Context.BrowserUrl);
        Assert.Equal("AXTextArea", reloaded.Context.Role);
        Assert.True(reloaded.Context.IsEditable);
        Assert.Equal("the quarterly number is 4240", reloaded.Context.VisibleText);
        Assert.Equal("as discussed, ", reloaded.Context.TextBeforeCaret);
        Assert.Equal(" — please confirm", reloaded.Context.TextAfterCaret);
        Assert.Equal("4240", reloaded.Context.SelectedText);
    }

    /// <summary>
    /// A row written before contexts were stored has to keep loading. The history file is the
    /// user's, not a cache, and a schema change that empties it is data loss.
    /// </summary>
    [Fact]
    public void ARowWrittenBeforeContextsExistedStillLoads()
    {
        var directory = TempDirectory();
        File.WriteAllText(
            Path.Combine(directory, "history.json"),
            """
            [{
              "Id": "9f1d3d2e-0000-4000-8000-000000000000",
              "Status": "Completed",
              "Text": "an older dictation",
              "Model": "gemini-3.6-flash",
              "Fidelity": "Light",
              "DurationSeconds": 3
            }]
            """);

        var records = new HistoryStore(directory).All();
        Assert.Single(records);
        Assert.Equal("an older dictation", records[0].Text);
        Assert.Null(records[0].Context);
    }

    /// <summary>
    /// What the inspector renders is what went over the wire, because it runs the same encoder the
    /// request did rather than describing it.
    /// </summary>
    [Fact]
    public void TheStoredContextEncodesToTheSamePartsTheRequestSent()
    {
        var context = Sample();
        var atRequestTime = new ContextEncoder().Encode(context);

        var reloaded = JsonSerializer.Deserialize<ScreenContext>(
            JsonSerializer.Serialize(context))!;
        var atInspectionTime = new ContextEncoder().Encode(reloaded);

        Assert.Equal(atRequestTime.Count, atInspectionTime.Count);
        Assert.Equal(
            atRequestTime.OfType<InputPart.Text>().Select(p => p.Value),
            atInspectionTime.OfType<InputPart.Text>().Select(p => p.Value));
    }

    /// <summary>
    /// A dictation that was never grounded stores nothing rather than an empty shell, so the
    /// inspector can tell "nothing was sent" from "something was sent and it was blank".
    /// </summary>
    [Fact]
    public void AnUngroundedDictationStoresNoContext()
    {
        var directory = TempDirectory();
        new HistoryStore(directory).Insert(new DictationRecord { Text = "hello" }, audio: null);
        Assert.Null(new HistoryStore(directory).All().Single().Context);
    }
}
