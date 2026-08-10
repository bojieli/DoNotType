namespace DoNotType.Core;

/// <summary>
/// Filtering and search over stored dictations.
///
/// In the core rather than in the settings form so that "find that thing I dictated last Tuesday"
/// behaves the same on every platform, and so the matching rules can be tested without a UI.
/// Search is the point of keeping history at all — a log you cannot search is just disk usage.
/// </summary>
public sealed class HistoryQuery
{
    public enum StatusFilter
    {
        All,
        Completed,
        NeedsAttention,
    }

    public string Text { get; set; } = string.Empty;
    public StatusFilter Status { get; set; } = StatusFilter.All;
    public string? AppName { get; set; }
    public DateTimeOffset? Since { get; set; }

    public bool IsEmpty =>
        string.IsNullOrWhiteSpace(Text) && Status == StatusFilter.All
        && AppName is null && Since is null;

    /// <summary>Applies the filters, newest first.</summary>
    public IReadOnlyList<DictationRecord> Apply(IEnumerable<DictationRecord> records)
    {
        var needle = Text.Trim();

        return records
            .Where(r => Status switch
            {
                StatusFilter.Completed => r.Status == DictationStatus.Completed,
                StatusFilter.NeedsAttention => r.Status != DictationStatus.Completed,
                _ => true,
            })
            .Where(r => AppName is null || r.AppName == AppName)
            .Where(r => Since is null || r.CreatedAt >= Since)
            .Where(r => needle.Length == 0 || Matches(r, needle))
            .OrderByDescending(r => r.CreatedAt)
            .ToList();
    }

    /// <summary>
    /// Error text is searched as well as the transcript: when you are hunting a failure, the
    /// message is what you remember — the transcript is empty.
    /// </summary>
    internal static bool Matches(DictationRecord record, string needle) =>
        new[] { record.Text, record.ErrorMessage ?? string.Empty,
                record.AppName ?? string.Empty, record.WindowTitle ?? string.Empty }
            .Any(haystack => haystack.Contains(needle, StringComparison.OrdinalIgnoreCase));

    /// <summary>Apps present in the history, for populating a filter control.</summary>
    public static IReadOnlyList<string> AppNames(IEnumerable<DictationRecord> records) =>
        records.Select(r => r.AppName)
            .Where(name => !string.IsNullOrEmpty(name))
            .Select(name => name!)
            .Distinct()
            .OrderBy(name => name)
            .ToList();
}
