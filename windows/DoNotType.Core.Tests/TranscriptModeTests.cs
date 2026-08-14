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

    [Fact]
    public void AFileThatIsNotAudioAtAllIsRejected()
    {
        // Not WAV and not Ogg, so it goes to the system decoder — which either says it cannot play
        // it or, off Windows, says which platforms can.
        var path = WriteTemp("not audio at all"u8.ToArray());
        Assert.Throws<AudioDecoder.DecodeException>(() => AudioDecoder.Load(path));
        File.Delete(path);
    }

    /// <summary>
    /// The container is sniffed rather than taken from the extension. A `.wav` that is really an
    /// MP3 is a thing recorders do, and dispatching on the name would send it to the WAV reader.
    /// </summary>
    [Fact]
    public void TheContainerIsSniffedNotAssumedFromTheExtension()
    {
        var opus = FormatFixture("speech.opus");
        Assert.True(AudioDecoder.LooksLikeWav(File.ReadAllBytes(FormatFixture("speech.wav"))));
        Assert.False(AudioDecoder.LooksLikeWav(File.ReadAllBytes(opus)));
        Assert.True(OggOpusReader.IsOggOpus(File.ReadAllBytes(opus)));
        Assert.False(OggOpusReader.IsOggOpus(File.ReadAllBytes(FormatFixture("speech.mp3"))));
    }

    /// <summary>
    /// Which of the three routes a file takes.
    ///
    /// The Media Foundation route cannot run here, so what is asserted is that MP3 and M4A are
    /// *sent* to it — and that off Windows the refusal names the platforms that do decode them
    /// rather than failing somewhere downstream with a malformed-WAV error.
    /// </summary>
    [Theory]
    [InlineData("speech.mp3")]
    [InlineData("speech.m4a")]
    public void CompressedFormatsGoToTheSystemDecoder(string name)
    {
        var path = FormatFixture(name);
        Assert.False(AudioDecoder.LooksLikeWav(File.ReadAllBytes(path)));
        Assert.False(OggOpusReader.IsOggOpus(File.ReadAllBytes(path)));

        if (OperatingSystem.IsWindows())
        {
            // On Windows the route is Media Foundation and there is a real decode to check. This
            // is the only place that COM interop ever executes — the vtable layouts in
            // MediaFoundationDecoder cannot be validated by compiling, so an offset off by one
            // would otherwise ship and fail on a user's first MP3.
            AssertDecodesToSpeech(AudioDecoder.Load(path), name);
            return;
        }

        var error = Assert.Throws<AudioDecoder.DecodeException>(() => AudioDecoder.Load(path));
        Assert.Contains("Windows", error.Message);
        Assert.Contains("ffmpeg", error.Message);
    }

    /// <summary>
    /// The fixture is 1.5 seconds of speech. Both halves matter: a decoder that returns silence
    /// would pass a length check alone, and one that returns a single frame would pass an
    /// is-it-audible check alone.
    /// </summary>
    internal static void AssertDecodesToSpeech(byte[] wav, string name)
    {
        Assert.True(AudioDecoder.IsAlreadyTarget(wav), $"{name} should decode to 16 kHz mono");

        var body = AudioChunker.PcmBody(wav);
        Assert.NotNull(body);

        var seconds = body!.Length / (double)(AudioDecoder.SampleRate * 2);
        Assert.InRange(seconds, 1.25, 1.75);

        var peak = 0;
        for (var i = 0; i + 1 < body.Length; i += 2)
        {
            peak = Math.Max(peak, Math.Abs(BitConverter.ToInt16(body, i)));
        }
        Assert.True(peak > 8_000, $"{name} decoded to something inaudible (peak {peak})");
    }

    /// <summary>Shared with the other three platforms; see eval/audio/formats/README.md.</summary>
    internal static string FormatFixture(string name)
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        for (var i = 0; i < 10 && directory is not null; i++)
        {
            var candidate = Path.Combine(directory.FullName, "eval", "audio", "formats", name);
            if (File.Exists(candidate)) return candidate;
            directory = directory.Parent;
        }
        throw new FileNotFoundException($"fixture {name} not found from {AppContext.BaseDirectory}");
    }
}

/// <summary>
/// Ogg Opus, decoded through libopus.
/// </summary>
/// <remarks>
/// This is the one platform that has to demux and decode Opus itself, and — because the libopus
/// binding resolves the library by name at load time — it is also the one piece of the Windows
/// decoder that can be exercised on a developer machine. Which is the whole reason the binding was
/// written that way: a P/Invoke layer that can only be tested by shipping it is not tested.
/// </remarks>
public sealed class OggOpusReaderTests
{
    private static byte[] Fixture(string name) =>
        File.ReadAllBytes(AudioDecoderTests.FormatFixture(name));

    [Fact]
    public void RecognisesAnOggOpusStream()
    {
        Assert.True(OggOpusReader.IsOggOpus(Fixture("speech.opus")));
        Assert.False(OggOpusReader.IsOggOpus(Fixture("speech.wav")));
        Assert.False(OggOpusReader.IsOggOpus(Fixture("speech.m4a")));
    }

    [Fact]
    public void DecodesToSixteenKilohertzMono()
    {
        if (!OpusEncoder.IsAvailable) return; // no libopus on this machine

        // Opus declares a pre-skip and pads its last frame, so the length is a tolerance rather
        // than an equality — see AssertDecodesToSpeech.
        AudioDecoderTests.AssertDecodesToSpeech(
            OggOpusReader.DecodeToWav(Fixture("speech.opus"), "speech.opus"), "speech.opus");
    }

    /// <summary>
    /// The round trip that matters: this project encodes Opus for upload, so the reader has to
    /// read what the writer writes. Anything else means one of the two is wrong about the format.
    /// </summary>
    [Fact]
    public void ReadsWhatTheProjectsOwnEncoderWrites()
    {
        if (!OpusEncoder.IsAvailable) return; // no libopus on this machine

        var original = File.ReadAllBytes(AudioDecoderTests.FormatFixture("speech.wav"));
        var encoded = OpusEncoder.Encode(original);
        Assert.NotNull(encoded);

        var decoded = OggOpusReader.DecodeToWav(encoded!, "round-trip.opus");
        var before = AudioChunker.PcmBody(original)!.Length / (double)(AudioDecoder.SampleRate * 2);
        var after = AudioChunker.PcmBody(decoded)!.Length / (double)(AudioDecoder.SampleRate * 2);
        Assert.InRange(after, before - 0.2, before + 0.2);
    }
}
