namespace DoNotType.Core;

/// <summary>The shape of a settings preview, and the words it is presented with.</summary>
/// <remarks>
/// Hand-ported from Sources/DoNotTypeCore/StylePreview.swift, because the four clients have to
/// describe the same thing the same way -- somebody comparing a laptop to a phone is comparing the
/// same product -- and because <em>which baseline to use</em> is a rule rather than a preference.
///
/// The preview exists because every control in a settings panel is a <em>cause</em> and what a user
/// needs is the <em>effect</em>. The label that read "Chat — short lines, light punctuation" was
/// describing its effect accurately while being read as a mood.
/// </remarks>
public static class StylePreview
{
    /// <summary>Where the left-hand pane's text comes from.</summary>
    public enum Baseline
    {
        /// <summary>A dictation already in History: a real past result, free, the honest "before".</summary>
        Stored,

        /// <summary>
        /// A clip just recorded, which has no past. The baseline is the same audio sent with the
        /// example box emptied -- the one comparison that answers "what is my example doing".
        /// </summary>
        WithoutExample,

        /// <summary>A clip recorded while the box is empty. The second request would be the first.</summary>
        None,
    }

    public static string Label(this Baseline baseline) => baseline switch
    {
        Baseline.Stored => "What you got",
        Baseline.WithoutExample => "Without your example",
        _ => "Your transcript",
    };

    public const string StyledLabel = "With these settings";

    /// <summary>How many model requests a preview of a freshly recorded clip will cost.</summary>
    /// <remarks>
    /// Stated as a method rather than assumed at each call site, because the answer is the
    /// difference between one request and two and the user is told which before pressing.
    /// </remarks>
    public static Baseline BaselineForClip(string example) =>
        Typography.SanitizedSample(example).Length == 0
            ? Baseline.None
            : Baseline.WithoutExample;

    /// <summary>What the button says it will cost. A preview is a real request, so it says so.</summary>
    public static string CostNote(Baseline baseline) => baseline switch
    {
        Baseline.Stored =>
            "Sends your most recent recording again with the settings above, and shows both "
            + "answers. One request.",
        Baseline.WithoutExample =>
            "Records a clip, then transcribes it twice — once with your example and once without — "
            + "so you can see what the example is doing. Two requests.",
        _ => "Records a clip and transcribes it with the settings above. One request.",
    };

    /// <summary>Said where a preview cannot run, rather than leaving a control disabled in silence.</summary>
    public const string NoStoredRecording =
        "No kept recording to try this on. Record a clip instead, or turn on Keep audio and make a "
        + "dictation.";
}
