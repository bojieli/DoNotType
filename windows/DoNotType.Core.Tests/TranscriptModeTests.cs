using System.Text.Json;
using DoNotType.Core;
using Xunit;

namespace DoNotType.Core.Tests;

/// <summary>Modes, the wall between rewriting and summarising, and the WAV decoder.</summary>
public sealed class TranscriptModeTests
{
    private static PromptBuilder Prompt() =>
        new(PromptBuilder.FindPromptDirectory()
            ?? throw new InvalidOperationException("prompt/ not found from the test run"));

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
        Assert.Equal("rewrite:casual", TranscriptMode.Parse("rewrite")!.Id);
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
    public void DefaultRewriteRemovesFillersAndRequestsConciseProse()
    {
        var rewrite = Prompt().SecondStageInstruction(TranscriptMode.Rewrite(RewriteStyle.Formal))!;
        foreach (var phrase in new[]
                 {
                     "vocal fillers", "\"um\"", "\"ah\"", "\"actually\"", "\"basically\"",
                     "false starts",
                     "repetition", "self-corrections", "final wording", "superseded wording",
                     "clear, concise, professional prose",
                 })
            Assert.Contains(phrase, rewrite);
    }

    [Fact]
    public void VerbatimAsksForNoSecondStage() =>
        Assert.Null(Prompt().SecondStageInstruction(TranscriptMode.Verbatim));

    /// <summary>
    /// A user who edited the contract before summaries existed used to break the summary stage
    /// outright: their override was the whole file, so it had no summary block and nothing could
    /// fall back. Per-part overrides make that unreachable -- an edited system.md says nothing
    /// about summary.md, which is still the shipped one.
    /// </summary>
    [Fact]
    public void EditingOnePartCannotBreakAStageItSaysNothingAbout()
    {
        if (PromptBuilder.FindPromptDirectory() is not { } bundled) return;

        var directory = Path.Combine(Path.GetTempPath(), "dnt-mode-" + Guid.NewGuid().ToString("N"));
        try
        {
            var store = new PromptStore(directory);
            store.Save("MY ENGINE. {{FIDELITY_RULE}}", PromptPart.System);
            var builder = store.Builder(bundled);

            Assert.StartsWith("MY ENGINE.", builder.SystemInstruction(Fidelity.Light));
            foreach (var mode in TranscriptMode.All.Where(m => m.NeedsSecondPass))
            {
                Assert.True(builder.SupportsSecondStage(mode));
            }
        }
        finally
        {
            if (Directory.Exists(directory)) Directory.Delete(directory, recursive: true);
        }
    }

