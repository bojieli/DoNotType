using System.Globalization;
using System.Text;

namespace DoNotType.Core;

/// <summary>
/// Structured logging, ported from the Swift core so the four platforms produce comparable output.
/// </summary>
/// <remarks>
/// <para>
/// The tray app had no logging at all beyond exception text in a message box, which meant the first
/// question of every transcription bug report -- what did the app send, and what came back? -- could
/// only be answered with a proxy or a rebuild. Four things are needed to answer it and none of them
/// existed: a level you can turn up, a file you can attach to an issue, anything at all from inside
/// the core, and a redaction rule that makes the first three safe to share.
/// </para>
/// <para>
/// The privacy rule is enforced rather than documented. Transcripts and screen contents are
/// <em>content</em>, and content is never written unless the user turns it on: a line records that a
/// 412-character transcript came back, not what it said. <see cref="Log.Content"/> is the one door
/// and it is closed by default.
/// </para>
/// </remarks>
public enum LogLevel
{
    /// <summary>Per-chunk, per-retry detail. Verbose enough to read a whole dictation from.</summary>
    Trace = 0,

    /// <summary>The decisions: which route, which backend, how big, how long.</summary>
    Debug = 1,

    /// <summary>One line per meaningful event. The default.</summary>
    Info = 2,

    /// <summary>Something degraded but recovered -- a fallback fired, an encoder was missing.</summary>
    Warn = 3,

    /// <summary>Something failed and the user noticed.</summary>
    Error = 4,

    /// <summary>Nothing at all.</summary>
    Off = 5,
}

public static class LogLevelExtensions
{
    public static string Id(this LogLevel level) => level switch
    {
        LogLevel.Trace => "trace",
        LogLevel.Debug => "debug",
        LogLevel.Info => "info",
        LogLevel.Warn => "warn",
        LogLevel.Error => "error",
        _ => "off",
    };

    /// <summary>Accepts the spellings people actually type, including "warning" and "silent".</summary>
    public static LogLevel? Parse(string? id) => id?.Trim().ToLowerInvariant() switch
    {
        "trace" or "verbose" => LogLevel.Trace,
        "debug" => LogLevel.Debug,
        "info" or "default" => LogLevel.Info,
        "warn" or "warning" => LogLevel.Warn,
        "error" or "err" => LogLevel.Error,
        "off" or "none" or "silent" or "quiet" => LogLevel.Off,
        _ => null,
    };

    public static string Describe(this LogLevel level) => level switch
    {
        LogLevel.Trace => "Everything (trace)",
        LogLevel.Debug => "Requests and decisions (debug)",
        LogLevel.Info => "Normal (info)",
        LogLevel.Warn => "Warnings only",
        LogLevel.Error => "Errors only",
        _ => "Nothing",
    };
}

/// <summary>One line in the log.</summary>
public sealed record LogEvent(
    long Id,
    DateTimeOffset Timestamp,
    LogLevel Level,
    string Category,
    string Message,
    IReadOnlyDictionary<string, string> Fields)
{
    /// <summary>`12:04:31.512 INFO  dictation    transcribed  chars=142 ms=980`</summary>
    /// <summary>A field value, kept whole and kept on one line.</summary>
    /// <remarks>
    /// Escaped rather than shortened. A response body belongs in the log in full — it is the thing
    /// somebody is reading the log to see — but a raw newline inside it would split one entry into
    /// several, and every line after the first would have no timestamp, level or category. A grep
    /// would then find a fragment and show it without the message it belongs to.
    /// </remarks>
    private static string Flatten(string value) =>
        value.Replace("\\", "\\\\").Replace("\n", "\\n").Replace("\r", "\\r")
            .Replace("\"", "\\\"");

    public string Render(bool includeTime = true)
    {
        var builder = new StringBuilder();
        if (includeTime)
        {
            builder.Append(Timestamp.ToString("HH:mm:ss.fff", CultureInfo.InvariantCulture)).Append(' ');
        }
        builder.Append(Level.Id().ToUpperInvariant().PadRight(5)).Append(' ');
        builder.Append(Category.PadRight(12)).Append(' ');
        builder.Append(Message);

        if (Fields.Count > 0)
        {
            builder.Append("  ");
            builder.Append(string.Join(" ", Fields.Keys.OrderBy(k => k, StringComparer.Ordinal)
                .Select(key =>
                {
                    var value = Flatten(Fields[key]);
                    return value.Contains(' ') || value.Length == 0 ? $"{key}=\"{value}\"" : $"{key}={value}";
                })));
        }
        return builder.ToString();
    }
}

