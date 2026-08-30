using DoNotType.Core;
using Xunit;

namespace DoNotType.Core.Tests;

/// <summary>
/// The typography table, repeated verbatim in <c>Tests/DoNotTypeCoreTests/TypographyTests.swift</c>
/// and <c>android/app/src/test/kotlin/app/donottype/core/TypographyTest.kt</c>.
/// </summary>
/// <remarks>
/// Repeated rather than shared through a fixture file, like the mode grammar: a fixture is read by
/// whichever platform remembers to read it, and a transcript that is spaced on a laptop and tight
/// on a phone is exactly the inconsistency this type was added to remove.
/// </remarks>
public sealed class TypographyTests
{
    /// <summary>input, spaced, tight.</summary>
    public static TheoryData<string, string, string> Table => new()
    {
        // The boundary, in both directions and with the space already there or not.
        { "中文English", "中文 English", "中文English" },
        { "中文 English", "中文 English", "中文English" },
        { "中文  English", "中文 English", "中文English" },
        { "English中文", "English 中文", "English中文" },
        { "English 中文", "English 中文", "English中文" },
        // Digits count as the Latin side. This is the convention, and it is also what makes
        // "gemini-3.5-flash" read the same way in Chinese prose as in English.
        { "在2026年", "在 2026 年", "在2026年" },
        { "使用GPT-4模型", "使用 GPT-4 模型", "使用GPT-4模型" },
        // The reported bug: a stray space after a full-width stop, on some sentences and not
        // others. No convention allows it, so both settings remove it.
        { "你好。 世界", "你好。世界", "你好。世界" },
        { "你好 ，世界", "你好，世界", "你好，世界" },
        { "完成了。 Then I said hi.", "完成了。Then I said hi.", "完成了。Then I said hi." },
        { "《书名》 abc", "《书名》abc", "《书名》abc" },
        // English is not touched at all, whichever setting is in force.
        { "Hello world.", "Hello world.", "Hello world." },
        { "Two  spaces stay.", "Two  spaces stay.", "Two  spaces stay." },
        // A space between two Han characters is left alone. Removing it would join words the
        // speaker meant to keep apart, and this transform is never allowed to change wording —
        // the model is asked for proper punctuation there instead, in prompt/typography.md.
        { "这是 一个 句子", "这是 一个 句子", "这是 一个 句子" },
        // Structure survives: a newline is not horizontal space, and an indent is the caller's.
        { "第一行\n第二行abc", "第一行\n第二行 abc", "第一行\n第二行abc" },
        { "  缩进", "  缩进", "  缩进" },
        { "中文 ", "中文 ", "中文 " },
        // Symbols are not the Latin side, deliberately: a rule that fires on punctuation has far
        // more ways to be wrong.
        { "50%的人", "50%的人", "50%的人" },
        // Korean separates its own words. Tight must not take that space away.
        { "Web 개발", "Web 개발", "Web 개발" },
        // Kana is treated like Han, so Japanese is consistent within itself.
        { "Webかいはつ", "Web かいはつ", "Webかいはつ" },
        { "A・B", "A・B", "A・B" },
        { "", "", "" },
    };

    [Theory]
    [MemberData(nameof(Table))]
    public void TheTableHolds(string input, string spaced, string tight)
    {
        Assert.Equal(spaced, Typography.Normalize(input, TypographySpacing.Spaced));
        Assert.Equal(tight, Typography.Normalize(input, TypographySpacing.Tight));
    }

    /// <summary>The escape hatch has to be exactly that: not a milder rule, no rule at all.</summary>
    [Theory]
    [MemberData(nameof(Table))]
    public void UnchangedTouchesNothing(string input, string spaced, string tight)
    {
        _ = spaced;
        _ = tight;
        Assert.Equal(input, Typography.Normalize(input, TypographySpacing.Unchanged));
    }

    /// <summary>
    /// A split recording is normalised per chunk and again over the stitch, so this is load
    /// bearing rather than a nicety.
    /// </summary>
    [Theory]
    [MemberData(nameof(Table))]
    public void NormalisingTwiceIsNormalisingOnce(string input, string spaced, string tight)
    {
        _ = spaced;
        _ = tight;
        foreach (var spacing in Enum.GetValues<TypographySpacing>())
        {
            var once = Typography.Normalize(input, spacing);
            Assert.Equal(once, Typography.Normalize(once, spacing));
        }
    }

    /// <summary>
    /// The invariant that makes this safe to run on every transcript: it is a space transform.
    /// Anything else here would be editing what the user said.
    /// </summary>
    [Theory]
    [MemberData(nameof(Table))]
    public void OnlySpacingEverChanges(string input, string spaced, string tight)
    {
        _ = spaced;
        _ = tight;
        var expected = new string([.. input.Where(c => !char.IsWhiteSpace(c))]);
        foreach (var spacing in Enum.GetValues<TypographySpacing>())
        {
            var result = Typography.Normalize(input, spacing);
            Assert.Equal(expected, new string([.. result.Where(c => !char.IsWhiteSpace(c))]));
        }
    }

    [Fact]
    public void TheDefaultIsAStableRuleRatherThanTheModelsJudgement()
    {
        Assert.Equal(TypographySpacing.Spaced, Typography.DefaultSpacing);
    }
}
