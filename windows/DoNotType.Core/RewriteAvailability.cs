namespace DoNotType.Core;

/// <summary>Which of the two second-stage jobs is being asked about.</summary>
/// <remarks>
/// Rewriting and translating have exactly the same requirements -- both take the transcript and
/// hand it back to a model as text -- so they share one rule and differ only in the noun the
/// sentence uses. Telling a user that a backend "cannot rewrite text" when they asked it to
/// translate sends them to look for the wrong setting.
/// </remarks>
public enum SecondStageJob
{
    Rewriting,
    Translating,
}

/// <summary>Wording for a <see cref="SecondStageJob"/>.</summary>
public static class SecondStageJobExtensions
{
    /// <summary>"rewriting" / "translating".</summary>
    public static string Gerund(this SecondStageJob job) =>
        job == SecondStageJob.Rewriting ? "rewriting" : "translating";

    /// <summary>"rewrite" / "translate".</summary>
    public static string Verb(this SecondStageJob job) =>
        job == SecondStageJob.Rewriting ? "rewrite" : "translate";
}

/// <summary>
/// Whether the second stage can run at all, and what to say when it cannot.
/// </summary>
/// <remarks>
/// Every client asked this question separately and got a different answer. macOS never asked and
/// offered the binding regardless; this form warned but left the control enabled; iOS and Android
/// asked whether the backend was a recogniser, which is a question about the <em>kind</em> of
/// backend and not about whether one is usable -- so a fresh install with no key at all offered a
/// rewrite that could not run.
///
/// One rule, hand-ported from the Swift with the strings word-identical, and asked through
/// <see cref="LiveModeExtensions.Availability"/> by every client -- a desktop key and a phone chip
/// are two ways of choosing between the same three modes. The reason text is the whole point: a
/// control greyed out without saying why is barely better than one that is missing, and a missing
/// one is how this feature came to look absent entirely.
/// </remarks>
public abstract record RewriteAvailability
{
    /// <summary>The stage can run.</summary>
    public sealed record Available : RewriteAvailability;

    /// <summary>No key for the selected backend, so nothing can run -- not a rewrite, not a transcript.</summary>
    public sealed record NoKey(SecondStageJob Job) : RewriteAvailability;

    /// <summary>
    /// The selected backend turns audio into text and cannot turn text into text, and no other
    /// configured backend can either.
    /// </summary>
    public sealed record BackendCannotRewrite(ProviderKind Kind, SecondStageJob Job)
        : RewriteAvailability;

    /// <summary>
    /// Translate was chosen with no target language configured. Not a backend problem: the mode is
    /// runnable as soon as Settings says which language to write in.
    /// </summary>
    public sealed record NoTargetLanguage : RewriteAvailability;

    public bool IsAvailable => this is Available;

    /// <summary>
    /// One sentence saying why not, and what to do about it. Empty when the stage can run.
    /// </summary>
    /// <remarks>
    /// Must stay word-identical across the four clients -- see docs/PARITY.md. Someone comparing a
    /// phone to a laptop is comparing the same product.
    /// </remarks>
    public string Reason => this switch
    {
        NoKey noKey =>
            $"Add an API key first — without one nothing can run, {noKey.Job.Gerund()} included.",
        BackendCannotRewrite cannot =>
            $"{cannot.Kind.PlainName()} only transcribes audio and cannot {cannot.Job.Verb()} "
            + $"text. Add a key for a backend that can, and {cannot.Job.Gerund()} will use it.",
        NoTargetLanguage =>
            "Set a target language in Settings first, and Translate will write in it.",
        _ => string.Empty,
    };

    /// <summary>Resolves against whatever the client uses to store keys.</summary>
    /// <param name="provider">The selected backend.</param>
    /// <param name="hasKey">
    /// Whether a usable key exists for a backend. Passed in rather than read here so the Keychain,
    /// DPAPI and SharedPreferences all answer the same question.
    /// </param>
    /// <param name="job">
    /// Which second stage is being asked about. Only the wording depends on it.
    /// </param>
    public static RewriteAvailability Resolve(
        ProviderKind provider,
        Func<ProviderKind, bool> hasKey,
        SecondStageJob job = SecondStageJob.Rewriting)
    {
        // Asked first, and about the selected backend: with no key the dictation itself fails, so a
        // message about rewriting would answer the second question while the first is still wrong.
        if (!hasKey(provider)) return new NoKey(job);

        if (provider.SupportsTextGeneration()) return new Available();

        // A recogniser with no text endpoint borrows a second stage from another configured
        // backend, which is the behaviour file transcription already had.
        var borrowed = Enum.GetValues<ProviderKind>()
            .Any(kind => kind.SupportsTextGeneration() && hasKey(kind));
        return borrowed ? new Available() : new BackendCannotRewrite(provider, job);
    }
}
