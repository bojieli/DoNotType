namespace DoNotType.Core;

/// <summary>
/// Whether the rewrite stage can run at all, and what to say when it cannot.
/// </summary>
/// <remarks>
/// Every client asked this question separately and got a different answer. macOS never asked and
/// offered the binding regardless; this form warned but left the control enabled; iOS and Android
/// asked whether the backend was a recogniser, which is a question about the <em>kind</em> of
/// backend and not about whether one is usable -- so a fresh install with no key at all offered a
/// rewrite that could not run.
///
/// One rule, hand-ported from the Swift with the strings word-identical. The reason text is the
/// whole point: a control greyed out without saying why is barely better than one that is missing,
/// and a missing one is how this feature came to look absent entirely.
/// </remarks>
public abstract record RewriteAvailability
{
    /// <summary>The stage can run.</summary>
    public sealed record Available : RewriteAvailability;

    /// <summary>No key for the selected backend, so nothing can run -- not a rewrite, not a transcript.</summary>
    public sealed record NoKey : RewriteAvailability;

    /// <summary>
    /// The selected backend turns audio into text and cannot turn text into text, and no other
    /// configured backend can either.
    /// </summary>
    public sealed record BackendCannotRewrite(ProviderKind Kind) : RewriteAvailability;

    /// <summary>
    /// A target language is set, so the second stage is a translation. Not a failure and not a
    /// missing backend — the user asked for one job rather than the other.
    /// </summary>
    public sealed record Translating(string Language) : RewriteAvailability;

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
        NoKey => "Add an API key first — without one nothing can run, rewriting included.",
        BackendCannotRewrite cannot =>
            $"{cannot.Kind.PlainName()} only transcribes audio and cannot rewrite text. Add a key "
            + "for a backend that can, and rewriting will use it.",
        Translating translating =>
            $"Dictations are being translated into {translating.Language}, which is the second "
            + "stage. Clear the target language to rewrite instead.",
        _ => string.Empty,
    };

    /// <summary>Resolves against whatever the client uses to store keys.</summary>
    /// <param name="provider">The selected backend.</param>
    /// <param name="hasKey">
    /// Whether a usable key exists for a backend. Passed in rather than read here so the Keychain,
    /// DPAPI and SharedPreferences all answer the same question.
    /// </param>
    /// <param name="translatingInto">
    /// The configured target language, or empty. Checked before the backend questions on purpose:
    /// with a target set the rewrite stage is not going to run whatever the backends can do, and
    /// reporting a key problem for a control that is unavailable for an unrelated reason sends the
    /// user to fix the wrong thing.
    /// </param>
    public static RewriteAvailability Resolve(
        ProviderKind provider, Func<ProviderKind, bool> hasKey, string translatingInto = "")
    {
        var target = TranslationTarget.Sanitized(translatingInto);
        if (target.Length > 0) return new Translating(target);

        // Asked first, and about the selected backend: with no key the dictation itself fails, so a
        // message about rewriting would answer the second question while the first is still wrong.
        if (!hasKey(provider)) return new NoKey();

        if (provider.SupportsTextGeneration()) return new Available();

        // A recogniser with no text endpoint borrows a second stage from another configured
        // backend, which is the behaviour file transcription already had.
        var borrowed = Enum.GetValues<ProviderKind>()
            .Any(kind => kind.SupportsTextGeneration() && hasKey(kind));
        return borrowed ? new Available() : new BackendCannotRewrite(provider);
    }
}
