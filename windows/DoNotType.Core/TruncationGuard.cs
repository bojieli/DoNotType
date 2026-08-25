namespace DoNotType.Core;

/// <summary>
/// The gate for a transcript that is <em>too short</em> for the audio.
/// </summary>
/// <remarks>
/// <para>
/// <see cref="HallucinationGuard"/> catches a model that invented words. This catches the opposite,
/// and until it existed nothing did: a model that stopped early and returned fluent, plausible text
/// with the middle of the dictation missing. The two are not symmetric. Fabrication is loud once you
/// look for it. Truncation is silent, because what comes back reads perfectly; it is only wrong in
/// what it does not say.
/// </para>
/// <para>
/// Measured 2026-08-25 on a 90-second Mandarin recording: <c>gemini-3.5-flash</c> at
/// <c>minimal</c> returned roughly 100 characters of a 310-character transcript, stopping
/// mid-sentence at the identical point every time it failed, on 6 runs in 10.
/// <c>gemini-3.6-flash</c> did it 0 times in 20. It is not the output-token cap.
/// </para>
/// <para>
/// The denominator is Silero-confirmed speech, not recording length. Across 350 real dictations the
/// legitimate minimum is 1.55 characters a second of audio and the truncated transcript ran 1.09 —
/// a 1.4x margin, which is a coin toss rather than a threshold, because speech is only 14% to 61%
/// of a recording. Against speech they separate: the truncated runs are 2.00 and 2.27, complete
/// runs of the same recording 6.31 and 7.78, and the minimum across 350 dictations 4.92.
/// </para>
/// <para>
/// The costs are asymmetric. A false positive spends one request nobody sees; a false negative
/// hands somebody a plausible transcript with their words deleted. So the floor sits nearer the
/// legitimate minimum than the observed failure.
/// </para>
/// </remarks>
public static class TruncationGuard
{
    /// <summary>Characters per second of Silero-confirmed speech below which a transcript is suspect.</summary>
    public const double MinimumCharactersPerSecond = 3.5;

    /// <summary>Below this much speech the ratio is not evidence.</summary>
    /// <remarks>
    /// Short clips make the rate wild in both directions, and truncation is a long-audio failure:
    /// 0 occurrences in 30 whole-file runs across six recordings that did not reproduce it. The
    /// same reasoning as <see cref="HallucinationGuard.MinimumSuspiciousCharacters"/>, from the
    /// other end.
    /// </remarks>
    public const double MinimumSpeechSeconds = 20.0;

    /// <summary>Cheap pre-filter, so the expensive check runs only on plausible candidates.</summary>
    /// <remarks>
    /// Characters per second of recording cannot decide anything, but it bounds the question from a
    /// WAV header rather than a model. The fifth percentile of real dictations is 3.16 and the
    /// median 7.57, so this admits roughly the bottom tenth for a second look.
    /// </remarks>
    public const double ScreeningCharactersPerSecond = 4.0;

    public enum Reason
    {
        Kept,
        SuspectedTruncation,
    }

    public readonly record struct Verdict(Reason Reason, int Characters, double SpeechSeconds)
    {
        public static readonly Verdict Kept = new(Reason.Kept, 0, 0);

        public bool IsSuspect => Reason == Reason.SuspectedTruncation;

        public string Summary => Reason switch
        {
            Reason.Kept => "kept",
            _ => string.Format(
                System.Globalization.CultureInfo.InvariantCulture,
                "{0} chars in {1:F1}s of speech = {2:F2} chars/s, floor {3:F2}",
                Characters, SpeechSeconds,
                Characters / System.Math.Max(SpeechSeconds, 0.001), MinimumCharactersPerSecond),
        };
    }

    /// <summary>Whether this transcript is worth measuring properly. Costs a subtraction.</summary>
    public static bool WarrantsInspection(string text, double? audioSeconds)
    {
        if (audioSeconds is not > 0) return false;
        return text.Trim().Length / audioSeconds.Value < ScreeningCharactersPerSecond;
    }

    /// <summary>The verdict, given how much speech the recording actually contains.</summary>
    /// <remarks>
    /// Unknown speech length yields <see cref="Verdict.Kept"/>: no measurement, no accusation.
    /// </remarks>
    public static Verdict Inspect(string text, double? speechSeconds)
    {
        if (speechSeconds is not >= MinimumSpeechSeconds) return Verdict.Kept;
        var characters = text.Trim().Length;
        if (characters == 0) return Verdict.Kept;
        if (characters / speechSeconds.Value >= MinimumCharactersPerSecond) return Verdict.Kept;
        return new Verdict(Reason.SuspectedTruncation, characters, speechSeconds.Value);
    }
}
