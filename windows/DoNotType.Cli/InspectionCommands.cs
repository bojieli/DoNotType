using System.Text.Json;
using System.Text.Json.Serialization;
using DoNotType.Core;

namespace DoNotType.Cli;

/// <summary>
/// Lists the backends and what each one can actually do here.
/// </summary>
/// <remarks>
/// The capability column is the point. Three of these five are not language models, which decides
/// whether screen grounding, rewriting and summarising work at all — and that difference is
/// invisible from the provider name.
/// </remarks>
public static class ProvidersCommand
{
    public static int Run(Arguments arguments)
    {
        var stored = !arguments.Flag("no-stored-key");
        var selected = Preferences.Provider;

        Out.Line("   backend      key                          model                     capability");
        foreach (var kind in Enum.GetValues<ProviderKind>())
        {
            var key = Preferences.ResolveKey(kind, stored)?.Source ?? "— not set";
            var marker = kind == selected ? " → " : "   ";
            Out.Line(
                marker
                + Pad(kind.ToString().ToLowerInvariant(), 12)
                + Pad(key, 29)
                + Pad(Preferences.Model(kind), 26)
                + (kind.IsSpeechRecognition()
                    ? "transcription only"
                    : "model — grounding, rewrite, summary"));
        }

        Out.Line(string.Empty);
        Out.Line(Preferences.IsAvailable
            ? "→ marks the backend the app is set to. Override with --provider."
            : "No settings file found, so → is the fresh-install default.");
        Out.Line("Recognition backends cannot rewrite or summarise; pair one with --text-provider.");
        return 0;
    }

    internal static string Pad(string value, int width) =>
        value.Length >= width ? value[..Math.Max(0, width - 2)] + "… " : value.PadRight(width);
}

