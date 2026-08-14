using DoNotType.Core;

namespace DoNotType.Cli;

/// <summary>
/// A parsed command line: one verb, some positional values, and `--name value` or `--flag` pairs.
/// </summary>
public sealed class Arguments
{
    public string Verb { get; private init; } = string.Empty;
    public List<string> Positional { get; } = [];
    private readonly Dictionary<string, string> _options = new(StringComparer.OrdinalIgnoreCase);
    private readonly HashSet<string> _flags = new(StringComparer.OrdinalIgnoreCase);

    public static Arguments Parse(string[] args)
    {
        var parsed = new Arguments
        {
            Verb = args.Length > 0 && !args[0].StartsWith('-') ? args[0].ToLowerInvariant()
                : args.Length > 0 ? args[0]
                : string.Empty,
        };

        for (var i = parsed.Verb.Length > 0 ? 1 : 0; i < args.Length; i++)
        {
            var value = args[i];
            if (!value.StartsWith("--", StringComparison.Ordinal) && value != "-v")
            {
                parsed.Positional.Add(value);
                continue;
            }

            var name = value.TrimStart('-');
            // `--name value` unless the next token is another option, which makes it a flag. That
            // is what lets `--json --output notes` and `--output notes --json` both work.
            if (i + 1 < args.Length && !args[i + 1].StartsWith("--", StringComparison.Ordinal)
                && TakesValue(name))
            {
                parsed._options[name] = args[++i];
            }
            else
            {
                parsed._flags.Add(name);
            }
        }
        return parsed;
    }

    /// <summary>
    /// Options that consume the next token. Declared rather than guessed, so a bare `--json` before
    /// a file path does not swallow the path.
    /// </summary>
    private static bool TakesValue(string name) => name.ToLowerInvariant() is
        "mode" or "provider" or "model" or "fidelity" or "prompt" or "output" or "text-provider"
        or "text-model" or "log-level" or "level" or "lines" or "grep" or "limit" or "status"
        or "query" or "older-than" or "concurrency" or "attempts" or "section" or "style"
        or "summary" or "id";

    public string? Option(string name) => _options.TryGetValue(name, out var value) ? value : null;

    public bool Flag(string name) => _flags.Contains(name) || _flags.Contains(name[..1]);

    public bool Has(string name) => _flags.Contains(name) || _options.ContainsKey(name);

    public int Int(string name, int fallback) =>
        int.TryParse(Option(name), out var value) ? value : fallback;

    // ---- Shared resolution --------------------------------------------------------------------

    /// <summary>
    /// Installs logging. Flags beat the environment, which beats the default -- a `--log-level`
    /// typed for this invocation must win over a variable set in the shell profile last month.
    /// </summary>
    public void StartLogging()
    {
        var configuration = LogRouter.Configuration
            .CommandLine(Flag("verbose") ? LogLevel.Debug : LogLevel.Warn)
            .ApplyingEnvironment();

        if (LogLevelExtensions.Parse(Option("log-level")) is { } level)
        {
            configuration = configuration with { Level = level };
        }
        if (Flag("log-content")) configuration = configuration with { IncludesContent = true };

        LogRouter.Bootstrap(configuration, applyEnvironment: false);
    }

    public ProviderKind ResolveProvider()
    {
        if (Option("provider") is not { } name) return Preferences.Provider;
        if (!Enum.TryParse<ProviderKind>(name, ignoreCase: true, out var kind))
        {
            throw new UsageException(
                $"unknown provider '{name}'. Options: "
                + string.Join(", ", Enum.GetNames<ProviderKind>().Select(n => n.ToLowerInvariant())));
        }
        return kind;
    }

    public Fidelity ResolveFidelity()
    {
        if (Option("fidelity") is not { } name) return Preferences.Fidelity;
        if (!Enum.TryParse<Fidelity>(name, ignoreCase: true, out var value))
        {
            throw new UsageException($"unknown fidelity '{name}'. Options: raw, light, tidy");
        }
        return value;
    }

    /// <summary>
    /// Finds PROMPT.md: an explicit path, then up from the working directory, then beside this
    /// executable -- which is where an installed copy sits, next to the app that ships it.
    /// </summary>
    public string ResolvePromptPath()
    {
        if (Option("prompt") is { } explicitPath)
        {
            if (!File.Exists(explicitPath)) throw new UsageException($"no such file: {explicitPath}");
            return explicitPath;
        }
        return PromptBuilder.FindPromptFile(Directory.GetCurrentDirectory())
            ?? PromptBuilder.FindPromptFile(AppContext.BaseDirectory)
            ?? throw new UsageException(
                "could not find PROMPT.md. Run this from a checkout, pass --prompt, or install the "
                + "app -- the CLI looks beside its own executable too.");
    }

    public PromptBuilder ResolvePrompt()
    {
        // The user's edited copy when they have one, exactly as the app would use it. A CLI that
        // silently sent the shipped prompt while the app sent an edited one would make the two
        // disagree about the only file that matters.
        var store = new PromptStore(Preferences.Directory);
        return new PromptBuilder(store.ActiveTemplate(ResolvePromptPath()));
    }

    /// <summary>Builds a service, and says where the key came from.</summary>
    public (TranscriptionService Service, string KeySource) MakeService(
        ProviderKind kind, string? modelOverride = null)
    {
        var resolved = Preferences.ResolveKey(kind, allowStored: !Flag("no-stored-key"))
            ?? throw new UsageException(
                $"no API key for {kind.ToString().ToLowerInvariant()}. Set {kind.ApiKeyEnvVar()}, or "
                + "add it in the app's settings — the CLI reads the same store unless you pass "
                + "--no-stored-key.");

        // Registered before the first request, so the key cannot appear in a log line whatever
        // route it takes there -- including a provider echoing it back inside an error body.
        LogRouter.Redact(resolved.Key);

        var model = modelOverride ?? Option("model") ?? Preferences.Model(kind);
        var provider = ProviderFactory.Create(kind, resolved.Key, model);
        var service = new TranscriptionService(
            provider,
            ResolvePrompt().SystemInstruction(ResolveFidelity()),
            new ContextEncoder())
        {
            Fidelity = ResolveFidelity(),
            KeytermBiasing = Flag("keyterms"),
        };
        return (service, resolved.Source);
    }
}