/// <summary>Somewhere a log line goes.</summary>
public interface ILogSink
{
    void Write(LogEvent entry);
    void Flush() { }
}

/// <summary>
/// The one place a log line passes through: filters by level, redacts, fans out to sinks, and keeps
/// the last few thousand events in memory for the settings window.
/// </summary>
/// <remarks>
/// A lock rather than an async queue. Logging has to be callable from a Win32 hook callback and
/// from a <c>finally</c> block without awaiting anything, and a logger you cannot call from the hot
/// path is one nobody calls.
/// </remarks>
public static class LogRouter
{
    private static readonly Lock Gate = new();
    private static readonly List<LogEvent> Buffer = [];
    private static readonly List<string> Secrets = [];

    private static LogLevel _level = LogLevel.Info;
    private static IReadOnlyList<ILogSink> _sinks = [];
    /// <summary>
    /// How many events the in-memory ring keeps for the log viewer. Fixed rather than configurable:
    /// it is a debugging aid, and the only honest answers are "enough to see what just happened"
    /// and "not enough to matter", which this is both of.
    /// </summary>
    private const int Capacity = 5_000;
    private static long _nextId = 1;
    private static bool _contentAllowed;
    private static string? _file;

    /// <summary>How the process wants to log.</summary>
    public sealed record Configuration
    {
        public LogLevel Level { get; init; } = LogLevel.Info;

        /// <summary>Where to append. Null disables file logging.</summary>
        public string? FilePath { get; init; }

        public bool WritesToStandardError { get; init; }

        /// <summary>Whether transcripts and screen text may be written. Off unless asked for.</summary>
        public bool IncludesContent { get; init; }

        public long MaximumFileBytes { get; init; } = 8L * 1024 * 1024;

        /// <summary>
        /// What a tray app wants: a file it can be asked for, and nothing on stderr because there
        /// is no console attached to a WinExe.
        /// </summary>
        public static Configuration App(string directory) => new()
        {
            FilePath = Path.Combine(directory, "donottype.log"),
        };

        /// <summary>
        /// What a command-line tool wants: stderr, so stdout stays a clean transcript, and no file
        /// unless one is asked for -- two processes appending would interleave and race rotation.
        /// </summary>
        public static Configuration CommandLine(LogLevel level = LogLevel.Warn) => new()
        {
            Level = level,
            WritesToStandardError = true,
        };

        /// <summary>
        /// Environment overrides, documented in docs/CLI.md and honoured by every executable:
        /// DNT_LOG_LEVEL, DNT_LOG_FILE, DNT_LOG_STDERR, DNT_LOG_CONTENT.
        /// </summary>
        public Configuration ApplyingEnvironment(IDictionary<string, string?>? environment = null)
        {
            string? Read(string name) => environment is null
                ? Environment.GetEnvironmentVariable(name)
                : environment.TryGetValue(name, out var value) ? value : null;

            var copy = this;
            if (LogLevelExtensions.Parse(Read("DNT_LOG_LEVEL")) is { } level)
            {
                copy = copy with { Level = level };
            }
            if (Read("DNT_LOG_FILE")?.Trim() is { Length: > 0 } path)
            {
                copy = copy with
                {
                    FilePath = path.ToLowerInvariant() is "none" or "off" or "no" or "0" ? null : path,
                };
            }
            if (Read("DNT_LOG_STDERR") is { } stderr)
            {
                copy = copy with { WritesToStandardError = IsTruthy(stderr) };
            }
            if (Read("DNT_LOG_CONTENT") is { } content)
            {
                copy = copy with { IncludesContent = IsTruthy(content) };
            }
            return copy;
        }