/// <summary>
/// Answers "why is this not working" without opening the app or reading the source.
/// </summary>
public static class DoctorCommand
{
    public static async Task<int> RunAsync(Arguments arguments)
    {
        var problems = new List<string>();
        void Row(string name, string value) => Out.Line($"  {ProvidersCommand.Pad(name, 22)}{value}");
        void Bad(string name, string value)
        {
            Row(name, value);
            problems.Add($"{name}: {value}");
        }

        Out.Line("DoNotType — dnt 1.0.0");

        Out.Line("\nEnvironment");
        Row("os", Environment.OSVersion.VersionString);
        Row("opus encoder", OpusEncoder.IsAvailable ? "available" : "UNAVAILABLE — uploads as WAV");
        Row("app settings", Preferences.IsAvailable
            ? Path.Combine(Preferences.Directory, "settings.json")
            : "none stored — using fresh-install defaults");
        Row("audio formats", AudioDecoder.SupportedFormats);
        Row("opus decoder", OpusEncoder.IsAvailable ? "libopus" : "UNAVAILABLE — .opus will fail");

        Out.Line("\nLogging");
        Row("level", LogRouter.CurrentLevel.Id());
        Row("file", LogRouter.FilePath ?? "none for this process");
        var appLog = Path.Combine(Preferences.Directory, "logs", "donottype.log");
        Row("app log", File.Exists(appLog)
            ? $"{appLog} ({new FileInfo(appLog).Length / 1024} KB)"
            : "not written yet");
        Row("content logging", LogRouter.IncludesContent ? "ON — transcripts are logged" : "off");

        Out.Line("\nPrompt");
        try
        {
            var path = arguments.ResolvePromptPath();
            Row("shipped", path);
            var builder = arguments.ResolvePrompt();
            builder.SystemInstruction(arguments.ResolveFidelity());
            Row("system block", "ok");
            Row("summary block",
                builder.SupportsSecondStage(TranscriptMode.Summary(SummaryStyle.Brief))
                    ? "ok"
                    : "MISSING — summaries will fail");
        }
        catch (Exception e) when (e is UsageException or InvalidOperationException or IOException)
        {
            Bad("prompt", e.Message);
        }
        var store = new PromptStore(Preferences.Directory);
        Row("custom copy", store.HasCustomPrompt ? $"yes — {store.CustomPath}" : "no");

        Out.Line("\nHistory");
        var history = new HistoryStore(Preferences.Directory);
        var records = history.All();
        Row("directory", Preferences.Directory);
        Row("records", records.Count.ToString());
        Row("needing retry", records.Count(r => r.CanRetry).ToString());
        Row("audio kept", $"{history.AudioBytes() / 1024} KB");

        Out.Line("\nBackends");
        foreach (var kind in Enum.GetValues<ProviderKind>())
        {
            var resolved = Preferences.ResolveKey(kind, !arguments.Flag("no-stored-key"));
            var marker = kind == arguments.ResolveProvider() ? "→ " : "  ";
            Row(
                $"{marker}{kind.ToString().ToLowerInvariant()}",
                (resolved is null ? $"no key ({kind.ApiKeyEnvVar()})" : $"key from {resolved.Value.Source}")
                + $" · {Preferences.Model(kind)}");
        }

        if (arguments.Flag("probe"))
        {
            Out.Line("\nLive check");
            var kind = arguments.ResolveProvider();
            var (service, _) = arguments.MakeService(kind);
            Out.Note($"probing {kind.ToString().ToLowerInvariant()}…");
            try
            {
                // A recogniser rejects a text-only request by design, so it gets silence instead —
                // enough to exercise auth, the URL and the response shape, which is all this claims.
                IReadOnlyList<InputPart> parts = service.Provider.Grounding
                    is GroundingSupport.MultimodalGrounding
                    ? [new InputPart.Text("Pretend the audio said: ok. Transcribe it.")]
                    : [new InputPart.Audio(SilentProbeWav(), "audio/wav")];

                await service.Provider
                    .TranscribeAsync("You are a transcription engine.", parts)
                    .ConfigureAwait(false);
                Row(kind.ToString().ToLowerInvariant(), "✓ accepted");
            }
            catch (Exception e) when (e is ProviderException or HttpRequestException)
            {
                Bad(kind.ToString().ToLowerInvariant(), $"✗ {e.Message}");
            }
        }
        else
        {
            Out.Line("\n(--probe makes one real request to check the key end to end.)");
        }

        Out.Line(string.Empty);
        if (problems.Count == 0)
        {
            Out.Line("No problems found.");
            return 0;
        }
        Out.Line($"{problems.Count} problem{(problems.Count == 1 ? "" : "s")} found:");
        foreach (var problem in problems) Out.Line($"  • {problem}");
        return 1;
    }

    /// <summary>A quarter-second of 16 kHz mono silence, built rather than shipped as a fixture.</summary>
    private static byte[] SilentProbeWav() =>
        AudioChunker.WrapInWavContainer(new byte[AudioDecoder.SampleRate / 4 * 2]);
}

/// <summary>
/// Reads and prunes the history the app writes.
/// </summary>
/// <remarks>
/// The history is already a plain JSON file by design — "deleting your history should be something
/// you can verify in Explorer". These are the operations that were previously only reachable
/// through a window.
/// </remarks>
public static class HistoryCommand
{
    public static int Run(Arguments arguments)
    {
        var store = new HistoryStore(Preferences.Directory);
        var sub = arguments.Positional.FirstOrDefault()?.ToLowerInvariant() ?? "list";

        return sub switch
        {
            "list" => List(arguments, store),
            "show" => Show(arguments, store),
            "delete" => Delete(arguments, store),
            "prune" => Prune(arguments, store),
            "path" => PrintPath(),
            _ => throw new UsageException(
                $"unknown history command '{sub}'. Options: list, show, delete, prune, path"),
        };
    }

