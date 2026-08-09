using System.Text.Json;
using System.Text.Json.Serialization;

namespace DoNotType.Core;

public enum DictationStatus
{
    Completed,
    Failed,
    Pending,
}

/// <summary>
/// One dictation, and everything needed to try it again.
///
/// Retry is why this holds more than text. A dictation that failed because the network dropped is
/// not lost work — the recording is still on disk, so the request can be reissued. That means
/// audio retention is not purely a privacy setting: a failed entry keeps its audio until it
/// succeeds, or Retry is a button that cannot work.
/// </summary>
public sealed class DictationRecord
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.Now;
    public DictationStatus Status { get; set; } = DictationStatus.Pending;
    public string Text { get; set; } = string.Empty;
    public string? ErrorMessage { get; set; }
    public string Model { get; set; } = string.Empty;
    public Fidelity Fidelity { get; set; } = Fidelity.Light;
    public string? AppName { get; set; }
    public string? WindowTitle { get; set; }
    public int RetryCount { get; set; }
    public string? AudioFileName { get; set; }

    [JsonIgnore]
    public bool IsRetryable => Status != DictationStatus.Completed;

    [JsonIgnore]
    public bool CanRetry => IsRetryable && AudioFileName is not null;

    [JsonIgnore]
    public string Summary => Status switch
    {
        DictationStatus.Completed => Text,
        DictationStatus.Failed => ErrorMessage ?? "Failed",
        _ => "Waiting to send",
    };
}

public enum RetentionPolicy
{
    Never,
    OneDay,
    OneWeek,
    OneMonth,
    Forever,
}

public static class RetentionPolicyExtensions
{
    public static string Label(this RetentionPolicy policy) => policy switch
    {
        RetentionPolicy.Never => "Don't keep history",
        RetentionPolicy.OneDay => "24 hours",
        RetentionPolicy.OneWeek => "1 week",
        RetentionPolicy.OneMonth => "1 month",
        _ => "Forever",
    };

    public static TimeSpan? MaximumAge(this RetentionPolicy policy) => policy switch
    {
        RetentionPolicy.Never => TimeSpan.Zero,
        RetentionPolicy.OneDay => TimeSpan.FromDays(1),
        RetentionPolicy.OneWeek => TimeSpan.FromDays(7),
        RetentionPolicy.OneMonth => TimeSpan.FromDays(30),
        _ => null,
    };
}

