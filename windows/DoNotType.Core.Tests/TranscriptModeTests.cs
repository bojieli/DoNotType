using System.Text.Json;
using DoNotType.Core;
using Xunit;

namespace DoNotType.Core.Tests;

/// <summary>Modes, the wall between rewriting and summarising, and the WAV decoder.</summary>
public sealed class TranscriptModeTests
{
    private static PromptBuilder Prompt() =>
        PromptBuilder.FromFile(
            PromptBuilder.FindPromptFile()
            ?? throw new InvalidOperationException("PROMPT.md not found from the test run"));

    [Fact]
    public void EveryOfferedSpellingParsesAndRoundTrips()
    {
        foreach (var spelling in TranscriptMode.AcceptedSpellings)
        {
            var parsed = TranscriptMode.Parse(spelling);
            Assert.NotNull(parsed);
            Assert.Equal(spelling, parsed!.Id);
        }
    }

    [Fact]
    public void BareStageNamesTakeTheirDefault()
    {
        Assert.Equal("summary:brief", TranscriptMode.Parse("summary")!.Id);
        Assert.Equal("rewrite:formal", TranscriptMode.Parse("rewrite")!.Id);
        Assert.Equal("summary:brief", TranscriptMode.Parse("summarize")!.Id);
    }

    [Theory]
    [InlineData("summary:novel")]
    [InlineData("rewrite:shakespeare")]
    [InlineData("translate")]
    // Verbatim is not a rewrite style, so asking for it as one is a mistake worth catching.
    [InlineData("rewrite:verbatim")]
    public void UnknownStylesAreRejectedRatherThanSilentlyDowngraded(string spelling) =>
        Assert.Null(TranscriptMode.Parse(spelling));

    [Fact]
    public void OnlyVerbatimAvoidsASecondRequest()
    {
        Assert.False(TranscriptMode.Verbatim.NeedsSecondPass);
        Assert.True(TranscriptMode.Rewrite(RewriteStyle.Formal).NeedsSecondPass);
        Assert.True(TranscriptMode.Summary(SummaryStyle.Actions).NeedsSecondPass);
    }

    /// <summary>
    /// A summary is not a rewrite style, and a history row must not claim it is — that column means
    /// something different for the two.
    /// </summary>
    [Fact]
    public void ASummaryHasNoRewriteStyle()
    {
        Assert.Null(TranscriptMode.Summary(SummaryStyle.Bullets).RewriteStyleOrNull);
        Assert.Equal(
            RewriteStyle.Concise, TranscriptMode.Rewrite(RewriteStyle.Concise).RewriteStyleOrNull);
    }

    // ---- The prompt blocks ---------------------------------------------------------------------

    [Fact]
    public void SummaryInstructionResolvesForEveryStyle()
    {
        foreach (var style in Enum.GetValues<SummaryStyle>())
        {
            var instruction = Prompt().SecondStageInstruction(TranscriptMode.Summary(style));
            Assert.NotNull(instruction);
            Assert.DoesNotContain("{{SUMMARY_RULE}}", instruction);
            Assert.DoesNotContain("<!--", instruction);
            Assert.Contains("summar", instruction);
        }
    }

    [Fact]
    public void SummaryAndRewriteAreDifferentInstructions()
    {
        var summary = Prompt().SecondStageInstruction(TranscriptMode.Summary(SummaryStyle.Brief))!;
        var rewrite = Prompt().SecondStageInstruction(TranscriptMode.Rewrite(RewriteStyle.Concise))!;
        Assert.NotEqual(summary, rewrite);

        // The rewrite block's first rule is the one this project exists to enforce; the summary
        // block must not carry it, because a summary that removes nothing has not summarised.
        Assert.Contains("Never remove", rewrite);
        Assert.DoesNotContain("Never remove", summary);
        // Both keep the numbers rule, which is the failure grounding actually produces.
        Assert.Contains("unchanged", summary);
        Assert.Contains("unchanged", rewrite);
    }

    [Fact]
    public void VerbatimAsksForNoSecondStage() =>
        Assert.Null(Prompt().SecondStageInstruction(TranscriptMode.Verbatim));

    /// <summary>
    /// A prompt edited before summaries existed is still a valid prompt for dictation. It must fail
    /// on summaries with a message that says what to do, not with a generic parse error.
    /// </summary>
    [Fact]
    public void APromptWithoutASummaryBlockFailsHelpfully()
    {
        var template = File.ReadAllText(PromptBuilder.FindPromptFile()!);
        var builder = new PromptBuilder(template.Replace("<!-- BEGIN SUMMARY -->", string.Empty));

        builder.SystemInstruction(Fidelity.Light); // dictation still works
        Assert.False(builder.SupportsSecondStage(TranscriptMode.Summary(SummaryStyle.Brief)));

        var error = Assert.Throws<InvalidOperationException>(
            () => builder.SecondStageInstruction(TranscriptMode.Summary(SummaryStyle.Brief)));
        Assert.Contains("restore the shipped prompt", error.Message);
    }

    // ---- History -------------------------------------------------------------------------------