    /// <summary>
    /// PromptStore.Validate gates saving an edited part, and each part is judged on its own terms
    /// -- a clause has no placeholder to require.
    /// </summary>
    [Fact]
    public void ValidationJudgesEachPartOnItsOwnTerms()
    {
        PromptStore.Validate("Fidelity is MINE.", PromptPart.Of(Fidelity.Light));
        PromptStore.Validate("Summarise. {{SUMMARY_RULE}}", PromptPart.Summary);
        Assert.Throws<InvalidOperationException>(
            () => PromptStore.Validate("Summarise.", PromptPart.Summary));
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
            // On Windows the route is Media Foundation and there is a real decode to check. This is
            // the only place that COM interop ever executes — the vtable layouts in
            // MediaFoundationDecoder cannot be validated by compiling, so an offset off by one
            // would otherwise ship and fail on a user's first MP3. One did.
            //
            // The source format goes into the message because this path runs on one machine in the
            // world, and when the length comes out wrong that is the first thing anyone needs.
            var (wav, format) = MediaFoundationDecoder.DecodeWithFormat(path, name);
            AssertDecodesToSpeech(
                wav,
                $"{name} (decoder gave {format.SampleRate} Hz, {format.Channels} ch, "
                    + $"{format.BitsPerSample}-bit, float={format.IsFloat})");
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
        // Assert.InRange takes no message, and on a path that runs only on a CI runner the message
        // is the entire diagnosis.
        Assert.True(
            seconds is >= 1.25 and <= 1.75,
            $"{name}: expected about 1.5 s, got {seconds:F2} s");

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

/// <summary>
/// What the Ogg reader does with input that is not a well-formed file.
/// </summary>
/// <remarks>
/// A demuxer is a parser fed bytes from outside the program, and the failures that matter are not
/// "does it decode" but "does it terminate, and does it fail in a way the caller can catch". A
/// partial download, a copy interrupted halfway, a file someone renamed — all reach this code.
/// </remarks>
public sealed class OggOpusReaderRobustnessTests
{
    private static byte[] Fixture(string name) =>
        File.ReadAllBytes(AudioDecoderTests.FormatFixture(name));

    /// <summary>
    /// Truncated at every length, including inside a page header and inside a lacing table.
    ///
    /// Every one must terminate and must fail as a DecodeException rather than an
    /// IndexOutOfRange, a hang, or — worst — silently returning a fraction of the audio as though
    /// it were the whole file.
    /// </summary>
    [Fact]
    public void TruncationNeverHangsAndNeverThrowsSomethingUncatchable()
    {
        var whole = Fixture("speech.opus");

        // Every 97 bytes: dense enough to land inside headers, lacing tables and packet bodies,
        // cheap enough to run on every push.
        for (var length = 1; length < whole.Length; length += 97)
        {
            var cut = whole[..length];
            var deadline = DateTimeOffset.Now.AddSeconds(5);

            try
            {
                OggOpusReader.IsOggOpus(cut);
                var stream = OggOpusReader.Demux(cut, "fuzz");
                // If it parsed, what it returns has to be self-consistent.
                Assert.All(stream.Packets, packet => Assert.NotEmpty(packet));
                Assert.True(stream.PreSkip >= 0);
                Assert.True(stream.Channels is >= 1 and <= 8);
            }
            catch (AudioDecoder.DecodeException)
            {
                // The documented failure.
            }

            Assert.True(
                DateTimeOffset.Now < deadline,
                $"demuxing {length} bytes took more than five seconds — a page whose length does "
                + "not advance the cursor would do that");
        }
    }

    /// <summary>
    /// A page header claiming more segments than the file contains, which is what a corrupt byte
    /// in the segment count looks like.
    /// </summary>
    [Fact]
    public void ALyingSegmentCountIsSurvived()
    {
        var whole = Fixture("speech.opus");
        for (var count = 1; count <= 255; count += 37)
        {
            var corrupt = whole.ToArray();
            corrupt[26] = (byte)count; // segment count of the first page
            try
            {
                OggOpusReader.Demux(corrupt, "fuzz");
            }
            catch (AudioDecoder.DecodeException)
            {
            }
        }
    }

    /// <summary>Random bytes that happen to start with the capture pattern.</summary>
    [Fact]
    public void GarbageBehindAValidMagicIsSurvived()
    {
        var random = new Random(20260815); // fixed, so a failure is reproducible
        for (var trial = 0; trial < 200; trial++)
        {
            var noise = new byte[random.Next(28, 4_096)];
            random.NextBytes(noise);
            "OggS"u8.CopyTo(noise);

            try
            {
                OggOpusReader.IsOggOpus(noise);
                OggOpusReader.Demux(noise, "fuzz");
            }
            catch (AudioDecoder.DecodeException)
            {
            }
        }
    }

    /// <summary>
    /// A page with no segments at all is legal Ogg, and is the shape that would make a reader
    /// whose cursor does not advance spin forever.
    /// </summary>
    [Fact]
    public void AnEmptyPageDoesNotStallTheReader()
    {
        var page = new byte[27];
        "OggS"u8.CopyTo(page);
        page[26] = 0; // no segments

        var doubled = page.Concat(page).ToArray();
        var deadline = DateTimeOffset.Now.AddSeconds(5);
        try
        {
            OggOpusReader.Demux(doubled, "fuzz");
        }
        catch (AudioDecoder.DecodeException)
        {
        }
        Assert.True(DateTimeOffset.Now < deadline, "an empty page stalled the reader");
    }
}

/// <summary>
/// The `--mode` parity table, duplicated verbatim in every language's test suite.
///
/// Four implementations of one grammar, and the failure mode is not a crash: it is a phone and a
/// laptop disagreeing about what `summary` means, which nobody would think to look for. The table
/// is duplicated in each language on purpose — a shared fixture file would be read by whichever
/// platform remembered to read it.
/// </summary>
public sealed class TranscriptModeParityTests
{
    [Theory]
    [InlineData("verbatim", "verbatim")]
    [InlineData("raw", "verbatim")]
    [InlineData("transcribe", "verbatim")]
    [InlineData("none", "verbatim")]
    [InlineData("rewrite", "rewrite:casual")]
    [InlineData("rewrite:formal", "rewrite:formal")]
    [InlineData("rewrite:concise", "rewrite:concise")]
    [InlineData("rewrite:casual", "rewrite:casual")]
    // The fourth style has no shipped clause — its text is the user's — but it is a style like any
    // other as far as the grammar is concerned.
    [InlineData("rewrite:custom", "rewrite:custom")]
    [InlineData("rewrite:", "rewrite:casual")]
    [InlineData("rewrite:verbatim", null)]
    [InlineData("summary", "summary:brief")]
    [InlineData("summary:", "summary:brief")]
    [InlineData("summary:brief", "summary:brief")]
    [InlineData("summary:bullets", "summary:bullets")]
    [InlineData("summary:actions", "summary:actions")]
    [InlineData("summarise", "summary:brief")]
    [InlineData("summarize", "summary:brief")]
    [InlineData("SUMMARY:Bullets", "summary:bullets")]
    [InlineData("  summary  ", "summary:brief")]
    [InlineData("", null)]
    [InlineData("nonsense", null)]
    [InlineData("rewrite:nonsense", null)]
    [InlineData("summary:nonsense", null)]
    // A language is free text, so there is no wrong one to reject — only a missing one. The case
    // is preserved because a language is a name, and the value survives the lowercasing that every
    // other tail goes through.
    [InlineData("translate:English", "translate:English")]
    [InlineData("translate:简体中文", "translate:简体中文")]
    [InlineData("translate:Brazilian Portuguese", "translate:Brazilian Portuguese")]
    [InlineData("  translate:English  ", "translate:English")]
    [InlineData("TRANSLATE:English", "translate:English")]
    [InlineData("translate", null)]
    [InlineData("translate:", null)]
    [InlineData("translate:   ", null)]
    public void TheModeGrammarIsIdenticalOnEveryPlatform(string typed, string? expected)
    {
        Assert.Equal(expected, TranscriptMode.Parse(typed)?.Id);
    }

    /// <summary>
    /// The word shown while the second request is in flight, which is the one thing on screen
    /// during the slowest part of a two-request mode. Four interfaces read it, so it is in the
    /// table with everything else that must not drift.
    /// </summary>
    [Theory]
    [InlineData("verbatim", "Finishing…")]
    [InlineData("rewrite:formal", "Rewriting…")]
    [InlineData("rewrite:concise", "Tightening…")]
    [InlineData("rewrite:casual", "Loosening…")]
    [InlineData("rewrite:custom", "Rewriting…")]
    [InlineData("summary:brief", "Summarising…")]
    [InlineData("summary:bullets", "Summarising into bullets…")]
    [InlineData("summary:actions", "Picking out the actions…")]
    [InlineData("translate:English", "Translating…")]
    public void TheProgressLabelIsIdenticalOnEveryPlatform(string typed, string expected)
    {
        Assert.Equal(expected, TranscriptMode.Parse(typed)!.ProgressLabel);
    }
}

/// <summary>Where a batch of transcripts lands.</summary>
public sealed class OutputNamingTests
{
    [Fact]
    public void TheOrdinaryCaseIsTheObviousName()
    {
        Assert.Equal(["meeting.txt"], FileTranscriber.OutputNames(["/tmp/meeting.wav"]));
        Assert.Equal(
            ["a.txt", "b.txt"], FileTranscriber.OutputNames(["/tmp/a.wav", "/tmp/b.mp3"]));
    }

    /// <summary>
    /// The bug. Both wanted `speech.txt`, the second overwrote the first, and "wrote speech.txt"
    /// printed twice as though both had landed.
    /// </summary>
    [Fact]
    public void TheSameNameInTwoFormatsDoesNotOverwrite()
    {
        var names = FileTranscriber.OutputNames(["/a/speech.wav", "/b/speech.mp3"]);
        Assert.Equal(["speech.txt", "speech.mp3.txt"], names);
    }

    [Fact]
    public void TheSameNameInTwoDirectoriesIsNumbered()
    {
        var names = FileTranscriber.OutputNames(
            ["/monday/notes.wav", "/tuesday/notes.wav", "/wednesday/notes.wav"]);
        Assert.Equal(["notes.txt", "notes.wav.txt", "notes-2.txt"], names);
    }

    [Fact]
    public void NamesAreUniqueForAnyBatch()
    {
        var paths = Enumerable.Range(0, 50)
            .Select(i => $"/dir{i % 3}/take{i % 5}.{(i % 2 == 0 ? "wav" : "mp3")}")
            .ToList();
        Assert.Equal(50, FileTranscriber.OutputNames(paths).Distinct().Count());
    }

    /// <summary>
    /// Windows file names are case-insensitive, so `Notes.wav` and `notes.wav` collide there even
    /// though they would not on the platform this test usually runs on.
    /// </summary>
    [Fact]
    public void CaseAloneIsNotEnoughToTellTwoNamesApart()
    {
        var names = FileTranscriber.OutputNames(["/a/Notes.wav", "/b/notes.wav"]);
        Assert.Equal(2, names.Distinct(StringComparer.OrdinalIgnoreCase).Count());
    }
}

/// <summary>
/// What someone is told when the file is not a recording.
/// </summary>
/// <remarks>
/// docs/MANUAL-CHECKS.md names the standard: the message should say what is wrong, rather than
/// describing the symptom. A folder and a zero-byte file both reached the decoder and came back as
/// an unexplained failure from whichever library got to them first.
/// </remarks>
public sealed class DecodeFailureMessageTests : IDisposable
{
    private readonly string _directory =
        Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString());

    public DecodeFailureMessageTests() => Directory.CreateDirectory(_directory);

    public void Dispose() => Directory.Delete(_directory, recursive: true);

    private string Message(string path)
    {
        try
        {
            AudioDecoder.Load(path);
            return "(it loaded)";
        }
        catch (Exception error)
        {
            return error.Message;
        }
    }

    [Fact]
    public void AFolderSaysItIsAFolder() => Assert.Contains("folder", Message(_directory));

    [Fact]
    public void AnEmptyFileSaysItIsEmpty()
    {
        var path = Path.Combine(_directory, "cut-short.wav");
        File.WriteAllBytes(path, []);
        Assert.Contains("empty", Message(path));
    }

    [Fact]
    public void AMissingFileSaysSo() =>
        Assert.Contains("No such file", Message(Path.Combine(_directory, "nope.wav")));

    /// <summary>
    /// Not WAV and not Opus, so this is the route to the system decoder — which does not exist off
    /// Windows, and the message has to say that rather than blaming the file.
    /// </summary>
    [Fact]
    public void SomethingThatIsNotAudioSaysSo()
    {
        var path = Path.Combine(_directory, "notes.wav");
        File.WriteAllText(path, "This is not a recording, it is a paragraph about one.");

        var message = Message(path);
        Assert.False(message == "(it loaded)", "a text file decoded as audio");
        Assert.Contains("notes.wav", message);
    }
}

/// <summary>
/// The target-language field, whose rules are repeated in
/// <c>Tests/DoNotTypeCoreTests/TranscriptModeTests.swift</c> and
/// <c>android/app/src/test/kotlin/app/donottype/core/TranslationTargetTest.kt</c>.
/// </summary>
public sealed class TranslationTargetTests
{
    [Theory]
    [InlineData("English", "English")]
    [InlineData("  English  ", "English")]
    [InlineData("Traditional  Chinese", "Traditional Chinese")]
    [InlineData("Brazilian\nPortuguese", "Brazilian Portuguese")]
    [InlineData("a\tb", "a b")]
    [InlineData("", "")]
    [InlineData("   ", "")]
    public void TheSanitiserIsIdenticalOnEveryPlatform(string typed, string expected)
    {
        Assert.Equal(expected, TranslationTarget.Sanitized(typed));
    }

