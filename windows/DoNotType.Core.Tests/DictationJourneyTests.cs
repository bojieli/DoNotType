using DoNotType.Core;
using Xunit;

namespace DoNotType.Core.Tests;

/// <summary>
/// The journey a user actually takes, offline. Port of
/// <c>Tests/DoNotTypeCoreTests/DictationJourneyTests.swift</c>.
///
/// <para>The pieces were tested and the sequence they form was not: what gets stored, what
/// survives a failure, whether Retry can still work afterwards. These assert decisions rather than
/// transcription quality — quality is what <c>dnt-eval</c> is for.</para>
///
/// <para><b>What is deliberately not covered here, and why.</b> On macOS the retry orchestration
/// lives in <c>RetryCoordinator</c> in the shared core, so it is testable. On Windows it lives in
/// <c>DictationController</c>, which is in the WinForms app target and cannot be referenced from a
/// net10.0 test project. The store-level guarantees Retry depends on — audio kept while retryable,
/// released on success — are asserted here.</para>
/// </summary>
public sealed class DictationJourneyTests : IDisposable
{
    private readonly string _directory;
    private readonly HistoryStore _store;

    public DictationJourneyTests()
    {
        _directory = Path.Combine(Path.GetTempPath(), $"dnt-journey-{Guid.NewGuid()}");
        _store = new HistoryStore(_directory);
        _store.Configure(RetentionPolicy.Forever, keepAudioForCompleted: false);
    }

    public void Dispose()
    {
        if (Directory.Exists(_directory)) Directory.Delete(_directory, recursive: true);
    }

    /// <summary>16 kHz mono PCM, the format every platform records.</summary>
    private static byte[] Wav(double seconds = 1)
    {
        const int rate = 16_000;
        var bytes = (int)(rate * 2 * seconds);
        using var stream = new MemoryStream();
        using var writer = new BinaryWriter(stream);
        writer.Write("RIFF"u8.ToArray());
        writer.Write(36 + bytes);
        writer.Write("WAVEfmt "u8.ToArray());
        writer.Write(16); writer.Write((short)1); writer.Write((short)1);
        writer.Write(rate); writer.Write(rate * 2);
        writer.Write((short)2); writer.Write((short)16);
        writer.Write("data"u8.ToArray());
        writer.Write(bytes);
        writer.Write(new byte[bytes]);
        writer.Flush();
        return stream.ToArray();
    }

    private static DictationRecord Record(DictationStatus status) => new()
    {
        Status = status,
        Model = "stub-model",
        Fidelity = Fidelity.Light,
    };

    // ---- The happy path ----------------------------------------------------------------------

    [Fact]
    public void ASuccessfulDictationIsStoredWithItsText()
    {
        var entry = Record(DictationStatus.Completed);
        entry.Text = "the transcript";

        var stored = _store.Insert(entry, null);

        Assert.Equal("the transcript", stored.Text);
        Assert.Single(_store.All());
        Assert.False(stored.CanRetry, "a completed dictation has nothing to retry");
    }

    // ---- Failure keeps the words recoverable -------------------------------------------------

    /// <summary>The promise Retry rests on: a failed dictation keeps its audio.</summary>
    [Fact]
    public void AFailedDictationKeepsItsAudioAndIsRetryable()
    {
        var entry = Record(DictationStatus.Failed);
        entry.ErrorMessage = "network";

        var stored = _store.Insert(entry, Wav());

        Assert.True(stored.CanRetry);
        Assert.NotNull(_store.AudioFor(stored));
        Assert.Single(_store.Retryable());
    }

    /// <summary>And the other half: a successful retry releases the recording it held.</summary>
    [Fact]
    public void ASuccessfulRetryReleasesTheAudio()
    {
        var entry = Record(DictationStatus.Failed);
        entry.ErrorMessage = "network";
        var stored = _store.Insert(entry, Wav());
        Assert.NotNull(_store.AudioFor(stored));

        stored.Status = DictationStatus.Completed;
        stored.Text = "recovered on the second attempt";
        stored.ErrorMessage = null;
        stored.RetryCount++;
        _store.Update(stored);

        var after = _store.All().Single(r => r.Id == stored.Id);
        Assert.Equal(DictationStatus.Completed, after.Status);
        Assert.Equal(1, after.RetryCount);
        Assert.Null(after.ErrorMessage);
        Assert.Null(after.AudioFileName);
        Assert.Empty(_store.Retryable());
    }

    /// <summary>Audio survives for anything retryable even with completed-audio retention off.</summary>
    [Fact]
    public void RetentionOffStillKeepsAudioForAnythingRetryable()
    {
        var failed = _store.Insert(Record(DictationStatus.Failed), Wav());
        var completed = _store.Insert(Record(DictationStatus.Completed), Wav());

        Assert.NotNull(_store.AudioFor(failed));
        Assert.Null(completed.AudioFileName);
    }

    // ---- The fallback is recorded honestly ---------------------------------------------------

    /// <summary>A hedged dictation must name the backend that answered, not the one asked.</summary>
    [Fact]
    public async Task AHedgedDictationRecordsTheBackendThatAnsweredIt()
    {
        var outcome = await new FallbackTranscriber(
            async token =>
            {
                await Task.Delay(5000, token);
                return new TranscriptionResult(new Transcript("primary"), new TokenUsage(), "p");
            },
            "primary", "primary-model",
            _ => Task.FromResult(
                new TranscriptionResult(
                    new Transcript("from the fallback"), new TokenUsage(), "f")),
            "fallback", "fallback-model",
            TimeSpan.FromMilliseconds(20)).TranscribeAsync();

        var entry = Record(DictationStatus.Completed);
        entry.Text = outcome.Result.Transcript.Text;
        entry.Model = outcome.Attribution.Model;
        var stored = _store.Insert(entry, null);

        Assert.Equal("from the fallback", stored.Text);
        Assert.Equal("fallback-model", stored.Model);
        Assert.True(outcome.Attribution.WasFallback);
    }

    // ---- Grounding reaches the request --------------------------------------------------------

    /// <summary>Screen text arrives as parts, audio last — docs/CONTEXT_FORMAT.md says order matters.</summary>
    [Fact]
    public void ScreenContextReachesTheProviderAheadOfTheAudio()
    {
        var context = new ScreenContext
        {
            AppName = "Chrome",
            VisibleText = string.Concat(Enumerable.Repeat("Brindlewood and quillmark-sync. ", 20)),
        };

        var parts = new List<InputPart>(new ContextEncoder().Encode(context))
        {
            new InputPart.Audio(Wav(), "audio/wav"),
        };

        Assert.IsType<InputPart.Audio>(parts[^1]);
        var text = string.Join(" ", parts.OfType<InputPart.Text>().Select(p => p.Value));
        Assert.Contains("Brindlewood", text);
        Assert.Contains("DO NOT TRANSCRIBE", text);
    }
}
