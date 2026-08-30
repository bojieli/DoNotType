using DoNotType.Core;
using Xunit;

namespace DoNotType.Core.Tests;

/// <summary>
/// What the Model field accepts, and what it says about the rest.
/// </summary>
/// <remarks>
/// These are sentences a user actually reads, so they are asserted as text. The rules match
/// `Sources/DoNotTypeCore/ModelIdentifier.swift` and
/// `android/app/src/main/kotlin/app/donottype/core/ModelIdentifier.kt` deliberately, and the tests
/// are duplicated in each language rather than shared: a fixture would be read by whichever
/// platform remembered to read it.
/// </remarks>
public sealed class ModelIdentifierTests
{
    /// <summary>
    /// The shapes that actually reach these providers. A rule that rejected any of these would
    /// stop somebody configuring a model that works.
    /// </summary>
    [Theory]
    [InlineData("gemini-3.6-flash")]
    [InlineData("google/gemini-3.6-flash")]
    [InlineData("nova-3")]
    [InlineData("grok-4-fast-non-reasoning")]
    [InlineData("voxtral-mini-latest")]
    [InlineData("gpt-4o-2024-08-06")]
    [InlineData("accounts/fireworks/models/llama-v3p1-8b")]
    [InlineData("qwen2.5:7b-instruct-q4_K_M")]
    [InlineData("ft:gpt-4o:acme:tone:1")]
    [InlineData("local-model")]
    public void RealModelIdentifiersAreAccepted(string id)
    {
        Assert.True(ModelIdentifier.IsValid(id));
        Assert.Null(ModelIdentifier.ValidationMessage(id));
    }

    /// <summary>
    /// Clearing the field is how a user asks for the backend's default, which every client already
    /// reads that way. Reporting it as an error would make the documented gesture look broken.
    /// </summary>
    [Fact]
    public void AnEmptyFieldIsNotAnError()
    {
        Assert.Null(ModelIdentifier.ValidationMessage(""));
        Assert.Null(ModelIdentifier.ValidationMessage("   "));
        Assert.Null(ModelIdentifier.ValidationMessage(null));
    }

    /// <summary>
    /// Surrounding space is trimmed on the way to storage on every client, so flagging it would
    /// report a problem that the next line of code removes.
    /// </summary>
    [Fact]
    public void SurroundingWhitespaceIsTrimmedRatherThanRejected()
    {
        Assert.Null(ModelIdentifier.ValidationMessage("  gemini-3.6-flash \n"));
    }

    /// <summary>
    /// The case this whole check exists for: the field had focus, and a sentence went into it.
    /// </summary>
    [Fact]
    public void ADictatedSentenceIsRejectedForItsSpaces()
    {
        Assert.Equal(
            "A model ID has no spaces in it. Check for a stray space, or for a sentence that "
                + "landed in this field by accident.",
            ModelIdentifier.ValidationMessage("please open the door"));
    }

    /// <summary>
    /// Named rather than described. "Invalid character" leaves the user hunting through a string
    /// they cannot see the end of; the character itself is the whole answer.
    /// </summary>
    [Fact]
    public void ANonAsciiCharacterIsNamedInTheMessage()
    {
        Assert.Equal(
            "\"模\" is not a character model IDs are made of. They use letters, digits, and "
                + ". _ - : / + @ — for example gemini-3.6-flash.",
            ModelIdentifier.ValidationMessage("模型-flash"));
    }

    /// <summary>
    /// Accented Latin is as wrong here as CJK and used to be the likelier accident, since it
    /// arrives from a keyboard layout rather than from an input method.
    /// </summary>
    [Fact]
    public void AccentedLatinIsRejected()
    {
        Assert.False(ModelIdentifier.IsValid("café-flash"));
    }

    /// <summary>
    /// Punctuation that no provider uses but a shell or a URL does. Left in, these reach the
    /// request as part of the model name and come back as a 404.
    /// </summary>
    [Theory]
    [InlineData("gemini!flash")]
    [InlineData("gemini,flash")]
    [InlineData("gemini(flash)")]
    [InlineData("gemini#flash")]
    [InlineData("gemini$flash")]
    public void PunctuationOutsideTheAllowedSetIsRejected(string id)
    {
        Assert.False(ModelIdentifier.IsValid(id));
    }

    /// <summary>
    /// A newline is whitespace, so it gets the sentence about spaces rather than an unprintable
    /// character quoted into the middle of a message.
    /// </summary>
    [Theory]
    [InlineData("gemini\tflash")]
    [InlineData("gemini\nflash")]
    public void ATabOrNewlineReadsAsASpace(string id)
    {
        Assert.Equal(
            "A model ID has no spaces in it. Check for a stray space, or for a sentence that "
                + "landed in this field by accident.",
            ModelIdentifier.ValidationMessage(id));
    }

    /// <summary>
    /// A pasted paragraph is caught as a paragraph. Without a cap it would be reported by whatever
    /// character in it happened to be disallowed first, which explains nothing.
    /// </summary>
    [Fact]
    public void APastedParagraphIsRejectedForItsLength()
    {
        Assert.Equal(
            "A model ID is at most 200 characters. This looks like something other than a model "
                + "ID ended up in the field.",
            ModelIdentifier.ValidationMessage(new string('a', ModelIdentifier.MaxLength + 1)));
    }

    [Fact]
    public void TheLengthCapIsInclusive()
    {
        Assert.True(ModelIdentifier.IsValid(new string('a', ModelIdentifier.MaxLength)));
    }
}