/// <summary>
/// Persists dictations and the audio needed to retry them.
///
/// A JSON index plus an audio/ directory, mirroring the other platforms. A database would be the
/// reflex, but the access pattern is "load a few hundred rows at startup, append one at a time",
/// and deleting your history should be something you can verify in Explorer.
/// </summary>
public sealed class HistoryStore(string directory)
{
    private static readonly JsonSerializerOptions Options = new()
    {
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter() },
    };

    private readonly string _indexPath = Path.Combine(directory, "history.json");
    private readonly string _audioDirectory = Path.Combine(directory, "audio");
    private readonly Lock _gate = new();

    private List<DictationRecord>? _records;
    private RetentionPolicy _retention = RetentionPolicy.Forever;
    private bool _keepAudioForCompleted;

    public static string DefaultDirectory() => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "DoNotType");

    public void Configure(RetentionPolicy retention, bool keepAudioForCompleted)
    {
        lock (_gate)
        {
            _retention = retention;
            _keepAudioForCompleted = keepAudioForCompleted;
            _records = null; // reapply retention on next read
        }
    }

    public IReadOnlyList<DictationRecord> All()
    {
        lock (_gate) return Loaded().ToList();
    }

    /// <summary>Everything that failed or never got sent, oldest first — the order to retry in.</summary>
    public IReadOnlyList<DictationRecord> Retryable()
    {
        lock (_gate) return Loaded().Where(r => r.CanRetry).OrderBy(r => r.CreatedAt).ToList();
    }

    public DictationRecord Insert(DictationRecord record, byte[]? audio)
    {
        lock (_gate)
        {
            var records = Loaded();

            // Kept whenever the entry might still need retrying, regardless of the
            // completed-audio setting: without it, Retry cannot work.
            var needsAudio = record.IsRetryable || _keepAudioForCompleted;
            if (audio is not null && needsAudio && _retention != RetentionPolicy.Never)
            {
                Directory.CreateDirectory(_audioDirectory);
                var name = $"{record.Id}.wav";
                File.WriteAllBytes(Path.Combine(_audioDirectory, name), audio);
                record.AudioFileName = name;
            }
            else
            {
                record.AudioFileName = null;
            }

            records.Insert(0, record);
            Persist();
            return record;
        }
    }

    public void Update(DictationRecord record)
    {
        lock (_gate)
        {
            var records = Loaded();
            var index = records.FindIndex(r => r.Id == record.Id);
            if (index < 0) return;

            // A successful retry releases the recording it was holding.
            if (record.Status == DictationStatus.Completed && !_keepAudioForCompleted)
            {
                RemoveAudio(record);
                record.AudioFileName = null;
            }
            records[index] = record;
            Persist();
        }
    }

    public void Delete(Guid id)
    {
        lock (_gate)
        {
            var records = Loaded();
            var record = records.FirstOrDefault(r => r.Id == id);
            if (record is null) return;

            RemoveAudio(record);
            records.Remove(record);
            Persist();
        }
    }

    public void DeleteAll()
    {
        lock (_gate)
        {
            var records = Loaded();
            foreach (var record in records) RemoveAudio(record);
            records.Clear();
            Persist();
        }
    }

    public long AudioBytes()
    {
        lock (_gate)
        {
            return Loaded()
                .Where(r => r.AudioFileName is not null)
                .Select(r => new FileInfo(Path.Combine(_audioDirectory, r.AudioFileName!)))
                .Where(f => f.Exists)
                .Sum(f => f.Length);
        }
    }

    public byte[]? AudioFor(DictationRecord record)
    {
        if (record.AudioFileName is null) return null;
        var path = Path.Combine(_audioDirectory, record.AudioFileName);
        return File.Exists(path) ? File.ReadAllBytes(path) : null;
    }

    // MARK: - Private

    private List<DictationRecord> Loaded()
    {
        if (_records is not null) return _records;

        _records = [];
        if (File.Exists(_indexPath))
        {
            try
            {
                _records = JsonSerializer.Deserialize<List<DictationRecord>>(
                    File.ReadAllText(_indexPath), Options) ?? [];
            }
            catch (Exception e) when (e is JsonException or IOException)
            {
                // A corrupt index should not stop the app from dictating; it starts fresh.
                _records = [];
            }
        }
        ApplyRetention();
        return _records;
    }

    private void ApplyRetention()
    {
        if (_retention.MaximumAge() is not { } maximumAge || _records is null) return;

        if (maximumAge == TimeSpan.Zero)
        {
            foreach (var record in _records) RemoveAudio(record);
            _records.Clear();
            Persist();
            return;
        }

        var cutoff = DateTimeOffset.Now - maximumAge;
        var expired = _records.Where(r => r.CreatedAt < cutoff).ToList();
        if (expired.Count == 0) return;

        foreach (var record in expired) RemoveAudio(record);
        _records.RemoveAll(r => r.CreatedAt < cutoff);
        Persist();
    }

    private void RemoveAudio(DictationRecord record)
    {
        if (record.AudioFileName is null) return;
        var path = Path.Combine(_audioDirectory, record.AudioFileName);
        if (File.Exists(path)) File.Delete(path);
    }

    private void Persist()
    {
        if (_retention == RetentionPolicy.Never)
        {
            if (File.Exists(_indexPath)) File.Delete(_indexPath);
            return;
        }
        Directory.CreateDirectory(directory);
        File.WriteAllText(_indexPath, JsonSerializer.Serialize(_records, Options));
    }
}