    [Fact]
    public void TheSanitiserCapsALongName()
    {
        Assert.Equal(
            TranslationTarget.MaxCharacters,
            TranslationTarget.Sanitized(new string('x', 200)).Length);
    }

    /// <summary>
    /// Empty is off rather than invalid, which is the difference between a field you can clear and
    /// one that shouts at you for clearing it.
    /// </summary>
    [Fact]
    public void AnEmptyFieldIsNotAnError()
    {
        Assert.Null(TranslationTarget.ValidationMessage(string.Empty));
        Assert.Null(TranslationTarget.ValidationMessage("   "));
        Assert.Null(TranslationTarget.ValidationMessage(null));
        Assert.Null(TranslationTarget.ValidationMessage("简体中文"));
        Assert.Equal(
            "A language name is at most 60 characters.",
            TranslationTarget.ValidationMessage(new string('x', 200)));
    }

    /// <summary>
    /// Not a whitelist, and the suite says so: a language that is not in the list must still be
    /// accepted, because the model is the authority on what it can write.
    /// </summary>
    [Fact]
    public void TheSuggestionsAreNotAWhitelist()
    {
        Assert.Null(TranslationTarget.ValidationMessage("Klingon"));
        Assert.Equal("translate:Klingon", TranscriptMode.Parse("translate:Klingon")!.Id);
        Assert.Contains("English", TranslationTarget.Suggestions);
    }
}
