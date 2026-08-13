using DoNotType.Core;
using Xunit;

namespace DoNotType.Core.Tests;

/// <summary>
/// The C# port of <c>Keyterms</c> has to agree with the Swift and Kotlin ones.
///
/// These are the same cases as <c>Tests/DoNotTypeCoreTests/KeytermsTests.swift</c>, deliberately.
/// A biasing list that differs by platform means the Windows app is grounded differently from the
/// one the evaluation measured, and nothing else in the project would notice.
/// </summary>
public class KeytermsTests
{
    /// <summary>
    /// The whole reason this project exists. A keyterm list has no "reference only" clause to
    /// attach, so a number in it is a request for the substitution bug.
    /// </summary>
    [Fact]
    public void NothingContainingADigitIsEverEmitted()
    {
        var context = new ScreenContext
        {
            VisibleText =
                "Upgrade to Gemini 3.5 Flash before Tuesday. Port 8080 is taken, use 9090. "
                + "Version v2.1.0 shipped. Contact Kaelith about the Brindlewood migration.",
        };

        var terms = Keyterms.Derive(context);

        Assert.All(terms, term => Assert.DoesNotContain(term, c => char.IsDigit(c)));
        // The names still come through — the rule costs nothing it should not cost.
        Assert.Contains("Kaelith", terms);
        Assert.Contains("Brindlewood", terms);
    }

    [Fact]
    public void AcronymsCamelCaseAndJoinedIdentifiersQualify()
    {
        var terms = Keyterms.Candidates(
            "The HTTP handler in OpenRouter calls quillmark-sync and snake_case_helper.");

        Assert.Contains("HTTP", terms);
        Assert.Contains("OpenRouter", terms);
        Assert.Contains("quillmark-sync", terms);
        Assert.Contains("snake_case_helper", terms);
    }

    /// <summary>A capital opening a sentence is grammar, not a proper noun.</summary>
    [Fact]
    public void SentenceInitialCapitalsAreNotTreatedAsProperNouns()
    {
        var terms = Keyterms.Candidates("We shipped Brindlewood today. However it broke.");

        Assert.Contains("Brindlewood", terms);
        Assert.DoesNotContain("We", terms);
        Assert.DoesNotContain("However", terms);
    }

    [Fact]
    public void OrdinaryProseYieldsNothing() =>
        Assert.Empty(Keyterms.Candidates("we should probably just ship it and see what happens"));

    [Fact]
    public void SurroundingPunctuationIsTrimmedButIdentifiersKeepTheirOwn()
    {
        var terms = Keyterms.Candidates("See (Kaelith), \"Brindlewood\" and README.md here.");

        Assert.Contains("Kaelith", terms);
        Assert.Contains("Brindlewood", terms);
        Assert.Contains("README.md", terms);
    }

    /// <summary>Caret-adjacent text predicts speech better than the rest of a long window.</summary>
    [Fact]
    public void TermsNearestTheCaretComeFirst()
    {
        var context = new ScreenContext
        {
            VisibleText = "FarAway MentionedOnlyInBody",
            TextBeforeCaret = "NearCaret",
            SelectedText = "SelectedFirst",
        };

        var terms = Keyterms.Derive(context);

        Assert.Equal("SelectedFirst", terms[0]);
        Assert.True(terms.ToList().IndexOf("NearCaret") < terms.ToList().IndexOf("FarAway"));
    }

    [Fact]
    public void TermCountIsCappedAndDuplicatesCollapseCaseInsensitively()
    {
        var words = string.Join(' ', Enumerable.Range(0, 300).Select(i => $"AlphaName{(char)('a' + i % 26)}Term"));
        Assert.True(Keyterms.Derive(new ScreenContext { VisibleText = words }, maxTerms: 5).Count <= 5);

        var repeated = new ScreenContext { VisibleText = "start Brindlewood BRINDLEWOOD brindlewood again" };
        Assert.Single(Keyterms.Derive(repeated).Where(t => t.Equals("brindlewood", StringComparison.OrdinalIgnoreCase)));
    }

