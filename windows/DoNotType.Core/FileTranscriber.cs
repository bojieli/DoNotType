namespace DoNotType.Core;

/// <summary>
/// Transcribes a recording that already exists, rather than one being spoken right now.
/// </summary>
/// <remarks>
/// <para>
/// Live dictation is a latency problem: the user is standing there, the audio is already in the
/// right format, and every decision exists to shorten the wait. A file on disk is a
/// <em>throughput</em> problem -- it may be forty minutes long, and nobody is waiting on the first
/// word.
/// </para>
/// <para>
/// The invariant is the one the whole project rests on: the verbatim transcript is produced and
/// returned alongside whatever was derived from it, always, including for summaries where the
/// derived text is by definition missing most of what was said.
/// </para>
/// </remarks>
public sealed class FileTranscriber(
    TranscriptionService service,
    PromptBuilder prompt,
    Fidelity fidelity = Fidelity.Light,
    TranscriptionService? secondStage = null)
{
    private static readonly Log Log = new("file");

    /// <summary>What the caller can show while this runs. A forty-minute file is not a spinner.</summary>
    public abstract record Progress
    {
        private Progress() { }

        public sealed record Decoding(string File) : Progress;
        public sealed record Transcribing(int Done, int Of) : Progress;
        public sealed record Deriving(TranscriptMode Mode) : Progress;
    }

    public sealed record Outcome
    {
        public required string SourcePath { get; init; }

        /// <summary>Word for word, at the requested fidelity. Always present.</summary>
        public required string Verbatim { get; init; }

        /// <summary>What the mode produced. Identical to <see cref="Verbatim"/> for verbatim.</summary>
        public required string Delivered { get; init; }

        public required TranscriptMode Mode { get; init; }
        public required Fidelity Fidelity { get; init; }
        public string Language { get; init; } = string.Empty;
        public TokenUsage Usage { get; init; } = new();
        public int ChunkCount { get; init; } = 1;
        public double DurationSeconds { get; init; }
        public double DecodeSeconds { get; init; }
        public double TranscriptionSeconds { get; init; }
        public double? SecondStageSeconds { get; init; }
        public required string Provider { get; init; }
        public required string Model { get; init; }

        /// <summary>The backend that ran the second stage, when it was not the transcription one.</summary>
        public string? SecondStageProvider { get; init; }

        public double TotalSeconds => DecodeSeconds + TranscriptionSeconds + (SecondStageSeconds ?? 0);

        /// <summary>
        /// A history row for this file, so an offline transcription is searchable next to the
        /// dictations -- and so the CLI and the app agree on what one looks like.
        /// </summary>
        public DictationRecord ToRecord() => new()
        {
            Status = DictationStatus.Completed,
            Text = Verbatim,
            StyledText = Mode is TranscriptMode.VerbatimMode ? null : Delivered,
            Mode = Mode.Id,
            SourceFileName = Path.GetFileName(SourcePath),
            Model = Model,
            Fidelity = Fidelity,
            DurationSeconds = DurationSeconds,
            LatencySeconds = TotalSeconds,
            RequestSeconds = TranscriptionSeconds,
            AudioTokens = Usage.AudioTokens,
        };
    }

    /// <summary>
    /// The backend that can run a second stage, or null when nothing available can.
    /// </summary>
    /// <remarks>
    /// A recogniser has no text channel, so this is a capability question rather than a preference.
    /// </remarks>
    private TranscriptionService? TextCapableService =>
        secondStage is not null && secondStage.Provider.Grounding is GroundingSupport.MultimodalGrounding
            ? secondStage
            : service.Provider.Grounding is GroundingSupport.MultimodalGrounding ? service : null;

    /// <summary>
    /// Whether this configuration can run the mode at all, checked before any audio is sent.
    /// Discovering that a summary is impossible after billing forty minutes would be expensive.
    /// </summary>
    public bool Supports(TranscriptMode mode) =>
        !mode.NeedsSecondPass || (TextCapableService is not null && prompt.SupportsSecondStage(mode));

    public async Task<Outcome> TranscribeAsync(
        string path,
        TranscriptMode? mode = null,
        ScreenContext? context = null,
        int attempts = 3,
        int maxConcurrent = 3,
        Action<Progress>? onProgress = null,
        CancellationToken cancellationToken = default)
    {
        mode ??= TranscriptMode.Verbatim;
        if (!Supports(mode))
        {
            throw new ProviderException(
                $"{service.Provider.Name} is a speech recognition endpoint: it transcribes audio and "
                + $"cannot do anything with text, so it cannot produce a {mode.Id}. Transcribe with "
                + "a model instead, or pair the recogniser with one for the second stage.");
        }

        var name = Path.GetFileName(path);
        Log.Info(() => "transcribing file", new Dictionary<string, string>
        {
            ["file"] = name,
            ["mode"] = mode.Id,
            ["provider"] = service.Provider.Name,
            ["model"] = service.Provider.Model,
            ["fidelity"] = fidelity.Id(),
        });

        onProgress?.Invoke(new Progress.Decoding(name));
        var decodeStart = DateTimeOffset.Now;
        var wav = AudioDecoder.Load(path);
        var decodeSeconds = (DateTimeOffset.Now - decodeStart).TotalSeconds;

        // The same gate as live dictation, for the same reason: a model handed a recording with no
        // speech in it returns a plausible sentence rather than nothing. Here it is an error rather
        // than a silent no-op, because somebody who pointed at a file and pressed go is owed an
        // answer — and "there is no speech in this recording" is a better one than a paragraph the
        // model made up.
        var activity = SpeechActivity.MeasureWav(wav);
        if (!activity.HasSpeech)
        {
            Log.Info(() => "no speech in the recording", new Dictionary<string, string>
            {
                ["file"] = name,
                ["audio"] = activity.Summary,
            });
            throw new NoSpeechException(name);
        }

        var transcribeStart = DateTimeOffset.Now;
        var result = await service.TranscribeLongAsync(
                wav, context, attempts, maxConcurrent,
                (done, of) => onProgress?.Invoke(new Progress.Transcribing(done, of)),
                cancellationToken)
            .ConfigureAwait(false);
        var transcriptionSeconds = (DateTimeOffset.Now - transcribeStart).TotalSeconds;

        var verbatim = result.Transcript.Text.Trim();
        Log.Info(() => "transcribed file", new Dictionary<string, string>
        {
            ["file"] = name,
            ["chars"] = verbatim.Length.ToString(),
            ["chunks"] = result.ChunkCount.ToString(),
            ["ms"] = ((long)(transcriptionSeconds * 1000)).ToString(),
        });
        Log.Content("transcript", () => verbatim, LogLevel.Trace);

        var outcome = new Outcome
        {
            SourcePath = path,
            Verbatim = verbatim,
            Delivered = verbatim,
            Mode = mode,
            Fidelity = fidelity,
            Language = result.Transcript.Language,
            Usage = result.Usage,
            ChunkCount = result.ChunkCount,
            DurationSeconds = AudioChunker.DurationSeconds(wav),
            DecodeSeconds = decodeSeconds,
            TranscriptionSeconds = transcriptionSeconds,
            Provider = service.Provider.Name,
            Model = service.Provider.Model,
        };

        // An empty transcript means silence, and there is nothing to rewrite or summarise. Running
        // the second stage anyway would ask a model to write prose from nothing, which is the one
        // way this pipeline could invent words outright.
        if (!mode.NeedsSecondPass || verbatim.Length == 0) return outcome;

        var instruction = prompt.SecondStageInstruction(mode);
        var deriver = TextCapableService;
        if (instruction is null || deriver is null) return outcome;

        onProgress?.Invoke(new Progress.Deriving(mode));
        var deriveStart = DateTimeOffset.Now;
        var derived = (await deriver.RewriteAsync(verbatim, instruction, cancellationToken)
            .ConfigureAwait(false)).Trim();
        var secondStageSeconds = (DateTimeOffset.Now - deriveStart).TotalSeconds;

        Log.Info(() => "second stage finished", new Dictionary<string, string>
        {
            ["file"] = name,
            ["mode"] = mode.Id,
            ["chars"] = derived.Length.ToString(),
            ["from"] = verbatim.Length.ToString(),
            ["provider"] = deriver.Provider.Name,
        });

        return outcome with
        {
            Delivered = derived.Length > 0 ? derived : verbatim,
            SecondStageSeconds = secondStageSeconds,
            SecondStageProvider =
                deriver.Provider.Name == service.Provider.Name ? null : deriver.Provider.Name,
        };
    }

    /// <summary>One output name per input, unique by construction.</summary>
    /// <remarks>
    /// `a/speech.wav` and `b/speech.mp3` both wanted to be `speech.txt`, and the second silently
    /// replaced the first — a whole transcription gone, already paid for, with "wrote speech.txt"
    /// printed twice as though both had landed. Only names that would actually collide are made
    /// ugly, because the ordinary case is one file and `speech.txt` is what anybody would expect.
    /// </remarks>
    public static IReadOnlyList<string> OutputNames(IReadOnlyList<string> paths)
    {
        var used = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var names = new List<string>(paths.Count);
        foreach (var path in paths)
        {
            var stem = Path.GetFileNameWithoutExtension(path);
            var name = stem + ".txt";
            // Keep the source extension, which is what distinguishes them and what the user typed.
            if (used.Contains(name)) name = Path.GetFileName(path) + ".txt";
            // Same name in two directories. Nothing in the name can separate those, so number them
            // in the order they were given, which is the order the "wrote ..." lines print in.
            for (var suffix = 2; used.Contains(name); suffix++) name = $"{stem}-{suffix}.txt";
            used.Add(name);
            names.Add(name);
        }
        return names;
    }
}

/// <summary>The recording contains no speech, so nothing was sent.</summary>
/// <remarks>
/// Its own type so a caller can tell "there was nothing to transcribe" from "the request failed",
/// which are different things to tell somebody and different things to retry.
/// </remarks>
public sealed class NoSpeechException(string name) : Exception(
    $"{name} has no speech in it — nothing was sent. A model given a recording with only silence "
    + "or noise in it does not reliably return nothing; it returns a plausible sentence, which is "
    + "worse than an error.");