    private static int List(Arguments arguments, HistoryStore store)
    {
        var records = store.All().AsEnumerable();

        if (arguments.Option("query") is { Length: > 0 } query)
        {
            records = records.Where(r =>
                r.Text.Contains(query, StringComparison.OrdinalIgnoreCase) ||
                (r.ErrorMessage ?? string.Empty).Contains(query, StringComparison.OrdinalIgnoreCase) ||
                (r.AppName ?? string.Empty).Contains(query, StringComparison.OrdinalIgnoreCase));
        }
        if (arguments.Option("status") is { } status && status != "all")
        {
            if (!Enum.TryParse<DictationStatus>(status, ignoreCase: true, out var wanted))
            {
                throw new UsageException($"unknown status '{status}'.");
            }
            records = records.Where(r => r.Status == wanted);
        }
        if (arguments.Flag("files-only")) records = records.Where(r => r.IsFromFile);

        var all = records.ToList();
        var limit = arguments.Int("limit", 20);
        var shown = limit > 0 ? all.Take(limit).ToList() : all;

        if (arguments.Flag("json"))
        {
            Out.Line(JsonSerializer.Serialize(shown, new JsonSerializerOptions
            {
                WriteIndented = true,
                Converters = { new JsonStringEnumConverter() },
            }));
            return 0;
        }

        if (shown.Count == 0)
        {
            Out.Line("Nothing in history matches.");
            return 0;
        }

        foreach (var record in shown)
        {
            var marker = record.Status switch
            {
                DictationStatus.Completed => "✓",
                DictationStatus.Failed => "✗",
                _ => "…",
            };
            var tags = new List<string> { record.ResolvedMode.Id };
            if (record.SourceFileName is { } source) tags.Add(source);
            if (record.AppName is { } app) tags.Add(app);
            if (record.RetryCount > 0) tags.Add($"retried {record.RetryCount}×");

            Out.Line(
                $"{marker} {record.Id.ToString()[..8]}  "
                + $"{record.CreatedAt:MMM dd HH:mm}  [{string.Join(" · ", tags)}]");
            Out.Line("    " + OneLine(record.Summary, 100));
        }

        // No silent caps: a list that stopped at 20 must say that 341 exist.
        if (limit > 0 && all.Count > shown.Count)
        {
            Out.Line($"\nShowing {shown.Count} of {all.Count}. Pass --limit 0 for all.");
        }
        return 0;
    }

    private static int Show(Arguments arguments, HistoryStore store)
    {
        var record = Match(arguments, store);
        if (arguments.Flag("json"))
        {
            Out.Line(JsonSerializer.Serialize(record, new JsonSerializerOptions
            {
                WriteIndented = true,
                Converters = { new JsonStringEnumConverter() },
            }));
            return 0;
        }

        Out.Line($"id         {record.Id}");
        Out.Line($"when       {record.CreatedAt:O}");
        Out.Line($"status     {record.Status.ToString().ToLowerInvariant()}");
        Out.Line($"mode       {record.ResolvedMode.Id}");
        Out.Line($"backend    {record.Model} · {record.Fidelity.Id()}");
        if (record.SourceFileName is { } source) Out.Line($"source     {source}");
        if (record.AppName is { } app) Out.Line($"app        {app}");
        if (record.LatencySeconds is { } latency)
        {
            Out.Line($"wait       {PerformanceStats.FormatDuration(latency)}");
        }
        if (record.AudioTokens is { } tokens) Out.Line($"audioTok   {tokens}");
        if (record.ErrorMessage is { } error) Out.Line($"error      {error}");
        Out.Line($"audio      {record.AudioFileName ?? "not kept"}");

        Out.Line("\n--- verbatim ---");
        Out.Line(record.Text);
        if (record.StyledText is { } styled)
        {
            Out.Line($"\n--- {record.ResolvedMode.Id} ---");
            Out.Line(styled);
        }
        return 0;
    }

