using System.Text.Json;
using System.Text.Json.Serialization;
using DoNotType.Core;

namespace DoNotType.Cli;

/// <summary>
/// Transcribes recordings that already exist.
/// </summary>
/// <remarks>
/// The offline half of the product. Everything else in DoNotType is built around a key you hold
/// while speaking; this takes a recording and produces the same three things the live path can.
/// The verbatim transcript is always produced -- with --output it is written beside the derived
/// text rather than replaced by it, because a summary you cannot check against what was actually
/// said is a summary you have to take on faith.
/// </remarks>
public static class TranscribeCommand
{
    public static async Task<int> RunAsync(Arguments arguments)
    {
        if (arguments.Positional.Count == 0)
        {
            throw new UsageException("nothing to transcribe. Pass one or more audio files.");
        }

        var mode = TranscriptMode.Parse(arguments.Option("mode") ?? "verbatim")
            ?? throw new UsageException(
                $"unknown mode '{arguments.Option("mode")}'. Options: "
                + string.Join(", ", TranscriptMode.AcceptedSpellings));

        foreach (var path in arguments.Positional.Where(path => !File.Exists(path)))
        {
            throw new UsageException($"no such file: {path}");
        }

        var kind = arguments.ResolveProvider();
        var (service, keySource) = arguments.MakeService(kind);
        var secondStage = MakeSecondStage(arguments, out var secondStageName);

        var transcriber = new FileTranscriber(
            service, arguments.ResolvePrompt(), arguments.ResolveFidelity(), secondStage,
            Preferences.CustomRewriteStyle);

        // Checked before a single byte is uploaded. Finding out that a summary is impossible after
        // billing forty minutes of audio is a bad way to learn it.
        if (!transcriber.Supports(mode))
        {
            throw new UsageException(
                $"{kind.ToString().ToLowerInvariant()} is a speech recognition endpoint: it "
                + $"transcribes audio and cannot do anything with text, so it cannot produce a "
                + $"{mode.Id}.\nEither transcribe with a model (--provider gemini), or keep the "
                + "recogniser and add --text-provider gemini for the second stage.");
        }

        var quiet = arguments.Flag("quiet");
        var json = arguments.Flag("json");
        if (!quiet)
        {
            Out.Note(
                $"{kind.ToString().ToLowerInvariant()} · {service.Provider.Model} · {mode.Id} · "
                + $"key from {keySource}"
                + (secondStageName is null ? string.Empty : $" · second stage: {secondStageName}"));
        }

        var destination = ResolveOutput(arguments, arguments.Positional.Count);
        // Worked out before the first request rather than as each file finishes: a name collision
        // discovered halfway through a batch has already cost the money for the file it would
        // overwrite.
        var names = FileTranscriber.OutputNames(arguments.Positional);
        var index = 0;
        var outcomes = new List<FileTranscriber.Outcome>();
        var failures = 0;

        // Sequential on purpose. Concurrency here would interleave failures with output and make
        // the cost of a mistyped wildcard unbounded; --concurrency splits a single long recording,
        // which is where the wait actually is.
        foreach (var path in arguments.Positional)
        {
            var name = names[index++];
            try
            {
                var outcome = await transcriber.TranscribeAsync(
                        path, mode,
                        attempts: arguments.Int("attempts", 3),
                        maxConcurrent: arguments.Int("concurrency", 3),
                        onProgress: progress =>
                        {
                            if (!quiet) Out.Progress(Describe(progress, Path.GetFileName(path)));
                        })
                    .ConfigureAwait(false);

                Out.EndProgress();
                outcomes.Add(outcome);

                if (destination is not null) Write(outcome, destination.Value, name);
                if (arguments.Flag("save-history")) Store(outcome);
                if (!json) Emit(outcome, arguments.Positional.Count > 1);
            }
            catch (Exception error) when (error is ProviderException or IOException
                                              or AudioDecoder.DecodeException)
            {
                Out.EndProgress();
                failures++;
                Out.Note($"✗ {Path.GetFileName(path)}: {error.Message}");
            }
        }

        if (json)
        {
            Out.Line(JsonSerializer.Serialize(
                outcomes.Select(JsonOutcome.From).ToList(),
                new JsonSerializerOptions
                {
                    WriteIndented = true,
                    DefaultIgnoreCondition = JsonIgnoreCondition.Never,
                }));
        }

        if (!quiet && outcomes.Count > 0) Out.Note(Summarise(outcomes));

        // A partial run must not look like a clean one, and a script driving this needs the exit
        // code to say so.
        return failures > 0 ? 1 : 0;
    }

    private static TranscriptionService? MakeSecondStage(Arguments arguments, out string? name)
    {
        name = null;
        if (arguments.Option("text-provider") is not { } requested) return null;

        if (!Enum.TryParse<ProviderKind>(requested, ignoreCase: true, out var kind))
        {
            throw new UsageException($"unknown --text-provider '{requested}'.");
        }
        if (kind.IsSpeechRecognition())
        {
            throw new UsageException(
                $"--text-provider {requested} is a speech recognition endpoint and has no text "
                + "input. Choose gemini or openrouter.");
        }

        var (service, _) = arguments.MakeService(
            kind, arguments.Option("text-model") ?? kind.DefaultModel());
        name = $"{kind.ToString().ToLowerInvariant()}/{service.Provider.Model}";
        return service;
    }