        private static bool IsTruthy(string value) =>
            value.Trim().ToLowerInvariant() is "1" or "true" or "yes" or "on";
    }

    /// <summary>
    /// Installs a configuration, replacing whatever was there.
    /// </summary>
    /// <param name="applyEnvironment">
    /// Whether DNT_LOG_* overrides this configuration. Callers that already merged the environment
    /// with their own flags pass false, because applying it twice would let DNT_LOG_LEVEL win over
    /// an explicitly typed --log-level.
    /// </param>
    public static Configuration Bootstrap(Configuration configuration, bool applyEnvironment = true)
    {
        var resolved = applyEnvironment ? configuration.ApplyingEnvironment() : configuration;
        var built = new List<ILogSink>();
        if (resolved.WritesToStandardError) built.Add(new StandardErrorLogSink());
        if (resolved.FilePath is { } path && FileLogSink.TryCreate(path, resolved.MaximumFileBytes) is { } file)
        {
            built.Add(file);
        }

        lock (Gate)
        {
            _level = resolved.Level;
            _sinks = built;
            _contentAllowed = resolved.IncludesContent;
            _file = resolved.FilePath;
            Trim();
        }
        return resolved;
    }

    public static void SetLevel(LogLevel level)
    {
        lock (Gate) _level = level;
    }

    public static LogLevel CurrentLevel
    {
        get { lock (Gate) return _level; }
    }

    public static bool IncludesContent
    {
        get { lock (Gate) return _contentAllowed; }
    }

    public static void SetIncludesContent(bool allowed)
    {
        lock (Gate) _contentAllowed = allowed;
    }

    /// <summary>The file being appended to, for the settings window and `dnt logs --path`.</summary>
    public static string? FilePath
    {
        get { lock (Gate) return _file; }
    }

    /// <summary>
    /// Registers a value that must never appear in a log line, whatever route it takes there.
    /// </summary>
    /// <remarks>
    /// Pattern matching alone is not enough: a key echoed back inside a provider's error body does
    /// not look like a key by the time it arrives here. The app registers every configured key at
    /// startup, so the exact bytes are known.
    /// </remarks>
    public static void Redact(string? secret)
    {
        var trimmed = secret?.Trim() ?? string.Empty;
        if (trimmed.Length < 8) return;
        lock (Gate)
        {
            if (!Secrets.Contains(trimmed)) Secrets.Add(trimmed);
        }
    }

    public static bool IsEnabled(LogLevel candidate)
    {
        lock (Gate) return _level != LogLevel.Off && candidate >= _level;
    }

    public static void Emit(
        LogLevel level, string category, string message, IReadOnlyDictionary<string, string>? fields)
    {
        LogEvent entry;
        IReadOnlyList<ILogSink> targets;

        lock (Gate)
        {
            if (_level == LogLevel.Off || level < _level) return;

            var known = Secrets.ToList();
            entry = new LogEvent(
                _nextId++,
                DateTimeOffset.Now,
                level,
                category,
                Redaction.Scrub(message, known),
                (fields ?? new Dictionary<string, string>())
                    .ToDictionary(pair => pair.Key, pair => Redaction.Scrub(pair.Value, known)));

            Buffer.Add(entry);
            Trim();
            targets = _sinks;
        }

        foreach (var sink in targets) sink.Write(entry);
    }

    /// <summary>Newest last, filtered. A copy, so the UI never holds the lock.</summary>
    public static IReadOnlyList<LogEvent> Recent(
        int limit = 500, LogLevel minimumLevel = LogLevel.Trace, string containing = "")
    {
        List<LogEvent> snapshot;
        lock (Gate) snapshot = Buffer.ToList();

        var needle = containing.Trim();
        var matches = snapshot.Where(entry =>
            entry.Level >= minimumLevel &&
            (needle.Length == 0 ||
             entry.Message.Contains(needle, StringComparison.OrdinalIgnoreCase) ||
             entry.Category.Contains(needle, StringComparison.OrdinalIgnoreCase) ||
             entry.Fields.Any(field =>
                 field.Key.Contains(needle, StringComparison.OrdinalIgnoreCase) ||
                 field.Value.Contains(needle, StringComparison.OrdinalIgnoreCase))));

        return matches.TakeLast(limit).ToList();
    }

