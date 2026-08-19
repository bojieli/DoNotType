using DoNotType.Core;
using Xunit;

namespace DoNotType.Core.Tests;

/// <summary>
/// The second hotkey: dictate, then rewrite.
/// </summary>
/// <remarks>
/// The keyboard hook and the controller need Windows and a message loop, so what is covered here is
/// the part that decides *what a press means* — which style a key maps to, and that the mapping
/// between the settings enum and the combo box in the settings form is not off by one. That
/// off-by-one is the whole risk in this feature: the list omits Verbatim, so every index is shifted,
/// and getting it wrong silently rewrites in a style nobody chose.
/// </remarks>
public sealed class SecondaryTriggerTests
{
    /// <summary>
    /// The styles the second key can produce, in the order the settings form lists them. Verbatim
    /// is absent on purpose: it is what the first key already does, and a second key producing the
    /// same thing is a setting with no effect.
    /// </summary>
    private static readonly RewriteStyle[] Offered =
        [RewriteStyle.Formal, RewriteStyle.Concise, RewriteStyle.Casual];

    [Fact]
    public void TheListOffersEveryRewriteAndNothingElse()
    {
        var everyRewrite = Enum.GetValues<RewriteStyle>().Where(style => style.IsRewrite());
        Assert.Equal(everyRewrite, Offered);
        Assert.DoesNotContain(RewriteStyle.Verbatim, Offered);
    }

    /// <summary>
    /// The settings form stores `(RewriteStyle)(index + 1)` and reads back `(int)style - 1`. If
    /// those ever disagree, somebody's Concise silently becomes Casual.
    /// </summary>
    [Theory]
    [InlineData(RewriteStyle.Formal, 0)]
    [InlineData(RewriteStyle.Concise, 1)]
    [InlineData(RewriteStyle.Casual, 2)]
    public void TheIndexAndTheStyleAgreeInBothDirections(RewriteStyle style, int index)
    {
        Assert.Equal(style, (RewriteStyle)(index + 1));
        Assert.Equal(index, (int)style - 1);
        Assert.Equal(style, Offered[index]);
    }

    /// <summary>Every style the second key offers has to have a prompt block behind it.</summary>
    [Theory]
    [InlineData(RewriteStyle.Formal)]
    [InlineData(RewriteStyle.Concise)]
    [InlineData(RewriteStyle.Casual)]
    public void EveryOfferedStyleHasAnInstruction(RewriteStyle style)
    {
        var instruction = new PromptBuilder(
                PromptBuilder.FindPromptDirectory()
                ?? throw new InvalidOperationException("prompt/ not found from the test run"))
            .SecondStageInstruction(TranscriptMode.Rewrite(style));

        Assert.NotNull(instruction);
        Assert.NotEmpty(instruction);
        // The block that says a rewrite may never drop a fact, which is what separates it from a
        // summary and is the reason the two have different prompt blocks at all.
        Assert.Contains("fact", instruction, StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>
    /// A default that produced verbatim would make turning the second key on do nothing, which
    /// reads as the feature being broken rather than as a setting needing a second choice.
    /// </summary>
    [Fact]
    public void TheDefaultStyleActuallyRewrites()
    {
        Assert.True(RewriteStyle.Casual.IsRewrite());
    }
}