    private static int Delete(Arguments arguments, HistoryStore store)
    {
        var record = Match(arguments, store);
        store.Delete(record.Id);
        Out.Note($"Deleted {record.Id}.");
        return 0;
    }

    private static int Prune(Arguments arguments, HistoryStore store)
    {
        var all = store.All();
        List<DictationRecord> doomed;

        if (arguments.Flag("all"))
        {
            doomed = all.ToList();
        }
        else if (arguments.Option("older-than") is { } days && int.TryParse(days, out var value))
        {
            var cutoff = DateTimeOffset.Now.AddDays(-value);
            doomed = all.Where(r => r.CreatedAt < cutoff).ToList();
        }
        else
        {
            throw new UsageException("pass --all or --older-than <days>.");
        }

        if (doomed.Count == 0)
        {
            Out.Note("Nothing to delete.");
            return 0;
        }
        if (arguments.Flag("dry-run"))
        {
            Out.Note($"Would delete {doomed.Count} of {all.Count} entries.");
            return 0;
        }
        foreach (var record in doomed) store.Delete(record.Id);
        Out.Note($"Deleted {doomed.Count} entries.");
        return 0;
    }

    private static int PrintPath()
    {
        Out.Line(Preferences.Directory);
        Out.Note("  history.json, audio\\, logs\\, and PROMPT.md if you have edited one");
        return 0;
    }

    private static DictationRecord Match(Arguments arguments, HistoryStore store)
    {
        var id = arguments.Positional.Skip(1).FirstOrDefault()
            ?? throw new UsageException("pass a record ID, or enough of the start of one.");

        var matches = store.All()
            .Where(r => r.Id.ToString().StartsWith(id, StringComparison.OrdinalIgnoreCase))
            .ToList();

        return matches.Count switch
        {
            0 => throw new UsageException($"no history entry starts with '{id}'."),
            1 => matches[0],
            _ => throw new UsageException($"'{id}' matches {matches.Count} entries. Use more of it."),
        };
    }

    private static string OneLine(string text, int limit)
    {
        var flat = text.Replace("\r", " ").Replace("\n", " ");
        return flat.Length > limit ? flat[..(limit - 1)] + "…" : flat;
    }
}

/// <summary>
/// Reads the app's log file. `tail` with the two things `tail` cannot do here: it knows where the
/// file is, and it understands the level column.
/// </summary>
public static class LogsCommand
{
    private static string AppLogPath =>
        Path.Combine(Preferences.Directory, "logs", "donottype.log");