    [Fact]
    public void ARecordSurvivesAJsonRoundTripWithTheNewFields()
    {
        var record = new DictationRecord
        {
            Status = DictationStatus.Completed,
            Text = "what was said",
            StyledText = "the gist",
            Mode = "summary:bullets",
            SourceFileName = "meeting.m4a",
        };

        var json = JsonSerializer.Serialize(record);
        var decoded = JsonSerializer.Deserialize<DictationRecord>(json)!;

        Assert.Equal("summary:bullets", decoded.Mode);
        Assert.Equal("meeting.m4a", decoded.SourceFileName);
        Assert.Equal("the gist", decoded.DeliveredText);
        Assert.True(decoded.IsFromFile);
        Assert.Equal("summary:bullets", decoded.ResolvedMode.Id);
    }

    /// <summary>
    /// History written before this change has no `Mode` key at all. Decoding it must not fail —
    /// that would empty someone's history on upgrade.
    /// </summary>
    [Fact]
    public void HistoryFromBeforeModesExistedStillDecodes()
    {
        const string json = """
            {"Id":"11111111-1111-1111-1111-111111111111","Status":0,
             "Text":"an older dictation","Model":"gemini-3.6-flash","DurationSeconds":3}
            """;
        var decoded = JsonSerializer.Deserialize<DictationRecord>(json)!;

        Assert.Null(decoded.Mode);
        Assert.Equal("verbatim", decoded.ResolvedMode.Id);
        Assert.Equal("an older dictation", decoded.DeliveredText);
        Assert.False(decoded.IsFromFile);
    }
}

/// <summary>The decoder that lets a recording made by something else reach the pipeline.</summary>
public sealed class AudioDecoderTests
{
    private static byte[] Wav(int rate, int channels, int bits, int seconds, bool isFloat = false)
    {
        var bytesPerSample = bits / 8;
        var body = new byte[rate * channels * bytesPerSample * seconds];
        var header = new List<byte>();
        header.AddRange("RIFF"u8.ToArray());
        header.AddRange(BitConverter.GetBytes(36 + body.Length));
        header.AddRange("WAVE"u8.ToArray());
        header.AddRange("fmt "u8.ToArray());
        header.AddRange(BitConverter.GetBytes(16));
        header.AddRange(BitConverter.GetBytes((ushort)(isFloat ? 3 : 1)));
        header.AddRange(BitConverter.GetBytes((ushort)channels));
        header.AddRange(BitConverter.GetBytes(rate));
        header.AddRange(BitConverter.GetBytes(rate * channels * bytesPerSample));
        header.AddRange(BitConverter.GetBytes((ushort)(channels * bytesPerSample)));
        header.AddRange(BitConverter.GetBytes((ushort)bits));
        header.AddRange("data"u8.ToArray());
        header.AddRange(BitConverter.GetBytes(body.Length));
        return [.. header, .. body];
    }

    private static string WriteTemp(byte[] bytes, string extension = ".wav")
    {
        var path = Path.Combine(Path.GetTempPath(), Guid.NewGuid() + extension);
        File.WriteAllBytes(path, bytes);
        return path;
    }

    [Fact]
    public void AlreadyTargetFormatIsPassedThroughByteForByte()
    {
        var wav = Wav(16_000, 1, 16, 1);
        var path = WriteTemp(wav);

        Assert.True(AudioDecoder.IsAlreadyTarget(wav));
        // A re-encode here would be a lossy round trip that changes nothing.
        Assert.Equal(wav, AudioDecoder.Load(path));

        File.Delete(path);
    }

    /// <summary>
    /// The case that matters: a recording made by something other than this app. 44.1 kHz stereo is
    /// what every other tool produces, and everything downstream assumes 16 kHz mono.
    /// </summary>
    [Fact]
    public void Stereo44kIsConvertedToTheFormatTheChunkerNeeds()
    {
        var path = WriteTemp(Wav(44_100, 2, 16, 2));
        var decoded = AudioDecoder.Load(path);

        Assert.True(AudioDecoder.IsAlreadyTarget(decoded));
        var body = AudioChunker.PcmBody(decoded);
        Assert.NotNull(body);
        // The length has to survive the conversion, or every history row is wrong.
        Assert.Equal(2.0, body!.Length / (double)(AudioDecoder.SampleRate * 2), precision: 1);

        File.Delete(path);
    }

    [Theory]
    [InlineData(8, false)]
    [InlineData(24, false)]
    [InlineData(32, false)]
    [InlineData(32, true)]
    public void EveryCommonSampleWidthIsReadable(int bits, bool isFloat)
    {
        var path = WriteTemp(Wav(48_000, 1, bits, 1, isFloat));
        var decoded = AudioDecoder.Load(path);

        Assert.True(AudioDecoder.IsAlreadyTarget(decoded));
        File.Delete(path);
    }

    /// <summary>
    /// The platform difference, asserted rather than left as a comment: .NET has no built-in
    /// decoder for compressed audio, so the message has to say what to do instead.
    /// </summary>
    [Fact]
    public void CompressedFormatsSayWhatToDoInstead()
    {
        var path = WriteTemp([1, 2, 3], ".m4a");
        var error = Assert.Throws<AudioDecoder.DecodeException>(() => AudioDecoder.Load(path));

        Assert.Contains("WAV only", error.Message);
        Assert.Contains("ffmpeg", error.Message);
        File.Delete(path);
    }

    [Fact]
    public void AFileThatIsNotAWavAtAllIsRejected()
    {
        var path = WriteTemp("not audio at all"u8.ToArray());
        Assert.Throws<AudioDecoder.DecodeException>(() => AudioDecoder.Load(path));
        File.Delete(path);
    }
}
