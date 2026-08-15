using System.Text;
using System.Text.RegularExpressions;

namespace DoNotType.Core;

/// <summary>
/// Takes digit sequences from an audio-only transcript and puts them into a grounded one.
/// </summary>
/// <remarks>
/// <para>
/// The evaluation suite has been consistent about where grounding goes wrong. Word-level
/// near-misses pass — names, acronym chains, jargon, brands, code-switched Mandarin — while
/// <em>every</em> measured regression has been a number: 1.5 to 2.5, 4240 to 1024, 4240 to 3240. A
/// value on screen is a strong prior, and unlike a misspelled name a wrong number is not
/// recoverable by reading it; nothing in the sentence marks it as wrong.
/// </para>
/// <para>
/// So this is deliberately not a general "trust the audio more" mechanism. It is scoped to the one
/// span type that measurably regresses, and it takes those spans from a run that could not have
/// seen the screen at all. The two requests are independent, so the cost is tokens rather than
/// latency when they are issued concurrently.
/// </para>
/// <para>
/// Ported from `Sources/DoNotTypeCore/NumericGuard.swift` and kept identical to it: the same
/// utterance dictated on a laptop and a desktop has to produce the same numbers, and the
/// measurements in the changelog describe one behaviour, not two.
/// </para>
/// </remarks>
public static class NumericGuard
{
    /// <summary>
    /// A digit run, with any separators that sit <em>between</em> digits — so 3.5, 1,024 and 16:9
    /// survive as one token while a trailing full stop does not become part of the number.
    /// </summary>
    private static readonly Regex Pattern = new(
        @"[0-9]+(?:[.,:\-][0-9]+)*", RegexOptions.Compiled | RegexOptions.CultureInvariant);

    /// <param name="Text">The grounded transcript with the spoken numbers put back into it.</param>
    /// <param name="Corrections">Numbers taken from the audio-only run, as (was, became).</param>
    /// <param name="SkippedForMismatch">
    /// The two transcripts disagreed on how many numbers there were.
    /// </param>
    public sealed record Reconciliation(
        string Text,
        IReadOnlyList<(string Was, string Became)> Corrections,
        bool SkippedForMismatch);

    /// <summary>
    /// Replaces each number in <paramref name="grounded"/> with the number in the same position
    /// from <paramref name="audioOnly"/>.
    /// </summary>
    /// <remarks>
    /// Positional alignment is only safe when both transcripts found the same <em>count</em> of
    /// numbers. When they disagree, one of them heard an extra figure or dropped one, and matching
    /// them up by index would move a value to somewhere it was never spoken — a worse failure than
    /// the one being fixed. In that case the grounded transcript is returned untouched and the
    /// caller can see why.
    /// </remarks>
    public static Reconciliation Reconcile(string grounded, string audioOnly)
    {
        var groundedMatches = Pattern.Matches(grounded);
        var audioNumbers = Numbers(audioOnly);

        if (groundedMatches.Count == 0)
        {
            return new Reconciliation(grounded, [], SkippedForMismatch: false);
        }
        if (groundedMatches.Count != audioNumbers.Count)
        {
            return new Reconciliation(grounded, [], SkippedForMismatch: true);
        }

        var corrections = new List<(string, string)>();
        var result = new StringBuilder();
        var cursor = 0;

        for (var index = 0; index < groundedMatches.Count; index++)
        {
            var match = groundedMatches[index];
            var spoken = audioNumbers[index];

            result.Append(grounded, cursor, match.Index - cursor);
            result.Append(spoken);
            cursor = match.Index + match.Length;

            if (match.Value != spoken) corrections.Add((match.Value, spoken));
        }
        result.Append(grounded, cursor, grounded.Length - cursor);

        return new Reconciliation(result.ToString(), corrections, SkippedForMismatch: false);
    }

    internal static IReadOnlyList<string> Numbers(string text) =>
        Pattern.Matches(text).Select(match => match.Value).ToList();

    /// <summary>
    /// Whether a dictation is in the regime where a screen number is likely to overwrite a spoken
    /// one.
    /// </summary>
    /// <remarks>
    /// <para>
    /// Measured, and the two channels are not close. The same contradicting value substitutes for
    /// what the speaker said 3/10 of the time from the visible-text section and 7/10 from the caret
    /// window — the text the user has already typed into the field they are dictating into.
    /// </para>
    /// <para>
    /// decoy in visible text: 30% without the guard, 8% with it.
    /// decoy in the caret window: 75% without, 20% with.
    /// </para>
    /// <para>
    /// So the trigger is digits near the caret, not digits anywhere on screen. The visible text is
    /// ten times the budget and routinely contains numbers that have nothing to do with the
    /// utterance — a sidebar, a timestamp, a row count — and spending a second request on those
    /// would make the cost constant while the benefit stayed occasional.
    /// </para>
    /// </remarks>
    public static bool IsHighRisk(ScreenContext? context)
    {
        if (context is null) return false;
        return new[] { context.TextBeforeCaret, context.TextAfterCaret, context.SelectedText }
            .Any(text => text is not null && text.Any(char.IsDigit));
    }
}

/// <summary>When to spend a second, screen-blind request to check the numbers.</summary>
public enum NumberCheckPolicy
{
    Never,

    /// <summary>Only when the text around the caret contains digits — where substitution is worst.</summary>
    WhenCaretHasNumbers,

    Always,
}

public static class NumberCheckPolicyExtensions
{
    public static string Id(this NumberCheckPolicy policy) => policy switch
    {
        NumberCheckPolicy.Never => "never",
        NumberCheckPolicy.WhenCaretHasNumbers => "whenCaretHasNumbers",
        _ => "always",
    };

    public static NumberCheckPolicy Parse(string? id) => id switch
    {
        "never" => NumberCheckPolicy.Never,
        "always" => NumberCheckPolicy.Always,
        _ => NumberCheckPolicy.WhenCaretHasNumbers,
    };

    public static string Label(this NumberCheckPolicy policy) => policy switch
    {
        NumberCheckPolicy.Never => "Never",
        NumberCheckPolicy.WhenCaretHasNumbers => "When the text you're editing contains numbers",
        _ => "Always",
    };

    /// <summary>Whether this policy fires for a given screen context.</summary>
    public static bool Applies(this NumberCheckPolicy policy, ScreenContext? context) => policy switch
    {
        NumberCheckPolicy.Never => false,
        NumberCheckPolicy.Always => true,
        _ => NumericGuard.IsHighRisk(context),
    };
}
