namespace DoNotType.Core;

/// <summary>
/// The gate on the way back, for audio that got past the gate on the way out.
///
/// <see cref="SpeechActivity"/> refuses to send silence, and it is the better defence because it
/// costs nothing and works for every backend. It is not sufficient. Measured on real dictations: a
/// 0.68-second recording of room tone — a stray tap in a quiet room, 380 ms of transient 25 dB
/// above a −63 dB floor — passed the original activity gate, and the model answered it with 876 characters
/// of fluent, topically-plausible prose the user had never said. It was not copied off the screen
/// either: the longest verbatim run shared with the screen context was nine words.
///
/// Rule 7 of the prompt asks for an empty transcript, which is an <em>omission</em> — a model
/// already inventing cannot notice it is failing to omit something. So the prompt asks for a token
/// it must positively write, and this checks for it. The rate ceiling is the backstop for models
/// that ignore both; it is a physical claim rather than a stylistic one, since speech has a maximum
/// rate and text far above it did not come from the audio.
///
/// Ported by hand from Sources/DoNotTypeCore/HallucinationGuard.swift. The constants and the
/// decisions must stay identical across the two.
/// </summary>
public static class HallucinationGuard
{
    /// <summary>
    /// What the model writes when it heard nothing. A positive answer, so its absence is
    /// detectable — unlike an empty string, which is indistinguishable from a model that never
    /// addressed the question.
    /// </summary>
    public const string Marker = "[NO_SPEECH]";

    /// <summary>
    /// Characters per second of audio above which the transcript did not come from the speech.
    ///
    /// Fast English narration is ~200 wpm, about 17 characters a second. Real dictations measured
    /// through this app run 7–15. The fabrications that prompted this guard ran 822 and 1288.
    /// </summary>
    public const double MaximumCharactersPerSecond = 25.0;

    /// <summary>
    /// Below this the ratio is not evidence, however extreme it looks. A two-second recording
    /// answered with one ordinary sentence is already 35 characters a second and perfectly real.
    /// The measured fabrications ran 625, 646 and 876 characters, so this sits well under them and
    /// well over anything a person says quickly.
    /// </summary>
    public const int MinimumSuspiciousCharacters = 200;

    /// <summary>Why a transcript was suppressed.</summary>
    public enum Reason
    {
        Kept,
        NoSpeechMarker,
        ImpossibleRate,
    }

    /// <summary>The decision, with the measurement that produced it.</summary>
    public readonly record struct Verdict(Reason Reason, int Characters, double Seconds)
    {
        public static readonly Verdict Kept = new(Reason.Kept, 0, 0);

        public string Summary => Reason switch
        {
            Reason.Kept => "kept",
            Reason.NoSpeechMarker => "model reported no speech",
            _ => $"{Characters} chars in {Seconds:F2}s = "
                + $"{Characters / Math.Max(Seconds, 0.001):F0} chars/s, ceiling "
                + $"{MaximumCharactersPerSecond:F0}",
        };
    }

    /// <summary>
    /// Exactly the token the prompt asks for, allowing only surrounding quotes, a full stop and
    /// whitespace. Deliberately strict: a looser match on the words would silently delete a
    /// dictation of somebody saying them.
    /// </summary>
    public static bool IsNoSpeechMarker(string text)
    {
        var stripped = text.Trim(' ', '\t', '\n', '\r', '"', '\'', '`', '.', '。');
        return string.Equals(stripped, Marker, StringComparison.OrdinalIgnoreCase)
            || string.Equals(stripped, "NO_SPEECH", StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>
    /// More text than the audio could physically contain. A duration of zero means unknown, and
    /// unknown is not suspicious: no measurement, no verdict.
    /// </summary>
    public static bool ExceedsPlausibleRate(string text, double audioSeconds)
    {
        if (audioSeconds <= 0)
        {
            return false;
        }

        var characters = text.Trim().Length;
        return characters >= MinimumSuspiciousCharacters
            && characters / audioSeconds > MaximumCharactersPerSecond;
    }

    /// <summary>The whole decision. Returns the transcript to use and why it changed, if it did.</summary>
    public static (Transcript Transcript, Verdict Verdict) Inspect(
        Transcript transcript, double audioSeconds)
    {
        if (IsNoSpeechMarker(transcript.Text))
        {
            return (transcript with { Text = "" }, new Verdict(Reason.NoSpeechMarker, 0, audioSeconds));
        }

        if (ExceedsPlausibleRate(transcript.Text, audioSeconds))
        {
            return (
                transcript with { Text = "" },
                new Verdict(Reason.ImpossibleRate, transcript.Text.Trim().Length, audioSeconds));
        }

        return (transcript, Verdict.Kept);
    }
}