    public static int Run(Arguments arguments)
    {
        if (arguments.Flag("path"))
        {
            Out.Line(AppLogPath);
            return 0;
        }

        if (arguments.Flag("clear"))
        {
            foreach (var path in new[] { AppLogPath, AppLogPath + ".1" }.Where(File.Exists))
            {
                File.Delete(path);
                Out.Note($"removed {path}");
            }
            return 0;
        }

        if (!File.Exists(AppLogPath))
        {
            Out.Note(
                $"No log file yet at {AppLogPath}.\n"
                + "The app writes one as soon as it runs. For the CLI's own logging use --verbose.");
            return 1;
        }

        var minimum = LogLevelExtensions.Parse(arguments.Option("level")) ?? LogLevel.Trace;
        var grep = arguments.Option("grep");
        var lines = arguments.Int("lines", 200);

        var matching = File.ReadAllLines(AppLogPath).Where(line => Matches(line, minimum, grep));
        foreach (var line in lines > 0 ? matching.TakeLast(lines) : matching) Out.Line(line);

        if (!arguments.Flag("follow")) return 0;

        // Polling rather than a FileSystemWatcher: an appended line does not always raise a change
        // notification on every filesystem, and half a second is invisible to someone watching.
        var offset = new FileInfo(AppLogPath).Length;
        while (true)
        {
            Thread.Sleep(500);
            var length = new FileInfo(AppLogPath).Length;
            if (length < offset) offset = 0; // rotated underneath us
            if (length == offset) continue;

            using var stream = new FileStream(
                AppLogPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
            stream.Seek(offset, SeekOrigin.Begin);
            using var reader = new StreamReader(stream);
            while (reader.ReadLine() is { } line)
            {
                if (Matches(line, minimum, grep)) Out.Line(line);
            }
            offset = length;
        }
    }

    private static bool Matches(string line, LogLevel minimum, string? grep)
    {
        if (grep is { Length: > 0 } && !line.Contains(grep, StringComparison.OrdinalIgnoreCase))
        {
            return false;
        }
        if (minimum == LogLevel.Trace) return true;

        // `12:04:31.512 WARN  fallback  …` — the level is the second column. A line that does not
        // parse (a wrapped stack trace, say) is kept rather than silently dropped.
        var columns = line.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (columns.Length < 2) return true;
        var parsed = LogLevelExtensions.Parse(columns[1]);
        return parsed is null || parsed >= minimum;
    }
}

/// <summary>
/// Prints the prompt that will actually be sent, placeholders expanded.
/// </summary>
public static class PromptCommand
{
    public static int Run(Arguments arguments)
    {
        var sub = arguments.Positional.FirstOrDefault()?.ToLowerInvariant() ?? "show";
        return sub switch
        {
            "show" => Show(arguments),
            "path" => ShowPath(arguments),
            "validate" => Validate(arguments),
            _ => throw new UsageException(
                $"unknown prompt command '{sub}'. Options: show, path, validate"),
        };
    }

    private static int Show(Arguments arguments)
    {
        var builder = arguments.ResolvePrompt();
        var section = arguments.Option("section") ?? "system";

        switch (section.ToLowerInvariant())
        {
            case "system" or "transcribe":
                Out.Line(builder.SystemInstruction(arguments.ResolveFidelity()));
                return 0;
            case "rewrite":
            {
                var mode = TranscriptMode.Parse($"rewrite:{arguments.Option("style") ?? "formal"}")
                    ?? throw new UsageException("unknown rewrite style.");
                Out.Line(builder.SecondStageInstruction(mode) ?? string.Empty);
                return 0;
            }
            case "summary":
            {
                var mode = TranscriptMode.Parse($"summary:{arguments.Option("summary") ?? "brief"}")
                    ?? throw new UsageException("unknown summary style.");
                Out.Line(builder.SecondStageInstruction(mode) ?? string.Empty);
                return 0;
            }
            default:
                throw new UsageException(
                    $"unknown section '{section}'. Options: system, rewrite, summary");
        }
    }

    private static int ShowPath(Arguments arguments)
    {
        var store = new PromptStore(Preferences.Directory);
        if (store.HasCustomPrompt)
        {
            Out.Line(store.CustomPath);
            Out.Note("edited copy — the measured numbers in PROMPT.md's changelog do not apply");
        }
        else
        {
            Out.Line(arguments.ResolvePromptPath());
            Out.Note("the shipped contract");
        }
        return 0;
    }

    private static int Validate(Arguments arguments)
    {
        var template = arguments.Positional.Skip(1).FirstOrDefault() is { } path
            ? File.ReadAllText(path)
            : new PromptStore(Preferences.Directory).ActiveTemplate(arguments.ResolvePromptPath());

        // PromptStore.Validate covers what a dictation needs. The optional stages are reported
        // rather than thrown: a prompt without a summary block is still a working prompt for
        // everything except summaries, and failing validation over it would be wrong.
        PromptStore.Validate(template);
        Out.Line("system block      ok (every fidelity resolves)");

        var builder = new PromptBuilder(template);
        foreach (var mode in TranscriptMode.All.Where(m => m.NeedsSecondPass))
        {
            Out.Line(ProvidersCommand.Pad(mode.Id, 18) + (builder.SupportsSecondStage(mode) ? "ok" : "MISSING"));
        }
        return 0;
    }
}
