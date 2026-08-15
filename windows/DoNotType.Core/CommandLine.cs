namespace DoNotType.Core;

/// <summary>
/// A parsed command line: one verb, some positional values, and `--name value` or `--flag` pairs.
/// </summary>
/// <remarks>
/// In the core rather than beside the CLI that uses it, because it is the one part of a
/// command-line tool with no platform in it and every part of it is worth a test. Living inside a
/// Windows-only executable is why it went untested long enough for two flags to become one.
/// </remarks>
public class CommandLine
{

    public string Verb { get; private init; } = string.Empty;
    public List<string> Positional { get; } = [];
    private readonly Dictionary<string, string> _options = new(StringComparer.OrdinalIgnoreCase);
    private readonly HashSet<string> _flags = new(StringComparer.OrdinalIgnoreCase);

    public static CommandLine Parse(string[] args)
    {
        var parsed = new CommandLine
        {
            Verb = args.Length > 0 && !args[0].StartsWith('-') ? args[0].ToLowerInvariant()
                : args.Length > 0 ? args[0]
                : string.Empty,
        };

        var optionsEnded = false;

        for (var i = parsed.Verb.Length > 0 ? 1 : 0; i < args.Length; i++)
        {
            var value = args[i];

            // `--` ends option parsing, as it does everywhere else. This is how somebody
            // transcribes a file whose name begins with a dash, and the only way: without it that
            // name is either an unknown option or, worse, a real one.
            if (value == "--" && !optionsEnded)
            {
                optionsEnded = true;
                continue;
            }
            if (optionsEnded)
            {
                parsed.Positional.Add(value);
                continue;
            }

            if (!value.StartsWith("--", StringComparison.Ordinal))
            {
                // A lone `-` is stdin by convention, and a negative number is a value. Anything
                // else with one dash is a short option nobody declared, and treating it as a file
                // name is how `-o notes.txt` became "No such file: -o".
                if (value.Length > 1 && value[0] == '-' && !char.IsDigit(value[1])
                    && !Short.ContainsValue(value[1..]))
                {
                    throw new UsageException(
                        $"unknown option '{value}'. Options are spelled out in full: "
                        + $"'--{value[1..]}' rather than '{value}'. Only -v is abbreviated.");
                }
                if (value != "-v")
                {
                    parsed.Positional.Add(value);
                    continue;
                }
            }

            var name = value.TrimStart('-');
            if (name.Length == 0) continue; // `---`, which is a typo rather than a flag
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

    /// <summary>
    /// Whether a flag was given, by its full name or a declared short form.
    /// </summary>
    /// <remarks>
    /// This used to answer yes if the first letter matched, which was a shortcut that quietly
    /// aliased every flag to its initial: `--p` set both `--path` and `--probe`, and `Flag("")`
    /// threw. Short forms are declared instead, and there is deliberately only one — `-v` is
    /// universal, and inventing a private alphabet for the rest makes scripts harder to read.
    /// </remarks>
    public bool Flag(string name) =>
        _flags.Contains(name) || (Short.TryGetValue(name, out var alias) && _flags.Contains(alias));

    private static readonly Dictionary<string, string> Short =
        new(StringComparer.OrdinalIgnoreCase) { ["verbose"] = "v" };

    public bool Has(string name) => _flags.Contains(name) || _options.ContainsKey(name);

    public int Int(string name, int fallback) =>
        int.TryParse(Option(name), out var value) ? value : fallback;

    /// <summary>Reparses, which is what a wrapper needs to produce its own type.</summary>
    protected CommandLine(CommandLine other)
    {
        Verb = other.Verb;
        Positional.AddRange(other.Positional);
        foreach (var (key, value) in other._options) _options[key] = value;
        foreach (var flag in other._flags) _flags.Add(flag);
    }

    protected CommandLine()
    {
    }
}

/// <summary>A message meant for the user rather than a stack trace.</summary>
public sealed class UsageException(string message) : Exception(message);