    [Fact]
    public void TermsLongerThanTheLimitAreDropped()
    {
        var long_ = "Kaelith" + new string('x', 60);
        var terms = Keyterms.Derive(
            new ScreenContext { VisibleText = $"start {long_} and Brindlewood" }, maxCharsPerTerm: 50);

        Assert.DoesNotContain(long_, terms);
        Assert.Contains("Brindlewood", terms);
    }

    /// <summary>The defect that made this feature useless for a bilingual user.</summary>
    [Fact]
    public void LatinTermsAreExtractedFromCodeSwitchedChinese()
    {
        var context = new ScreenContext
        {
            VisibleText = "我要把这几个串起来搞成一个retrieval pipeline，然后用Kubernetes部署。"
                + "参考Google的做法。看一下quillmark-sync这个repo。",
            TextBeforeCaret = "刚才说的RAG方案",
        };

        var terms = Keyterms.Derive(context);

        Assert.Contains("RAG", terms);
        Assert.Contains("Kubernetes", terms);
        Assert.Contains("quillmark-sync", terms);
        Assert.All(terms, term => Assert.DoesNotContain(term, Keyterms.IsCjkScript));
    }

    /// <summary>Pure Chinese yields nothing: identifying a term there needs segmentation.</summary>
    [Fact]
    public void PureChineseYieldsNothingRatherThanABlob() =>
        Assert.Empty(Keyterms.Derive(new ScreenContext { VisibleText = "我要把这几个串起来然后部署到线上环境。" }));

    [Fact]
    public void UnbalancedBracketsAndQuotesSplitRatherThanRideAlong()
    {
        var terms = Keyterms.Candidates("""lib.func('getFocusedAppInfo') and git commit --author="Li Bojie" """);

        Assert.Contains("lib.func", terms);
        Assert.Contains("getFocusedAppInfo", terms);
        Assert.Contains("--author", terms);
        Assert.DoesNotContain(terms, t => t.Contains('\'') || t.Contains('"') || t.Contains('('));
    }

    /// <summary>A dot is interior to README.md and terminal after "tokens."; look-ahead decides.</summary>
    [Fact]
    public void AFullStopEndsASentenceUnlessAWordContinuesIt()
    {
        var terms = Keyterms.Candidates(
            "Costs $3.00 per million tokens. Compare Gemini and read README.md for details.");

        Assert.Contains("README.md", terms);
        Assert.DoesNotContain("Compare", terms);
        Assert.Contains("Gemini", terms);
    }

    [Fact]
    public void ContractionsAreRejectedButApostropheNamesSurvive()
    {
        Assert.DoesNotContain("I'll", Keyterms.Candidates("Ask Kaelith, I'll review it"));
        Assert.Contains("O'Brien", Keyterms.Candidates("Ask O'Brien about it"));
    }

    [Fact]
    public void CommandLineFlagsQualifyWhetherOrNotTheyAreHyphenated()
    {
        var terms = Keyterms.Candidates("run git commit --amend --no-edit --author now");
        Assert.Contains("--amend", terms);
        Assert.Contains("--no-edit", terms);
        Assert.Contains("--author", terms);
    }

    [Fact]
    public void EmptyContextYieldsNoTerms()
    {
        Assert.Empty(Keyterms.Derive(new ScreenContext()));
        Assert.Empty(Keyterms.Derive(new ScreenContext { VisibleText = "a b" }, maxTerms: 0));
    }
}

/// <summary>Request shaping and response parsing, without touching the network.</summary>
public class SpeechRecognitionProviderTests
{
    /// <summary>`multi` measured 18/42 against detection's 12/42 on the near-miss suite.</summary>
    [Fact]
    public void NovaThreeDefaultsToMultilingualRatherThanDetection() =>
        Assert.Equal("&language=multi", DeepgramProvider.LanguageQuery(null, "nova-3"));

    /// <summary>`multi` is nova-3 only and a 400 on anything older.</summary>
    [Fact]
    public void OlderModelsFallBackToDetection() =>
        Assert.Equal("&detect_language=true", DeepgramProvider.LanguageQuery(null, "nova-2"));