    /// <summary>Monotonic count, so a viewer can tell whether anything changed without diffing.</summary>
    public static long EmittedCount
    {
        get { lock (Gate) return _nextId - 1; }
    }

    public static void ClearBuffer()
    {
        lock (Gate) Buffer.Clear();
    }

    public static void Flush()
    {
        IReadOnlyList<ILogSink> targets;
        lock (Gate) targets = _sinks;
        foreach (var sink in targets) sink.Flush();
    }

    /// <summary>Test seam: swap the sinks for one that records, without touching the file.</summary>
    public static void Install(IReadOnlyList<ILogSink> sinks, LogLevel level = LogLevel.Trace)
    {
        lock (Gate)
        {
            _sinks = sinks;
            _level = level;
            _file = null;
            _contentAllowed = false;
            Secrets.Clear();
            Buffer.Clear();
        }
    }

    private static void Trim()
    {
        if (Buffer.Count > Capacity) Buffer.RemoveRange(0, Buffer.Count - Capacity);
    }
}

/// <summary>
/// A category handle, held as a field on the type that logs.
/// </summary>
/// <remarks>
/// The message is a delegate so that building it costs nothing when the level is off, which is what
/// makes it reasonable to leave trace calls in hot paths permanently.
/// </remarks>
public sealed class Log(string category)
{
    public void Trace(Func<string> message, IReadOnlyDictionary<string, string>? fields = null) =>
        Write(LogLevel.Trace, message, fields);

    public void Debug(Func<string> message, IReadOnlyDictionary<string, string>? fields = null) =>
        Write(LogLevel.Debug, message, fields);

    public void Info(Func<string> message, IReadOnlyDictionary<string, string>? fields = null) =>
        Write(LogLevel.Info, message, fields);

    public void Warn(Func<string> message, IReadOnlyDictionary<string, string>? fields = null) =>
        Write(LogLevel.Warn, message, fields);

    public void Error(Func<string> message, IReadOnlyDictionary<string, string>? fields = null) =>
        Write(LogLevel.Error, message, fields);

    /// <summary>
    /// The user's words, or their screen. The size is always logged; the text only when the user
    /// has turned content logging on.
    /// </summary>
    public void Content(string message, Func<string> text, LogLevel level = LogLevel.Debug)
    {
        if (!LogRouter.IsEnabled(level)) return;
        var value = text();
        var fields = new Dictionary<string, string> { ["chars"] = value.Length.ToString() };
        if (LogRouter.IncludesContent) fields["text"] = value;
        LogRouter.Emit(level, category, message, fields);
    }

    private void Write(
        LogLevel level, Func<string> message, IReadOnlyDictionary<string, string>? fields)
    {
        if (!LogRouter.IsEnabled(level)) return;
        LogRouter.Emit(level, category, message(), fields);
    }
}

/// <summary>
/// Appends to a file, rotating once it gets big. One previous generation is kept: two is not
/// obviously better, and "the log ate the disk" is a real way for a tray app to ruin someone's day.
/// </summary>
public sealed class FileLogSink : ILogSink
{
    private readonly Lock _gate = new();
    private readonly string _path;
    private readonly long _maximumBytes;
    private long _written;

    private FileLogSink(string path, long maximumBytes)
    {
        _path = path;
        _maximumBytes = maximumBytes;
        _written = File.Exists(path) ? new FileInfo(path).Length : 0;
    }

    public static FileLogSink? TryCreate(string path, long maximumBytes)
    {
        try
        {
            var directory = Path.GetDirectoryName(path);
            if (!string.IsNullOrEmpty(directory)) Directory.CreateDirectory(directory);
            if (!File.Exists(path)) File.WriteAllText(path, string.Empty);
            return new FileLogSink(path, maximumBytes);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            // A log that cannot be written must never stop the app that was trying to write it.
            return null;
        }
    }

