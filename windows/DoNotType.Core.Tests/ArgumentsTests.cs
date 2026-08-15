using Xunit;

namespace DoNotType.Core.Tests;

/// <summary>
/// The argument parser, which is the part of a developer tool everybody touches and nobody reads.
/// </summary>
public sealed class ArgumentsTests
{
    [Fact]
    public void AVerbAndAPathAreTakenApart()
    {
        var args = CommandLine.Parse(["transcribe", "speech.wav"]);
        Assert.Equal("transcribe", args.Verb);
        Assert.Equal(["speech.wav"], args.Positional);
    }

    [Fact]
    public void AnOptionTakesTheNextTokenAndAFlagDoesNot()
    {
        var args = CommandLine.Parse(["transcribe", "speech.wav", "--mode", "summary", "--json"]);
        Assert.Equal("summary", args.Option("mode"));
        Assert.True(args.Flag("json"));
        Assert.Equal(["speech.wav"], args.Positional);
    }

    /// <summary>
    /// The order of a flag and an option must not change what either means, because nobody
    /// remembers a rule like that and the failure is silent — the path becomes the option's value.
    /// </summary>
    [Theory]
    [InlineData("--json|--output|notes.txt|speech.wav")]
    [InlineData("--output|notes.txt|--json|speech.wav")]
    [InlineData("speech.wav|--output|notes.txt|--json")]
    public void FlagsAndOptionsCommuteAroundThePath(string rest)
    {
        var args = CommandLine.Parse(["transcribe", .. rest.Split('|')]);
        Assert.Equal("notes.txt", args.Option("output"));
        Assert.True(args.Flag("json"));
        Assert.Equal(["speech.wav"], args.Positional);
    }

    /// <summary>
    /// The bug this file exists for. `Flag` matched on the first letter, so every flag was
    /// silently aliased to its initial and the two that begin with p were the same flag.
    /// </summary>
    [Fact]
    public void AFlagIsNotItsFirstLetter()
    {
        var args = CommandLine.Parse(["doctor", "--probe"]);
        Assert.True(args.Flag("probe"));
        Assert.False(args.Flag("path"));
        Assert.False(args.Flag("provider"));
    }

    [Fact]
    public void AnEmptyNameIsAskedAboutWithoutThrowing()
    {
        // Reached through a `Flag(userSuppliedString)` path; used to be an index out of range.
        Assert.False(CommandLine.Parse(["doctor"]).Flag(string.Empty));
    }

    [Fact]
    public void TheOneShortFormStillWorks()
    {
        Assert.True(CommandLine.Parse(["doctor", "-v"]).Flag("verbose"));
        Assert.True(CommandLine.Parse(["doctor", "--verbose"]).Flag("verbose"));
    }

    /// <summary>
    /// An undeclared short option is a typo, and used to be accepted as a file name — which turned
    /// `--output` misspelled as `-o` into "No such file: -o", blaming the wrong token.
    /// </summary>
    [Fact]
    public void AnUndeclaredShortOptionSaysSo()
    {
        var error = Assert.Throws<UsageException>(
            () => CommandLine.Parse(["transcribe", "-o", "notes.txt", "speech.wav"]));
        Assert.Contains("--o", error.Message);
    }

    [Fact]
    public void ADashAloneIsStillAPositional()
    {
        Assert.Equal(["-"], CommandLine.Parse(["transcribe", "-"]).Positional);
    }

    [Fact]
    public void ANegativeNumberIsAValueNotAnOption()
    {
        Assert.Equal(["-3"], CommandLine.Parse(["history", "-3"]).Positional);
    }

    [Fact]
    public void IntFallsBackWhenTheValueIsNotANumber()
    {
        var args = CommandLine.Parse(["logs", "--lines", "abc"]);
        Assert.Equal(50, args.Int("lines", 50));
        Assert.Equal(120, CommandLine.Parse(["logs", "--lines", "120"]).Int("lines", 50));
    }
}
