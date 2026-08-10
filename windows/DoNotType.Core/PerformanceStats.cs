namespace DoNotType.Core;

/// <summary>
/// What the app has actually cost you, computed from the history.
/// </summary>
/// <remarks>
/// A port of <c>PerformanceStats.swift</c>, kept deliberately close to it: the same fields, the
/// same nearest-rank percentile, the same refusal to turn a missing value into a zero. Two
/// platforms reporting different numbers for the same history would make both untrustworthy.
///
/// Median and p95 rather than a mean. A mean is dragged upwards by the one dictation that hit a
/// retry storm, which makes the typical case look worse than it is; p95 is the separate and more
/// useful question of how bad the bad ones get.
/// </remarks>
public sealed class PerformanceStats
{
    public int Total { get; init; }
    public int Completed { get; init; }
    public int Failed { get; init; }
    public int Pending { get; init; }

    /// <summary>Dictations that needed at least one retry -- the honest measure of trouble.</summary>
    public int Retried { get; init; }

    public double? MedianLatency { get; init; }
    public double? P95Latency { get; init; }
    public double? MedianRequest { get; init; }

    public double SpokenSeconds { get; init; }
    public int Words { get; init; }
    public int AudioTokens { get; init; }

    /// <summary>Null rather than zero when nothing is recorded: 0/0 is not a 0% success rate.</summary>
    public double? SuccessRate => Total == 0 ? null : (double)Completed / Total;

    /// <summary>
    /// Wait per second of speech. Below 1.0 means the transcript arrives faster than it took to
    /// say -- the number that decides whether dictation feels immediate or laborious.
    /// </summary>
    public double? RealTimeFactor
    {
        get
        {
            if (MedianLatency is not { } median || SpokenSeconds <= 0 || Completed == 0)
            {
                return null;
            }
            var meanSpoken = SpokenSeconds / Completed;
            return meanSpoken > 0 ? median / meanSpoken : null;
        }
    }

    /// <summary>Typing time saved at a generous 40 wpm. An estimate, and labelled as one.</summary>
    public double EstimatedTypingMinutesSaved => Words / 40.0;

    public static PerformanceStats Compute(IReadOnlyList<DictationRecord> records)
    {
        var completed = 0;
        var failed = 0;
        var pending = 0;
        var retried = 0;
        var spokenSeconds = 0.0;
        var words = 0;
        var audioTokens = 0;
        var latencies = new List<double>();
        var requests = new List<double>();

        foreach (var record in records)
        {
            switch (record.Status)
            {
                case DictationStatus.Completed: completed++; break;
                case DictationStatus.Failed: failed++; break;
                default: pending++; break;
            }
            if (record.RetryCount > 0)
            {
                retried++;
            }

            // Timings only come from successes. A failure's latency measures how long an error took
            // to arrive, which is a different quantity and would poison the median.
            if (record.Status != DictationStatus.Completed)
            {
                continue;
            }

            // A null latency is an unmeasured one -- an old record from before timings existed --
            // and zero means the same thing. Neither is an instant dictation.
            if (record.LatencySeconds is > 0 and var latency)
            {
                latencies.Add(latency);
            }
            if (record.RequestSeconds is > 0 and var request)
            {
                requests.Add(request);
            }
            spokenSeconds += record.DurationSeconds;
            words += record.Text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Length;
            audioTokens += record.AudioTokens ?? 0;
        }

        return new PerformanceStats
        {
            Total = records.Count,
            Completed = completed,
            Failed = failed,
            Pending = pending,
            Retried = retried,
            MedianLatency = Percentile(latencies, 0.5),
            P95Latency = Percentile(latencies, 0.95),
            MedianRequest = Percentile(requests, 0.5),
            SpokenSeconds = spokenSeconds,
            Words = words,
            AudioTokens = audioTokens,
        };
    }

    /// <summary>
    /// Nearest-rank percentile. No interpolation: with the handful of samples a new user has,
    /// interpolating invents precision that is not there.
    /// </summary>
    public static double? Percentile(IReadOnlyList<double> values, double fraction)
    {
        if (values.Count == 0)
        {
            return null;
        }
        var sorted = values.OrderBy(value => value).ToList();
        var rank = (int)Math.Ceiling(fraction * sorted.Count);
        return sorted[Math.Clamp(rank, 1, sorted.Count) - 1];
    }

    /// <summary>"--" rather than "0 s": an unmeasured value must not read as an instant one.</summary>
    public static string FormatDuration(double? seconds)
    {
        if (seconds is not { } value || double.IsNaN(value) || double.IsInfinity(value))
        {
            return "—";
        }
        if (value < 1)
        {
            return $"{value * 1000:F0} ms";
        }
        if (value < 60)
        {
            return $"{value:F1} s";
        }
        var minutes = (int)(value / 60);
        return minutes < 60 ? $"{minutes}m {(int)value % 60}s" : $"{minutes / 60}h {minutes % 60}m";
    }

    public static string FormatCount(int value) =>
        value >= 10_000 ? $"{value / 1000.0:F1}k" : value.ToString("N0");
}

/// <summary>Per-model figures, so switching model shows its effect rather than being believed.</summary>
public sealed record ModelPerformance(string Model, PerformanceStats Stats)
{
    public static IReadOnlyList<ModelPerformance> Breakdown(IReadOnlyList<DictationRecord> records) =>
        records
            .GroupBy(record => record.Model)
            .Select(group => new ModelPerformance(group.Key, PerformanceStats.Compute(group.ToList())))
            // A model tried twice is noise next to one used for a month.
            .OrderByDescending(entry => entry.Stats.Total)
            .ToList();
}