    public void Write(LogEvent entry)
    {
        var line = entry.Render() + Environment.NewLine;
        lock (_gate)
        {
            try
            {
                File.AppendAllText(_path, line);
                _written += line.Length;
                if (_written > _maximumBytes) Rotate();
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                // Same reasoning as above.
            }
        }
    }

    private void Rotate()
    {
        var previous = _path + ".1";
        if (File.Exists(previous)) File.Delete(previous);
        File.Move(_path, previous);
        File.WriteAllText(_path, string.Empty);
        _written = 0;
    }
}

/// <summary>stderr, so stdout stays a clean transcript that can be piped into a file.</summary>
public sealed class StandardErrorLogSink : ILogSink
{
    private readonly Lock _gate = new();

    public void Write(LogEvent entry)
    {
        // Time only, no date: a CLI invocation does not run across midnight and the date is column
        // noise in front of every line.
        lock (_gate) Console.Error.WriteLine(entry.Render(includeTime: false));
    }
}

/// <summary>Collects events in memory. For tests, and for anything that wants no file.</summary>
public sealed class MemoryLogSink : ILogSink
{
    private readonly Lock _gate = new();
    private readonly List<LogEvent> _events = [];

    public void Write(LogEvent entry)
    {
        lock (_gate) _events.Add(entry);
    }

    public IReadOnlyList<LogEvent> Events
    {
        get { lock (_gate) return _events.ToList(); }
    }
}

/// <summary>
/// Keeps secrets out of a log that exists to be pasted into an issue.
/// </summary>
/// <remarks>
/// Two mechanisms, because either alone leaks. Registered secrets catch the key this app is using
/// wherever it turns up, including inside a URL or a provider's own error message echoing it back.
/// Pattern matching catches a key belonging to something else that this process was never told
/// about.
/// </remarks>
public static class Redaction
{
    /// <summary>Prefixes that mean "the rest of this token is a credential", whatever its length.</summary>
    private static readonly string[] SecretPrefixes =
        ["sk-", "sk_", "AIza", "xai-", "gsk_", "dg_", "pk_", "ghp_"];

    /// <summary>A run of opaque token characters this long is not a word in any language.</summary>
    private const int OpaqueLength = 32;

    public static string Scrub(string text, IReadOnlyList<string> secrets)
    {
        var result = text;
        // Longest first, so a key containing another registered value still masks fully.
        foreach (var secret in secrets.Where(s => s.Length > 0).OrderByDescending(s => s.Length))
        {
            result = result.Replace(secret, Mask(secret), StringComparison.Ordinal);
        }
        return ScrubPatterns(result);
    }

    public static string Mask(string secret) => $"‹redacted {secret.Length}-char secret›";

    /// <summary>
    /// Walks token runs and masks anything credential-shaped. Hand-rolled rather than a regular
    /// expression so the behaviour is obvious from reading it -- this runs on every log line.
    /// </summary>
    public static string ScrubPatterns(string text)
    {
        var output = new StringBuilder();
        var token = new StringBuilder();

        void Flush()
        {
            output.Append(LooksSecret(token.ToString()) ? "‹redacted›" : token);
            token.Clear();
        }

        foreach (var character in text)
        {
            if (char.IsLetterOrDigit(character) || character is '-' or '_' or '.')
            {
                token.Append(character);
            }
            else
            {
                Flush();
                output.Append(character);
            }
        }
        Flush();
        return output.ToString();
    }

    public static bool LooksSecret(string token)
    {
        if (token.Length < 12) return false;
        if (SecretPrefixes.Any(prefix =>
                token.StartsWith(prefix, StringComparison.Ordinal) && token.Length > prefix.Length + 6))
        {
            return true;
        }
        if (token.Length < OpaqueLength) return false;

        // Opaque means no separators, with digits and letters mixed -- enough to exclude a long
        // identifier from a stack trace and include a base64-ish key.
        var hasDigit = token.Any(char.IsDigit);
        var hasLetter = token.Any(char.IsLetter);
        var hasSeparator = token.Any(c => c is '.' or '-' or '_');
        return hasDigit && hasLetter && !hasSeparator;
    }
}
