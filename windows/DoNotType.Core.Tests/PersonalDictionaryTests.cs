using System.Text;
using DoNotType.Core;
using Xunit;

namespace DoNotType.Core.Tests;

public sealed class PersonalDictionaryTests
{
    private sealed class RecordingProvider(GroundingSupport grounding) : ITranscriptionProvider
    {
        public string Name => "recording";
        public string Model => "model";
        public GroundingSupport Grounding => grounding;
        public IReadOnlyList<InputPart> Parts { get; private set; } = [];
        public IReadOnlyList<string> Keyterms { get; private set; } = [];

        public Task<TranscriptionResult> TranscribeAsync(
            string systemInstruction, IReadOnlyList<InputPart> parts, int maxOutputTokens = 2048,
            CancellationToken cancellationToken = default, Fidelity fidelity = Fidelity.Light,
            IReadOnlyList<string>? keyterms = null,
            ConnectionPreference connection = ConnectionPreference.Pooled)
        {
            Parts = parts;
            Keyterms = keyterms ?? [];
            return Task.FromResult(new TranscriptionResult(
                new Transcript("ok"), new TokenUsage(), "ok"));
        }
    }

    [Fact]
    public void EntriesAreNormalizedAndDeduplicated()
    {
        var terms = PersonalDictionary.Add("  quillmark-sync  ", []);
        terms = PersonalDictionary.Add("Kaelith   Rowan", terms);
        Assert.Equal(["quillmark-sync", "Kaelith Rowan"], terms);
        Assert.Throws<PersonalDictionary.ValidationException>(
            () => PersonalDictionary.Add("QUILLMARK-SYNC", terms));
    }

    [Fact]
    public void CsvSupportsQuotesBomAndPlainLines()
    {
        var terms = PersonalDictionary.EntriesFromCsv(
            Encoding.UTF8.GetBytes("\uFEFFKaelith\r\n\"O\"\"Brien\"\r\n\"Smith, Jones\"\r\nkaelith\r\n"));
        Assert.Equal(["Kaelith", "O\"Brien", "Smith, Jones"], terms);
        Assert.Throws<PersonalDictionary.ValidationException>(
            () => PersonalDictionary.EntriesFromCsv(Encoding.UTF8.GetBytes("one,two\n")));
    }

    [Fact]
    public void ModelReferenceIsDelimitedAndJsonEncoded()
    {
        var block = PersonalDictionary.ReferenceBlock(["Kaelith", "A \"quoted\" name", "GPT-5"]);
        Assert.Contains("SPELLING REFERENCE ONLY, DO NOT TRANSCRIBE", block);
        Assert.Contains("[\"Kaelith\",\"A \\u0022quoted\\u0022 name\",\"GPT-5\"]", block);
        Assert.Null(PersonalDictionary.ReferenceBlock([]));
    }

    [Fact]
    public void KeytermsExcludeNumbersAndPutUserEntriesFirst()
    {
        Assert.Equal(["Kaelith", "quillmark-sync"],
            PersonalDictionary.Keyterms(["Kaelith", "GPT-5", "quillmark-sync"], 100, 50));
        Assert.Equal(["Kaelith", "SwiftUI", "ScreenDecoy"],
            PersonalDictionary.MergeKeyterms(
                ["Kaelith", "SwiftUI"], ["ScreenDecoy", "KAELITH", "Other"], 3, 50));
    }

    [Fact]
    public void LearningKeepsSpellingFixesAndRejectsOrdinaryEditing()
    {
        Assert.Equal(["Kaelith", "SwiftUI"], PersonalDictionary.LearnedCandidates(
            "Ask Keyleth about swift UI tomorrow.", "Ask Kaelith about SwiftUI on Friday."));
        Assert.Empty(PersonalDictionary.LearnedCandidates(
            "Use Gemini 3.5 and send the draft", "Please use Gemini 3 and email the final draft"));
        Assert.Equal(["SwiftUI"], PersonalDictionary.LearnedCandidates(
            "The swiftui view", "The SwiftUI view"));
    }

    [Fact]
    public async Task ServiceRoutesDictionaryThroughEachProvidersSupportedChannel()
    {
        var model = new RecordingProvider(GroundingSupport.Multimodal);
        await new TranscriptionService(model, "instruction")
        {
            PersonalDictionary = ["Kaelith", "GPT-5"],
            HedgeStalledRequests = false,
        }.TranscribeAsync(Wav(), null);
        Assert.Contains(model.Parts.OfType<InputPart.Text>(),
            part => part.Value.Contains("PERSONAL DICTIONARY") && part.Value.Contains("GPT-5"));
        Assert.IsType<InputPart.Audio>(model.Parts[^1]);

        var recognizer = new RecordingProvider(GroundingSupport.Keyterms(2, 50));
        await new TranscriptionService(recognizer, "instruction")
        {
            PersonalDictionary = ["Kaelith", "GPT-5", "SwiftUI"],
            HedgeStalledRequests = false,
        }.TranscribeAsync(Wav(), null);
        Assert.Equal(["Kaelith", "SwiftUI"], recognizer.Keyterms);
        Assert.Single(recognizer.Parts);
        Assert.IsType<InputPart.Audio>(recognizer.Parts[0]);
    }

    private static byte[] Wav()
    {
        const int samples = 16_000;
        using var stream = new MemoryStream();
        using var writer = new BinaryWriter(stream);
        writer.Write("RIFF"u8.ToArray()); writer.Write(36 + samples * 2);
        writer.Write("WAVEfmt "u8.ToArray()); writer.Write(16); writer.Write((short)1);
        writer.Write((short)1); writer.Write(samples); writer.Write(samples * 2);
        writer.Write((short)2); writer.Write((short)16);
        writer.Write("data"u8.ToArray()); writer.Write(samples * 2);
        writer.Write(new byte[samples * 2]); writer.Flush();
        return stream.ToArray();
    }
}
