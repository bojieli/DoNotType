using DoNotType.Core;

namespace DoNotType.Cli;

/// <summary>
/// The command line, plus everything the CLI has to look up before it can act on it: which
/// provider, which key, which prompt file.
/// </summary>
/// <remarks>
/// The parsing lives in <see cref="CommandLine"/>, which is portable and tested. This half is not
/// either: it reads the Windows credential store and the user's preferences.
/// </remarks>
public sealed class Arguments : CommandLine
{
    private Arguments(CommandLine parsed) : base(parsed)
    {
    }

    public static new Arguments Parse(string[] args) => new(CommandLine.Parse(args));

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
    /// Finds prompt/: an explicit path, then up from the working directory, then beside this
    /// executable -- which is where an installed copy sits, next to the app that ships it.
    /// </summary>
    public string ResolvePromptPath()
    {
        if (Option("prompt") is { } explicitPath)
        {
            if (!Directory.Exists(explicitPath))
            {
                throw new UsageException($"no such directory: {explicitPath}");
            }
            return explicitPath;
        }
        return PromptBuilder.FindPromptDirectory(Directory.GetCurrentDirectory())
            ?? PromptBuilder.FindPromptDirectory(AppContext.BaseDirectory)
            ?? throw new UsageException(
                "could not find the prompt/ directory. Run this from a checkout, pass --prompt, or "
                + "install the app -- the CLI looks beside its own executable too.");
    }

    public PromptBuilder ResolvePrompt()
    {
        // The user's edited parts when they have any, exactly as the app would use them. A CLI that
        // silently sent the shipped prompt while the app sent an edited one would make the two
        // disagree about the only files that matter.
        var store = new PromptStore(Preferences.Directory);
        return store.Builder(ResolvePromptPath());
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
