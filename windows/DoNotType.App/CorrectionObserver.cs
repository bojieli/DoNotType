using DoNotType.Core;

namespace DoNotType.App;

/// <summary>Briefly observes the insertion target for a deliberate spelling correction.</summary>
public sealed class CorrectionObserver : IDisposable
{
    private static readonly TimeSpan Window = TimeSpan.FromMinutes(1);
    private readonly ScreenReader _reader;
    private CancellationTokenSource? _watch;

    public CorrectionObserver(ScreenReader reader) => _reader = reader;

    public void Watch(
        ScreenReader.EditableSnapshot before, string inserted,
        Action<IReadOnlyList<string>> learned)
    {
        _watch?.Cancel();
        _watch?.Dispose();
        _watch = new CancellationTokenSource();
        var token = _watch.Token;
        var prefix = before.Value[..before.SelectionStart];
        var suffix = before.Value[(before.SelectionStart + before.SelectionLength)..];
        var processId = before.ProcessId;
        var runtimeId = before.RuntimeId;

        _ = Task.Run(async () =>
        {
            string? prior = null;
            var stableReads = 0;
            var started = DateTimeOffset.Now;
            while (!token.IsCancellationRequested && DateTimeOffset.Now - started < Window)
            {
                await Task.Delay(TimeSpan.FromMilliseconds(750), token).ConfigureAwait(false);
                var current = _reader.CaptureFocusedEditable();
                if (current is null
                    || current.ProcessId != processId
                    || current.RuntimeId != runtimeId) return;
                if (!TryInsertedSpan(current.Value, prefix, suffix, out var edited)) return;
                if (edited == inserted) { prior = null; stableReads = 0; continue; }

                if (edited == prior) stableReads++;
                else { prior = edited; stableReads = 1; }
                if (stableReads < 2) continue;

                var candidates = PersonalDictionary.LearnedCandidates(inserted, edited);
                if (candidates.Count > 0) learned(candidates);
                return;
            }
        }, token).ContinueWith(_ => { }, TaskScheduler.Default);
    }

    private static bool TryInsertedSpan(string value, string prefix, string suffix, out string span)
    {
        span = string.Empty;
        if (!value.StartsWith(prefix, StringComparison.Ordinal)) return false;
        if (!value.EndsWith(suffix, StringComparison.Ordinal)) return false;
        var end = value.Length - suffix.Length;
        if (end < prefix.Length) return false;
        span = value[prefix.Length..end];
        return true;
    }

    public void Dispose()
    {
        _watch?.Cancel();
        _watch?.Dispose();
    }
}
