using DoNotType.Core;

namespace DoNotType.Cli;

/// <summary>
/// The developer-facing command line, ported from the Swift `dnt`.
/// </summary>
/// <remarks>
/// <para>
/// Two rules shape the output. <strong>stdout is the transcript</strong> -- every diagnostic,
/// progress line and summary goes to stderr, so <c>dnt transcribe memo.wav &gt; memo.txt</c>
/// produces a file with nothing in it but words. <strong>Nothing prints a secret</strong> -- keys
/// are reported by source, never by value, and each is registered with the logger before the first
/// request.
/// </para>
/// <para>
/// Hand-rolled argument parsing rather than System.CommandLine, which is a preview package. The
/// grammar here is six verbs and a handful of <c>--name value</c> pairs; a dependency to express
/// that would cost more than it saves.
/// </para>
/// </remarks>
public static class Program
{
    public static async Task<int> Main(string[] args)
    {
        var arguments = Arguments.Parse(args);
        arguments.StartLogging();

        try
        {
            return arguments.Verb switch
            {
                "transcribe" => await TranscribeCommand.RunAsync(arguments).ConfigureAwait(false),
                "providers" => ProvidersCommand.Run(arguments),
                "doctor" => await DoctorCommand.RunAsync(arguments).ConfigureAwait(false),
                "history" => HistoryCommand.Run(arguments),
                "logs" => LogsCommand.Run(arguments),
                "prompt" => PromptCommand.Run(arguments),
                "help" or "--help" or "-h" or "" => Help(),
                "--version" => Version(),
                _ => Unknown(arguments.Verb),
            };
        }
        catch (UsageException usage)
        {
            Out.Note($"error: {usage.Message}");
            return 2;
        }
        catch (Exception error)
        {
            Out.Note($"error: {error.Message}");
            return 1;
        }
    }

    private static int Help()
    {
        Out.Line(
            """
            dnt — transcribe recordings, and inspect what DoNotType is doing.

            USAGE
              dnt <command> [options]

            COMMANDS
              transcribe <files...>   Transcribe one or more recordings
              providers               Which backends have a key, and what each can do
              doctor                  Check keys, prompt, history, audio support
              history                 List, show, delete and prune stored transcripts
              logs                    Show what the app logged
              prompt                  Show, locate or validate the prompt contract

            TRANSCRIBE
              --mode <mode>           verbatim (default), rewrite[:style], summary[:style]
                                      styles: formal, concise, casual / brief, bullets, actions
              --provider <name>       gemini, openrouter, deepgram, mistral, xai
              --model <id>            Model override
              --fidelity <level>      raw, light, tidy
              --text-provider <name>  Backend for the rewrite or summary stage
              --output <path>         Write transcripts here; a directory takes one file each
              --json                  Emit JSON, including the verbatim transcript
              --save-history          Record the results in the app's history
              --quiet                 Only the transcript on stdout
              --no-stored-key         Ignore the app's stored key; use the environment only

            GLOBAL
              -v, --verbose           Log to stderr at debug level
              --log-level <level>     trace, debug, info, warn, error, off

            EXAMPLES
              dnt transcribe memo.wav
              dnt transcribe talk.wav --mode summary:bullets
              dnt doctor --probe
              dnt logs --follow --level warn

            Formats: WAV, MP3, M4A/AAC, Opus, and anything else Windows can play. Recordings
            longer than 90 seconds are split on silence and transcribed concurrently.
            """);
        return 0;
    }

    private static int Version()
    {
        Out.Line("dnt 0.2.0");
        return 0;
    }

    private static int Unknown(string verb)
    {
        Out.Note($"error: unknown command '{verb}'. Run `dnt help`.");
        return 2;
    }
}

/// <summary>
/// stdout is the transcript; stderr is everything else.
/// </summary>
/// <remarks>
/// One type rather than scattered Console calls, because the rule is easy to break by accident and
/// a single stray WriteLine in a progress path silently corrupts every piped transcript downstream.
/// </remarks>
public static class Out
{
    public static void Line(string text) => Console.Out.WriteLine(text);

    public static void Note(string text) => Console.Error.WriteLine(text);

    /// <summary>Overwritable progress. Silent when stderr is redirected -- a bar in a log is noise.</summary>
    public static void Progress(string text)
    {
        if (Console.IsErrorRedirected) return;
        Console.Error.Write("\r" + text.PadRight(72));
    }

    public static void EndProgress()
    {
        if (Console.IsErrorRedirected) return;
        Console.Error.Write("\r" + new string(' ', 72) + "\r");
    }
}
