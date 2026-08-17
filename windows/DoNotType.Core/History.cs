using System.Text;
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
    /// <summary>What to tell the user: one sentence, from <see cref="FailureAdvice"/>.</summary>
    public string? ErrorMessage { get; set; }

    /// <summary>The failure exactly as it arrived, uncut.</summary>
    /// <remarks>
    /// Separate from <see cref="ErrorMessage"/> because the two have different jobs and one string
    /// cannot do both. A list needs a sentence somebody can read at a glance; debugging needs the
    /// status, the whole response body and the exception type, with nothing dropped — a body cut at
    /// 400 characters loses the `param` field that says which part of the request was wrong, and a
    /// half-message pasted into an issue cannot be searched for.
    /// </remarks>
    public string? ErrorDetail { get; set; }
    public string Model { get; set; } = string.Empty;
    public Fidelity Fidelity { get; set; } = Fidelity.Light;
    public string? AppName { get; set; }
    public string? WindowTitle { get; set; }
    public int RetryCount { get; set; }
    public string? AudioFileName { get; set; }

    /// <summary>
    /// Wall clock from the end of speech to text delivered -- what the user actually waits.
    /// </summary>
    /// <remarks>
    /// Measured from key release rather than from the request, because everything in between
    /// (reading the screen, a retry) is time spent watching the overlay. A
    /// figure that excluded it would flatter the app. Null means not measured, which must never
    /// render as zero.
    /// </remarks>
    public double? LatencySeconds { get; set; }

    /// <summary>Time inside the request alone, for telling a slow model from a slow app.</summary>
    public double? RequestSeconds { get; set; }

    /// <summary>Time in the second request, when there was one. Null when nothing was rewritten.</summary>
    /// <remarks>
    /// Separate from <see cref="RequestSeconds"/> so the cost of rewriting is visible on its own.
    /// It is the part somebody turns off when dictation feels slow, and they should be able to see
    /// what turning it off would buy.
    /// </remarks>
    public double? RewriteSeconds { get; set; }

    /// <summary>
    /// The exact context that was sent, so the inspector can show it and a retry can reuse it.
    /// </summary>
    /// <remarks>
    /// <para>
    /// Both halves of that matter. Without it a retry re-runs <em>ungrounded</em> — a different
    /// request from the one that failed, on a row that still names the same provider and model —
    /// and the inspector has nothing to inspect.
    /// </para>
    /// <para>
    /// It is screen contents on disk, so it lives and dies with the row: the retention policy
    /// deletes it along with everything else, and a context that was never captured — grounding
    /// off, or the app on the blocklist — is null here rather than empty.
    /// </para>
    /// </remarks>
    public ScreenContext? Context { get; set; }

    /// <summary>Seconds of speech, for the wait-per-second-spoken figure.</summary>
    public double DurationSeconds { get; set; }

    public int? AudioTokens { get; set; }

    /// <summary>
    /// The derived text, when a mode other than verbatim produced one.
    /// </summary>
    /// <remarks>
    /// Kept beside <see cref="Text"/> rather than replacing it. That separation is the whole
    /// difference from the tool this project replaces: a rewrite or a summary is a derived artifact,
    /// and what you actually said stays recoverable next to it.
    /// </remarks>
    public string? StyledText { get; set; }

    /// <summary>Which mode produced <see cref="StyledText"/>. Null on rows written before modes.</summary>
    public string? Mode { get; set; }

    /// <summary>
    /// The recording this came from, when it was a file rather than the microphone. Its presence is
    /// what distinguishes an offline transcription from a dictation, and both live in the same
    /// history on purpose.
    /// </summary>
    public string? SourceFileName { get; set; }

    [JsonIgnore]
    public bool IsFromFile => SourceFileName is not null;

    /// <summary>What was delivered: the derived text when one exists, otherwise the transcript.</summary>
    [JsonIgnore]
    public string DeliveredText => StyledText ?? Text;

    /// <summary>
    /// The mode, including for rows written before the field existed -- every one of those was a
    /// verbatim dictation, so the reconstruction is exact rather than a guess.
    /// </summary>
    [JsonIgnore]
    public TranscriptMode ResolvedMode => TranscriptMode.Parse(Mode) ?? TranscriptMode.Verbatim;

    [JsonIgnore]
    public bool IsRetryable => Status != DictationStatus.Completed;

    [JsonIgnore]
    public bool CanRetry => IsRetryable && AudioFileName is not null;

    [JsonIgnore]
    public string Summary => Status switch
    {
        DictationStatus.Completed => DeliveredText,
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

    private static readonly Log Log = new("history");

    private readonly string _indexPath = Path.Combine(directory, "history.json");
    private readonly string _temporaryIndexPath = Path.Combine(directory, "history.json.tmp");
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
        lock (_gate) return Loaded().Select(Copy).ToList();
    }

    /// <summary>Everything that failed or never got sent, oldest first — the order to retry in.</summary>
    public IReadOnlyList<DictationRecord> Retryable()
    {
        lock (_gate)
        {
            return Loaded().Where(r => r.CanRetry).OrderBy(r => r.CreatedAt).Select(Copy).ToList();
        }
    }

    public DictationRecord Insert(DictationRecord record, byte[]? audio)
    {
        lock (_gate)
        {
            var records = Loaded();
            var stored = Copy(record);

            // Privacy applies immediately. Keeping a session-only list until exit would make the
            // history view contradict "Don't keep history" even though disk happened to be empty.
            if (_retention == RetentionPolicy.Never)
            {
                Persist();
                return stored;
            }

            // Kept whenever the entry might still need retrying, regardless of the
            // completed-audio setting: without it, Retry cannot work.
            var needsAudio = record.IsRetryable || _keepAudioForCompleted;
            string? writtenAudio = null;
            if (audio is not null && needsAudio)
            {
                var name = $"{stored.Id}.wav";
                var destination = AudioPath(name)!;
                if (WriteAudio(destination, audio))
                {
                    stored.AudioFileName = name;
                    writtenAudio = destination;
                }
            }

            records.Insert(0, stored);
            var persisted = Persist();
            if (!persisted)
            {
                records.RemoveAt(0);
                if (writtenAudio is not null) File.Delete(writtenAudio);
                stored.AudioFileName = null;
            }
            Log.Debug(() => "stored", new Dictionary<string, string>
            {
                ["status"] = stored.Status.ToString().ToLowerInvariant(),
                ["mode"] = stored.ResolvedMode.Id,
                ["audio"] = stored.AudioFileName is null ? "discarded" : "kept",
                ["persisted"] = persisted ? "yes" : "no",
                ["source"] = stored.SourceFileName ?? "microphone",
            });
            return Copy(stored);
        }
    }

    public void Update(DictationRecord record)
    {
        lock (_gate)
        {
            var records = Loaded();
            var index = records.FindIndex(r => r.Id == record.Id);
            if (index < 0) return;
            var previous = records[index];
            var updated = Copy(record);
            var audioNameToRemove = previous.AudioFileName;
            var shouldReleaseAudio =
                updated.Status == DictationStatus.Completed && !_keepAudioForCompleted;

            // A successful retry releases the recording it was holding.
            if (shouldReleaseAudio)
            {
                updated.AudioFileName = null;
            }
            records[index] = updated;
            if (Persist())
            {
                if (shouldReleaseAudio && audioNameToRemove is not null)
                {
                    RemoveAudio(new DictationRecord { AudioFileName = audioNameToRemove });
                }
            }
            else
            {
                records[index] = previous;
            }
        }
    }

    public void Delete(Guid id)
    {
        lock (_gate)
        {
            var records = Loaded();
            var index = records.FindIndex(r => r.Id == id);
            if (index < 0) return;
            var record = records[index];

            records.RemoveAt(index);
            if (Persist())
            {
                RemoveAudio(record);
            }
            else
            {
                records.Insert(index, record);
            }
        }
    }

    public void DeleteAll()
    {
        lock (_gate)
        {
            var records = Loaded();
            var removed = records.ToList();
            records.Clear();
            if (Persist())
            {
                foreach (var record in removed) RemoveAudio(record);
            }
            else
            {
                records.AddRange(removed);
            }
        }
    }

    public long AudioBytes()
    {
        lock (_gate)
        {
            return Loaded()
                .Where(r => r.AudioFileName is not null)
                .Select(r => AudioPath(r.AudioFileName!))
                .Where(path => path is not null)
                .Select(path => new FileInfo(path!))
                .Where(f => f.Exists)
                .Sum(f => f.Length);
        }
    }

    public byte[]? AudioFor(DictationRecord record)
    {
        if (record.AudioFileName is null) return null;
        var path = AudioPath(record.AudioFileName);
        if (path is null) return null;
        return File.Exists(path) ? File.ReadAllBytes(path) : null;
    }

    // MARK: - Private

    /// <summary>History owns its rows; UI code must call <see cref="Update"/> to mutate one.</summary>
    private static DictationRecord Copy(DictationRecord record) =>
        JsonSerializer.Deserialize<DictationRecord>(
            JsonSerializer.Serialize(record, Options), Options)!;

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
            catch (Exception e) when (e is JsonException or IOException or UnauthorizedAccessException)
            {
                // A corrupt index should not stop the app from dictating; it starts fresh.
                _records = [];
                Log.Error(() => "history index is unreadable; leaving it untouched",
                    new Dictionary<string, string> { ["type"] = e.GetType().Name });
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
            var removed = _records.ToList();
            _records.Clear();
            if (Persist())
            {
                foreach (var record in removed) RemoveAudio(record);
            }
            else
            {
                _records.AddRange(removed);
            }
            return;
        }

        var cutoff = DateTimeOffset.Now - maximumAge;
        var expired = _records.Where(r => r.CreatedAt < cutoff).ToList();
        if (expired.Count == 0) return;
        var previous = _records.ToList();

        _records.RemoveAll(r => r.CreatedAt < cutoff);
        if (Persist())
        {
            foreach (var record in expired) RemoveAudio(record);
            // Deleting transcripts is worth a line even when requested: it answers where they went.
            Log.Info(() => "retention pruned history", new Dictionary<string, string>
            {
                ["removed"] = expired.Count.ToString(),
                ["policy"] = _retention.ToString().ToLowerInvariant(),
            });
        }
        else
        {
            _records.Clear();
            _records.AddRange(previous);
        }
    }

    private void RemoveAudio(DictationRecord record)
    {
        if (record.AudioFileName is null) return;
        var path = AudioPath(record.AudioFileName);
        if (path is null) return;
        if (File.Exists(path)) File.Delete(path);
    }

    private bool Persist()
    {
        if (_retention == RetentionPolicy.Never)
        {
            try
            {
                if (File.Exists(_indexPath)) File.Delete(_indexPath);
                if (File.Exists(_temporaryIndexPath)) File.Delete(_temporaryIndexPath);
                return true;
            }
            catch (Exception error)
            {
                Log.Error(() => "could not remove disabled history",
                    new Dictionary<string, string> { ["type"] = error.GetType().Name });
                return false;
            }
        }
        try
        {
            Directory.CreateDirectory(directory);
            var json = JsonSerializer.Serialize(_records, Options);
            // A complete, flushed sibling replaces the live index in one filesystem operation.
            // If the process or machine stops first, the previous JSON remains readable.
            using (var stream = new FileStream(
                _temporaryIndexPath, FileMode.Create, FileAccess.Write, FileShare.None,
                bufferSize: 4096, FileOptions.WriteThrough))
            {
                using (var writer = new StreamWriter(
                    stream, new UTF8Encoding(encoderShouldEmitUTF8Identifier: false),
                    bufferSize: 1024, leaveOpen: true))
                {
                    writer.Write(json);
                    writer.Flush();
                }
                stream.Flush(flushToDisk: true);
            }
            File.Move(_temporaryIndexPath, _indexPath, overwrite: true);
            return true;
        }
        catch (Exception error)
        {
            try { File.Delete(_temporaryIndexPath); } catch (Exception) { }
            Log.Error(() => "could not persist history; the previous index is still intact",
                new Dictionary<string, string> { ["type"] = error.GetType().Name });
            return false;
        }
    }

    /// <summary>Flushes retry audio before the index advertises it.</summary>
    private bool WriteAudio(string destination, byte[] audio)
    {
        try
        {
            Directory.CreateDirectory(_audioDirectory);
            using var stream = new FileStream(
                destination, FileMode.Create, FileAccess.Write, FileShare.None,
                bufferSize: 4096, FileOptions.WriteThrough);
            stream.Write(audio);
            stream.Flush(flushToDisk: true);
            return true;
        }
        catch (Exception error)
        {
            try { File.Delete(destination); } catch (Exception) { }
            Log.Error(() => "could not persist retry audio",
                new Dictionary<string, string> { ["type"] = error.GetType().Name });
            return false;
        }
    }

    /// <summary>A persisted record cannot grant itself authority outside the audio directory.</summary>
    private string? AudioPath(string name)
    {
        if (string.IsNullOrWhiteSpace(name) || Path.IsPathRooted(name)
            || name.IndexOfAny(['/', '\\']) >= 0 || Path.GetFileName(name) != name)
        {
            Log.Warn(() => "ignored an unsafe audio filename in history");
            return null;
        }
        return Path.Combine(_audioDirectory, name);
    }
}