    [Fact]
    public void AnExplicitLanguageAlwaysWins()
    {
        Assert.Equal("&language=zh", DeepgramProvider.LanguageQuery("zh", "nova-3"));
        Assert.Equal("&language=zh", DeepgramProvider.LanguageQuery("zh", "nova-2"));
    }

    [Fact]
    public void KeytermSupportIsReportedPerModel()
    {
        Assert.IsType<GroundingSupport.KeytermGrounding>(new DeepgramProvider("k", "nova-3").Grounding);
        Assert.IsType<GroundingSupport.NoGrounding>(new DeepgramProvider("k", "nova-2").Grounding);
    }

    /// <summary>Voxtral has no biasing channel: `context` and `prompt` are accepted and ignored.</summary>
    [Fact]
    public void MistralReportsNoGroundingAtAll() =>
        Assert.IsType<GroundingSupport.NoGrounding>(new MistralProvider("k").Grounding);

    /// <summary>
    /// Through the interface, because <c>Grounding</c> is a default interface member: the model
    /// providers deliberately do not override it, so the default is what they report.
    /// </summary>
    [Fact]
    public void ModelProvidersStillReportMultimodalGrounding()
    {
        ITranscriptionProvider gemini = new GeminiProvider("k");
        Assert.IsType<GroundingSupport.MultimodalGrounding>(gemini.Grounding);
    }

    [Fact]
    public void DeepgramParsesTranscriptAndDetectedLanguage()
    {
        const string body =
            """{"results":{"channels":[{"detected_language":"en","alternatives":[{"transcript":"Should switch."}]}]}}""";

        var transcript = DeepgramProvider.Parse(body);

        Assert.Equal("Should switch.", transcript.Text);
        Assert.Equal("en", transcript.Language);
    }

    [Fact]
    public void DeepgramErrorBodyIsUnwrappedToTheActionableSentence() =>
        Assert.Equal(
            "Token is invalid (INVALID_AUTH)",
            DeepgramProvider.ErrorMessage("""{"err_code":"INVALID_AUTH","err_msg":"Token is invalid"}"""));

    [Fact]
    public void MistralReportsAudioTokensSoTheSilentDropGuardIsLive()
    {
        const string body =
            """{"text":"hi","usage":{"prompt_tokens":3,"completion_tokens":14,"prompt_tokens_details":{"audio_tokens":375}}}""";

        var usage = MistralProvider.ParseUsage(body);

        Assert.Equal(375, usage.AudioTokens);
        Assert.Equal(3, usage.PromptTokens);
    }

    /// <summary>The one part of the xAI provider confirmed against the live API.</summary>
    [Fact]
    public void XaiErrorBodyIsUnwrapped() =>
        Assert.Equal(
            "Incorrect API key provided. (invalid-argument)",
            XAISpeechProvider.ErrorMessage(
                """{"code":"invalid-argument","error":"Incorrect API key provided."}"""));

    /// <summary>
    /// The rewrite path sends text with no audio. A recogniser cannot serve it, and the error has
    /// to say what to do rather than surfacing as a raw 400 from the network.
    /// </summary>
    [Fact]
    public async Task TextOnlyRequestIsRejectedWithoutReachingTheNetwork()
    {
        var error = await Assert.ThrowsAsync<ProviderException>(() =>
            new DeepgramProvider("k").TranscribeAsync("i", [new InputPart.Text("rewrite this")]));

        Assert.Contains("cannot", error.Message, StringComparison.OrdinalIgnoreCase);
        Assert.False(error.IsTransient);
    }

    [Fact]
    public void RecognitionBackendsAreFlaggedAsSuch()
    {
        Assert.True(ProviderKind.Deepgram.IsSpeechRecognition());
        Assert.True(ProviderKind.Mistral.IsSpeechRecognition());
        Assert.True(ProviderKind.XAI.IsSpeechRecognition());
        Assert.False(ProviderKind.Gemini.IsSpeechRecognition());
        Assert.Equal("nova-3", ProviderKind.Deepgram.DefaultModel());
        Assert.Equal("DEEPGRAM_API_KEY", ProviderKind.Deepgram.ApiKeyEnvVar());
    }
}