    // ---- Output --------------------------------------------------------------------------------

    private enum DestinationKind { Directory, File }

    private static (DestinationKind Kind, string Path)? ResolveOutput(Arguments arguments, int count)
    {
        if (arguments.Option("output") is not { } output) return null;

        if (Directory.Exists(output)) return (DestinationKind.Directory, output);
        if (output.EndsWith('/') || output.EndsWith('\\') || count > 1)
        {
            Directory.CreateDirectory(output);
            return (DestinationKind.Directory, output);
        }
        return (DestinationKind.File, output);
    }

    private static void Write(
        FileTranscriber.Outcome outcome, (DestinationKind Kind, string Path) destination, string name)
    {
        var target = destination.Kind == DestinationKind.Directory
            ? Path.Combine(destination.Path, name)
            : destination.Path;

        File.WriteAllText(target, outcome.Delivered);
        Out.Note($"wrote {target}");

        // The verbatim transcript goes next to the derived one rather than being replaced by it.
        if (outcome.Mode is TranscriptMode.VerbatimMode || outcome.Delivered == outcome.Verbatim)
        {
            return;
        }
        var beside = Path.ChangeExtension(target, ".verbatim.txt");
        File.WriteAllText(beside, outcome.Verbatim);
        Out.Note($"wrote {beside}");
    }

    private static void Emit(FileTranscriber.Outcome outcome, bool showHeader)
    {
        if (showHeader) Out.Line($"# {Path.GetFileName(outcome.SourcePath)}");
        Out.Line(outcome.Delivered);
        if (showHeader) Out.Line(string.Empty);
    }

    private static void Store(FileTranscriber.Outcome outcome)
    {
        // The recording is already on disk where the user put it; copying it into the history would
        // duplicate potentially hours of audio, and the row records where it came from.
        new HistoryStore(Preferences.Directory).Insert(outcome.ToRecord(), null);
    }

    private static string Describe(FileTranscriber.Progress progress, string file) => progress switch
    {
        FileTranscriber.Progress.Decoding => $"{file}: reading the file…",
        FileTranscriber.Progress.Transcribing chunk =>
            chunk.Of > 1
                ? $"{file}: transcribing {chunk.Done}/{chunk.Of}…"
                : $"{file}: transcribing…",
        FileTranscriber.Progress.Deriving deriving => $"{file}: {deriving.Mode.Id}…",
        _ => string.Empty,
    };

    private static string Summarise(List<FileTranscriber.Outcome> outcomes)
    {
        var seconds = outcomes.Sum(o => o.TotalSeconds);
        var audio = outcomes.Sum(o => o.DurationSeconds);
        var tokens = outcomes.Sum(o => o.Usage.AudioTokens ?? 0);

        var parts = new List<string> { $"{outcomes.Count} file{(outcomes.Count == 1 ? "" : "s")}" };
        if (audio > 0)
        {
            parts.Add($"{PerformanceStats.FormatDuration(audio)} of audio");
            parts.Add($"in {PerformanceStats.FormatDuration(seconds)}");
            if (seconds > 0) parts.Add($"({audio / seconds:F0}× realtime)");
        }
        else
        {
            parts.Add($"in {PerformanceStats.FormatDuration(seconds)}");
        }
        if (tokens > 0) parts.Add($"· {tokens} audio tokens");
        return string.Join(" ", parts);
    }

    /// <summary>
    /// The --json shape. Declared rather than derived from Outcome so the field names are a
    /// deliberate, stable contract for whatever is parsing them.
    /// </summary>
    private sealed record JsonOutcome
    {
        public required string File { get; init; }
        public required string Mode { get; init; }
        public required string Fidelity { get; init; }
        public required string Provider { get; init; }
        public required string Model { get; init; }
        public string? SecondStageProvider { get; init; }
        public required string Language { get; init; }
        public required string Text { get; init; }
        public required string Verbatim { get; init; }
        public double AudioSeconds { get; init; }
        public double DecodeSeconds { get; init; }
        public double TranscriptionSeconds { get; init; }
        public double? SecondStageSeconds { get; init; }
        public int Chunks { get; init; }
        public int? AudioTokens { get; init; }

        public static JsonOutcome From(FileTranscriber.Outcome outcome) => new()
        {
            File = outcome.SourcePath,
            Mode = outcome.Mode.Id,
            Fidelity = outcome.Fidelity.Id(),
            Provider = outcome.Provider,
            Model = outcome.Model,
            SecondStageProvider = outcome.SecondStageProvider,
            Language = outcome.Language,
            Text = outcome.Delivered,
            Verbatim = outcome.Verbatim,
            AudioSeconds = outcome.DurationSeconds,
            DecodeSeconds = outcome.DecodeSeconds,
            TranscriptionSeconds = outcome.TranscriptionSeconds,
            SecondStageSeconds = outcome.SecondStageSeconds,
            Chunks = outcome.ChunkCount,
            AudioTokens = outcome.Usage.AudioTokens,
        };
    }
}
