using DoNotType.Core;

namespace DoNotType.App;

/// <summary>
/// Remembers the last thing inserted, so it can be taken back.
/// </summary>
/// <remarks>
/// This is the feature the project's whole design makes cheap. The verbatim transcript is stored
/// before anything is done to it, so "that came out wrong" or "that rewrite was too formal" is a
/// key press rather than a retype. A tool that discards what you said cannot offer this at all,
/// which is precisely the difference being argued.
/// </remarks>
public sealed class InsertionTracker
{
    /// <param name="Delivered">What was actually put into the field.</param>
    /// <param name="Verbatim">
    /// The verbatim transcript, which differs from <paramref name="Delivered"/> when a rewrite was
    /// applied.
    /// </param>
    public sealed record Insertion(Guid RecordId, string Delivered, string Verbatim, DateTimeOffset At)
    {
        /// <summary>True when reverting would produce different text.</summary>
        public bool HasVerbatimAlternative => Delivered != Verbatim;
    }

    /// <summary>
    /// How long an insertion stays revertible.
    /// </summary>
    /// <remarks>
    /// Not forever: deleting characters from a field the user has since moved away from would
    /// destroy unrelated text. A minute covers "that's wrong, undo it" and expires long before the
    /// caret has plausibly moved somewhere dangerous.
    /// </remarks>
    private static readonly TimeSpan Window = TimeSpan.FromMinutes(1);

    public Insertion? Last { get; private set; }

    public bool CanUndo => Last is not null && DateTimeOffset.Now - Last.At < Window;

    public bool CanRevertToVerbatim => CanUndo && Last?.HasVerbatimAlternative == true;

    public void Record(Guid recordId, string delivered, string verbatim) =>
        Last = new Insertion(recordId, delivered, verbatim, DateTimeOffset.Now);

    public void Clear() => Last = null;

    /// <summary>Deletes the inserted text, optionally replacing it with the verbatim version.</summary>
    public async Task<bool> UndoAsync(bool replacingWithVerbatim, string dictation = "-")
    {
        if (Last is not { } insertion || !CanUndo) return false;
        Last = null;

        TextInjector.DeleteBackward(insertion.Delivered.Length, dictation);
        if (replacingWithVerbatim && insertion.HasVerbatimAlternative)
        {
            await TextInjector.InsertAsync(insertion.Verbatim, dictation).ConfigureAwait(false);
            // The verbatim text is now what is in the field, so undoing again should remove it
            // rather than swapping back and forth.
            Last = new Insertion(
                insertion.RecordId, insertion.Verbatim, insertion.Verbatim, DateTimeOffset.Now);
        }
        return true;
    }
}
