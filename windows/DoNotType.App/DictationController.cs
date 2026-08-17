using System.Diagnostics;
using DoNotType.Core;

namespace DoNotType.App;

/// <summary>
/// Orchestrates one dictation: hold the key, speak, release, get your words back.
/// </summary>
public sealed class DictationController : IDisposable
{
    public enum State
    {
        Idle,
        Recording,
        Transcribing,
        /// <summary>
        /// The second request. A different thing to be waiting on, and usually the slower of the
        /// two — the transcript already exists by then, so an overlay that still says
        /// "Transcribing…" is describing something that has finished.
        /// </summary>
        Deriving,
        Failed,
    }

    private readonly AudioRecorder _recorder = new();
    private readonly HotkeyMonitor _hotkey = new();
    private readonly ScreenReader _screen = new();
    private readonly HistoryStore _history;
    private readonly AppSettings _settings;

    private ScreenContext? _pendingContext;
    private CancellationTokenSource? _groundingCts;
    private CancellationTokenSource? _dictationCts;
    private Task<ScreenContext>? _fullCapture;

    public State Current { get; private set; } = State.Idle;
    public string? LastError { get; private set; }

    /// <summary>Everything a dictation does, under one category so `dnt logs --grep` finds it.</summary>
    private static readonly Log DictationLog = new("dictate");

    /// <summary>
    /// The prompt in force: the user's edited parts over the shipped ones.
    /// </summary>
    /// <remarks>
    /// Every path that builds a request goes through here -- primary, fallback, second stage and
    /// retry alike. Reading the shipped directory directly in any one of them would mean an edited
    /// prompt applied to some requests and not others, and which you got would depend on timing.
    /// </remarks>
    private static PromptBuilder Prompt(string bundled) =>
        new PromptStore(HistoryStore.DefaultDirectory()).Builder(bundled);

    /// <summary>The in-flight dictation's id, from the key press to the insertion.</summary>
    private Guid _pendingId = Guid.NewGuid();

    /// <summary>
    /// Which key started the recording decides whether it is rewritten, and into what.
    /// </summary>
    /// <remarks>
    /// Read at the press and held until the transcript is delivered, because the settings it comes
    /// from are live: changing the style mid-dictation must not change what the recording already
    /// in flight becomes.
    /// </remarks>
    private RewriteStyle _pendingStyle = RewriteStyle.Verbatim;

    /// <summary>Which process was focused when the key went down, and its window title.</summary>
    /// <remarks>
    /// The process id rather than the title: two windows of the same app are the same target, and
    /// a title changes while the user works without the target having moved at all.
    /// </remarks>
    private (uint Pid, string Title)? _pendingTarget;

    /// <summary>
    /// Eight characters is enough to pick one dictation out of a day's log and short enough to sit
    /// in every line without pushing the interesting fields off the end.
    /// </summary>
    private static string Short(Guid id) => id.ToString("N")[..8];

    public event Action<State>? StateChanged;

    /// <summary>
    /// Words reached the focused window, and how many characters they were.
    /// </summary>
    /// <remarks>
    /// Fired after the insertion rather than with the state change, because the state goes back to
    /// idle before the paste so the hotkey is free again. Without this the pill simply vanishes and
    /// success is something the user has to infer from text appearing — which they cannot do if the
    /// target window scrolled, or if the insertion went somewhere they were not looking.
    /// </remarks>
    /// <param name="Characters">How many characters reached the focused window.</param>
    /// <param name="RewriteFailed">
    /// The words landed, but the rewrite that was asked for did not happen. Carried on the same
    /// event rather than a second one: two events would have to arrive in a particular order for
    /// the interface to render correctly, and nothing would enforce it.
    /// </param>
    public sealed record Insertion(int Characters, bool RewriteFailed);

    public event Action<Insertion>? Inserted;

    /// <summary>
    /// Fires as each part of a long dictation lands, as (done, total).
    /// </summary>
    /// <remarks>
    /// Only raised when a recording was long enough to split -- "1 of 1" is noise. A nine-minute
    /// recording that sits on "Transcribing…" for half a minute looks hung, and this is what
    /// distinguishes slow from stuck.
    /// </remarks>
    public event Action<int, int>? ChunkProgress;
    public event Action? HistoryChanged;

    public HistoryStore History => _history;
    public IReadOnlyList<AudioLevelMeter.Bar> DrainLevels() => _recorder.DrainLevels();

    public DictationController(AppSettings settings)
    {
        _settings = settings;
        _history = new HistoryStore(HistoryStore.DefaultDirectory());
        _history.Configure(settings.Retention, settings.KeepAudio);

        _hotkey.IsRecording = () => Current == State.Recording;
        _hotkey.IsDictationActive = () =>
            Current is State.Recording or State.Transcribing or State.Deriving;
        _hotkey.Pressed += BeginRecording;
        _hotkey.Released += FinishRecording;
        _hotkey.Cancelled += CancelActiveDictation;

        // Both are cheap only because the verbatim transcript is always kept.
        _hotkey.UndoRequested += () => _ = UndoLastInsertionAsync(revertToVerbatim: false);
        _hotkey.RevertToVerbatimRequested += () => _ = UndoLastInsertionAsync(revertToVerbatim: true);
    }

    private readonly InsertionTracker _insertions = new();

    public bool CanUndo => _insertions.CanUndo;
    public bool CanRevertToVerbatim => _insertions.CanRevertToVerbatim;

    /// <summary>Takes the last insertion back out of the field it went into.</summary>
    public async Task UndoLastInsertionAsync(bool revertToVerbatim)
    {
        if (!_insertions.CanUndo) return;
        var undone = await _insertions.UndoAsync(revertToVerbatim, Short(_pendingId))
            .ConfigureAwait(false);
        if (!undone) return;

        DictationLog.Info(() => "insertion undone", new Dictionary<string, string>
        {
            ["dictation"] = Short(_pendingId),
            ["reverted"] = revertToVerbatim ? "to verbatim" : "removed",
        });
        Undone?.Invoke(revertToVerbatim ? "Reverted to what you said" : "Insertion removed");
    }

    /// <summary>An insertion was taken back, with what to say about it.</summary>
    public event Action<string>? Undone;

    public bool Start()
    {
        ReloadHotkey();
        return _hotkey.Start();
    }

    public void ReloadHotkey()
    {
        _hotkey.Stop();
        _hotkey.Key = _settings.Trigger;
        _hotkey.SecondaryKey = _settings.SecondaryTrigger;
        _hotkey.RecordingMode = _settings.HotkeyMode;
        _hotkey.CancelKey = _settings.CancelShortcut;
        _hotkey.Start();
    }

    public void Dispose()
    {
        _hotkey.Dispose();
        _recorder.Dispose();
        _groundingCts?.Dispose();
        _dictationCts?.Cancel();
        _dictationCts?.Dispose();
    }

    // ---- Recording ---------------------------------------------------------------------------

    /// <summary>Opens the connection the dictation about to be recorded will need.</summary>
    /// <remarks>
    /// Nothing here needs the prompt directory or the history — only which host the audio is going
    /// to — and this runs on the key-down path, so it builds the provider and nothing else.
    ///
    /// <para>Silent on failure by design: nothing has been asked for yet, so there is nothing to
    /// report. A dead connection found here is replaced and the user never learns it happened.</para>
    /// </remarks>
    private void WarmUpConnection()
    {
        try
        {
            var key = _settings.ResolvedApiKey();
            if (string.IsNullOrEmpty(key)) return;
            var origin = ProviderFactory
                .Create(_settings.Provider, key, _settings.Model)
                .EndpointOrigin;
            if (origin is null) return;
            _ = Task.Run(() => ProviderTransport.WarmUpAsync(origin));
        }
        catch (Exception)
        {
            // A backend that cannot even be constructed is a problem for the dictation to report,
            // with a message written for it. Warm-up has nothing to add.
        }
    }

    private void BeginRecording()
    {
        if (Current != State.Idle) return;

        try
        {
            _recorder.PreferredDeviceName = _settings.MicrophoneName;
            InteractionSounds.Enabled = _settings.InteractionSounds;
            _recorder.Start();
            InteractionSounds.PlayStart();
            SetState(State.Recording);

            // One id from the key press to the insertion, on every line and on the history row.
            // Without it a log with three dictations in it is three interleaved stories, and the
            // question being asked is always about one of them.
            _pendingId = Guid.NewGuid();
            _pendingStyle = _hotkey.UsedSecondary && _settings.SecondaryTrigger is not null
                ? _settings.SecondaryStyle
                : RewriteStyle.Verbatim;
            // Where the words are meant to go, decided now rather than when they arrive.
            Interop.GetWindowThreadProcessId(Interop.GetForegroundWindow(), out var targetPid);
            _pendingTarget = targetPid == 0 ? null : (targetPid, Interop.ForegroundWindowTitle());

            DictationLog.Info(() => "recording started", new Dictionary<string, string>
            {
                ["dictation"] = Short(_pendingId),
                ["style"] = _pendingStyle.Id(),
                ["mode"] = _settings.HotkeyMode.ToString(),
                ["trigger"] = _settings.Trigger.ToString(),
                ["provider"] = _settings.Provider.ToString(),
                ["model"] = _settings.Model,
                ["fidelity"] = _settings.Fidelity.Id(),
                ["grounding"] = _settings.GroundingEnabled ? "on" : "off",
            });

            // The same trick as the screen capture below, for the network. Opening a connection
            // costs about a second and whether the pooled one is still alive cannot be known
            // without using it, so both happen here rather than after the key comes up with
            // somebody watching. See ProviderTransport.
            WarmUpConnection();

            // Phase 1: cheap, synchronous, before focus can move.
            _pendingContext = _settings.GroundingEnabled ? _screen.CaptureIdentity() : null;

            if (_pendingContext is not null
                && _settings.IsBlocked(_pendingContext.AppName, _pendingContext.BrowserUrl))
            {
                _pendingContext = null;
            }
            else if (_pendingContext is not null)
            {
                // Phase 2: the expensive walk, running while the user is still speaking.
                _groundingCts = new CancellationTokenSource(TimeSpan.FromMilliseconds(700));
                var token = _groundingCts.Token;
                _fullCapture = Task.Run(() => _screen.CaptureFull(token), token);
            }
        }
        catch (MicrophoneUnavailableException error)
        {
            // Windows has no permission prompt for the microphone: access is a toggle somebody has
            // to find, which makes opening the page the whole of the guidance. Once per run — the
            // second time it opens it is no longer help, it is an argument.
            DictationLog.Error(() => "cannot record", new Dictionary<string, string>
            {
                ["dictation"] = Short(_pendingId),
                ["detail"] = error.Message,
                ["fixable"] = error.CanBeFixedInSettings ? "in Settings" : "no device",
            });

            if (error.CanBeFixedInSettings && !_openedMicrophoneSettings)
            {
                _openedMicrophoneSettings = true;
                OpenSettingsPage(MicrophoneUnavailableException.SettingsUri);
                Fail($"{error.Message} Opening Settings…");
            }
            else
            {
                Fail(error.Message);
            }
        }
        catch (InvalidOperationException error)
        {
            Fail(error.Message);
        }
    }

    private bool _openedMicrophoneSettings;

    /// <summary>Opens a `ms-settings:` page, which needs the shell rather than a plain start.</summary>
    private static void OpenSettingsPage(string uri)
    {
        try
        {
            System.Diagnostics.Process.Start(
                new System.Diagnostics.ProcessStartInfo(uri) { UseShellExecute = true });
        }
        catch (Exception error)
        {
            DictationLog.Warn(
                () => "could not open the settings page",
                new Dictionary<string, string> { ["uri"] = uri, ["error"] = error.Message });
        }
    }

    private void CancelRecording()
    {
        if (Current != State.Recording) return;
        _recorder.Cancel();
        _groundingCts?.Cancel();
        _pendingContext = null;
        SetState(State.Idle);
    }

    private void CancelActiveDictation()
    {
        if (Current == State.Recording)
        {
            CancelRecording();
            return;
        }
        if (Current is not (State.Transcribing or State.Deriving)) return;

        DictationLog.Info(
            () => "transcription cancellation requested",
            new Dictionary<string, string> { ["dictation"] = Short(_pendingId) });
        if (_dictationCts is { } cancellation) _ = cancellation.CancelAsync();
    }

    private async void FinishRecording()
    {
        if (Current != State.Recording) return;

        var wav = _recorder.Stop();
        InteractionSounds.PlayStop();
        if (wav is null)
        {
            // A tap rather than a hold. Not worth interrupting anyone over — but logged, because
            // "I pressed the key and nothing happened" is a real report and this is the most
            // common innocent explanation for it.
            DictationLog.Info(
                () => "recording too short to send",
                new Dictionary<string, string> { ["dictation"] = Short(_pendingId) });
            _groundingCts?.Cancel();
            SetState(State.Idle);
            return;
        }

        // Nothing without speech in it is ever sent. A model handed room tone does not reliably
        // return silence — it returns a plausible sentence, and a dictation tool that types words
        // nobody said has done the one thing this project exists to prevent. PROMPT.md rule 7 asks
        // for an empty transcript, but it only reaches model providers: a speech recogniser has no
        // system instruction, so for Deepgram, xAI and Voxtral the rule is never sent at all. Not
        // transmitting the audio is the only defence that holds for every backend.
        var activity = SpeechActivity.MeasureWav(wav);
        if (!activity.HasSpeech)
        {
            DictationLog.Info(
                () => "nothing was said, so nothing was sent",
                new Dictionary<string, string>
                {
                    ["dictation"] = Short(_pendingId),
                    ["audio"] = activity.Summary,
                });
            _groundingCts?.Cancel();
            SetState(State.Idle);
            return;
        }

        DictationLog.Info(() => "recording finished", new Dictionary<string, string>
        {
            ["dictation"] = Short(_pendingId),
            ["bytes"] = wav.Length.ToString(),
            ["seconds"] = AudioChunker.DurationSeconds(wav).ToString("F2"),
            ["audio"] = activity.Summary,
        });

        SetState(State.Transcribing);
        var cancellation = new CancellationTokenSource();
        _dictationCts = cancellation;
        try
        {
            await TranscribeAsync(wav, cancellation.Token).ConfigureAwait(false);
        }
        finally
        {
            if (ReferenceEquals(_dictationCts, cancellation)) _dictationCts = null;
            cancellation.Dispose();
        }
    }


    /// <summary>
    /// Wraps the configured primary with a fallback, when one is set. Built per dictation because
    /// the provider, its key and the delay are all live settings.
    /// </summary>
    private FallbackTranscriber BuildTranscriber(
        TranscriptionService primary, byte[] wav, ScreenContext? context)
    {
        Task<TranscriptionResult> RunPrimary(CancellationToken token) =>
            primary.TranscribeLongAsync(
                wav, context,
                onProgress: (done, total) => ChunkProgress?.Invoke(done, total),
                cancellationToken: token);

        var kind = _settings.ResolvedFallbackProvider();
        var key = kind is null
            ? null
            : _settings.KeyFor(kind.Value)
                ?? Environment.GetEnvironmentVariable(kind.Value.ApiKeyEnvVar());
        // Through the store, not the shipped directory: a fallback that sent the shipped contract
        // while the primary sent an edited one would make the two disagree about the only files
        // that matter, and which one you got would depend on whether the first request timed out.
        var promptPath = PromptBuilder.FindPromptDirectory();

        if (kind is null || string.IsNullOrEmpty(key) || promptPath is null)
        {
            return new FallbackTranscriber(
                RunPrimary, primary.Provider.Name, primary.Provider.Model);
        }

        var secondary = new TranscriptionService(
            ProviderFactory.Create(kind.Value, key, _settings.ModelFor(kind.Value)),
            Prompt(promptPath).SystemInstruction(_settings.Fidelity))
        {
            Fidelity = _settings.Fidelity,
            KeytermBiasing = _settings.KeytermBiasing,
        };

        Task<TranscriptionResult> RunSecondary(CancellationToken token) =>
            secondary.TranscribeLongAsync(wav, context, cancellationToken: token);

        return new FallbackTranscriber(
            RunPrimary, primary.Provider.Name, primary.Provider.Model,
            RunSecondary, secondary.Provider.Name, secondary.Provider.Model,
            _settings.ResolvedFallbackDelay());
    }

    /// <summary>
    /// The context as it should be written to the history index: everything except the screenshot.
    /// </summary>
    /// <remarks>
    /// The index is one JSON file, read whole at launch. A PNG base64'd into every row would make
    /// its size a function of how many dictations somebody has ever made, and "keep history
    /// forever" is the default. Windows has no screenshot fallback today so this strips nothing —
    /// it is here so that adding one later cannot quietly turn the index into a hundred megabytes.
    /// When that fallback arrives the image should go beside the audio, as a file the row points
    /// at, which is the pattern <see cref="DictationRecord.AudioFileName"/> already uses.
    /// </remarks>
    private static ScreenContext? ForStorage(ScreenContext? context)
    {
        if (context is null) return null;
        if (context.ScreenshotPng is null) return context;

        return new ScreenContext
        {
            AppName = context.AppName,
            WindowTitle = context.WindowTitle,
            BrowserUrl = context.BrowserUrl,
            Role = context.Role,
            IsEditable = context.IsEditable,
            VisibleText = context.VisibleText,
            TextBeforeCaret = context.TextBeforeCaret,
            TextAfterCaret = context.TextAfterCaret,
            SelectedText = context.SelectedText,
        };
    }

    private async Task TranscribeAsync(byte[] wav, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        // Snapshotted, not read live. Nothing today can change it mid-flight — a press while a
        // transcription is running is refused — but this method is long and the field is set by a
        // keyboard hook, and "the style changed under us" is not a bug anybody would find twice.
        var style = _pendingStyle;
        var context = MergeContext();

        var key = _settings.ResolvedApiKey();
        if (string.IsNullOrEmpty(key))
        {
            Fail("No API key. Open Settings to add one.");
            return;
        }

        var provider = ProviderFactory.Create(_settings.Provider, key, _settings.Model);
        var promptPath = PromptBuilder.FindPromptDirectory();
        if (promptPath is null)
        {
            Fail("The prompt/ directory is missing next to the executable.");
            return;
        }

        var service = new TranscriptionService(
            provider, Prompt(promptPath).SystemInstruction(_settings.Fidelity))
        {
            // Carried separately as well as baked into the prompt, because a recognition backend
            // has no system instruction to read it out of.
            Fidelity = _settings.Fidelity,
            KeytermBiasing = _settings.KeytermBiasing,
        };

        // From here, not from the request: reading the screen and any retry are both time the
        // user spends watching the overlay, and a figure that skipped them would flatter the app.
        var releasedAt = Stopwatch.GetTimestamp();
        var record = new DictationRecord
        {
            Id = _pendingId,
            Model = _settings.Model,
            Fidelity = _settings.Fidelity,
            AppName = context?.AppName,
            WindowTitle = context?.WindowTitle,
            Context = ForStorage(context),
            DurationSeconds = AudioRecorder.DurationSeconds(wav),
        };

        DictationLog.Info(() => "transcribing", new Dictionary<string, string>
        {
            ["dictation"] = Short(_pendingId),
            ["provider"] = _settings.Provider.ToString(),
            ["model"] = _settings.Model,
            ["fidelity"] = _settings.Fidelity.Id(),
            ["seconds"] = record.DurationSeconds.ToString("F2"),
            ["grounded"] = context is null ? "no" : "yes",
            ["contextChars"] = (context?.VisibleText?.Length ?? 0).ToString(),
            ["app"] = context?.AppName ?? "?",
        });

        try
        {
            var requestStart = Stopwatch.GetTimestamp();
            // Long recordings split across concurrent requests; short ones -- every ordinary
            // dictation -- take the single-request path unchanged.
            // Hedged when a fallback backend is configured: the primary gets the whole delay to
            // itself, and only a stalled one is ever raced. See FallbackTranscriber.
            var outcome = await BuildTranscriber(service, wav, context)
                .TranscribeAsync(cancellationToken)
                .ConfigureAwait(false);
            cancellationToken.ThrowIfCancellationRequested();
            var result = outcome.Result;
            // Recorded as the backend that answered, not the one that was asked: a history row
            // naming the wrong one would make history useless for the comparisons it exists for.
            record.Model = outcome.Attribution.Model;
            record.RequestSeconds = Stopwatch.GetElapsedTime(requestStart).TotalSeconds;
            record.AudioTokens = result.Usage.AudioTokens;
            var text = result.Transcript.Text.Trim();

            DictationLog.Info(() => "transcript received", new Dictionary<string, string>
            {
                ["dictation"] = Short(_pendingId),
                ["chars"] = text.Length.ToString(),
                ["language"] = result.Transcript.Language ?? string.Empty,
                ["chunks"] = result.ChunkCount.ToString(),
                ["audioTokens"] = result.Usage.AudioTokens?.ToString() ?? "unreported",
                ["model"] = outcome.Attribution.Model,
                ["hedged"] = outcome.Attribution.Model == _settings.Model ? "no" : "yes",
                ["ms"] = ((long)Stopwatch.GetElapsedTime(requestStart).TotalMilliseconds).ToString(),
            });
            DictationLog.Content("transcript", () => text, LogLevel.Trace);

            if (text.Length == 0)
            {
                // Not an error, and the one outcome people report as one: the key worked, the
                // request worked, and nothing was said.
                DictationLog.Info(
                    () => "nothing was said",
                    new Dictionary<string, string> { ["dictation"] = Short(_pendingId) });
                SetState(State.Idle); // silence in, nothing out
                return;
            }

            record.Status = DictationStatus.Completed;
            record.Text = text;

            // A rewrite is a second pass over a transcript that already exists, so the verbatim
            // version is stored either way and "what did I actually say" stays answerable.
            var delivered = text;
            var rewriteFailed = false;
            if (style.IsRewrite())
            {
                var mode = TranscriptMode.Rewrite(style);
                var instruction = Prompt(promptPath).SecondStageInstruction(mode);
                if (instruction is not null)
                {
                    SetState(State.Deriving);
                    var rewriteStart = Stopwatch.GetTimestamp();
                    DictationLog.Info(() => "second stage", new Dictionary<string, string>
                    {
                        ["dictation"] = Short(_pendingId),
                        ["style"] = style.Id(),
                        ["chars"] = text.Length.ToString(),
                    });
                    try
                    {
                        var styled = await service.RewriteAsync(
                                text, instruction, cancellationToken)
                            .ConfigureAwait(false);
                        cancellationToken.ThrowIfCancellationRequested();
                        record.StyledText = styled;
                        record.Mode = mode.Id;
                        delivered = styled;
                        DictationLog.Info(
                            () => "second stage finished",
                            new Dictionary<string, string>
                            {
                                ["dictation"] = Short(_pendingId),
                                ["chars"] = styled.Length.ToString(),
                                ["from"] = text.Length.ToString(),
                                ["ms"] = ((long)Stopwatch.GetElapsedTime(rewriteStart)
                                    .TotalMilliseconds).ToString(),
                            });
                    }
                    catch (OperationCanceledException)
                        when (cancellationToken.IsCancellationRequested)
                    {
                        throw;
                    }
                    catch (Exception error)
                        when (error is ProviderException or HttpRequestException
                            or TaskCanceledException)
                    {
                        rewriteFailed = true;
                        // The words survive either way, so this is a warning rather than a
                        // failure — but it is said out loud, because a rewrite that fails every
                        // time should not be indistinguishable from one never asked for.
                        DictationLog.Warn(
                            () => "second stage failed, delivering the verbatim transcript",
                            new Dictionary<string, string>
                            {
                                ["dictation"] = Short(_pendingId),
                                ["style"] = style.Id(),
                                ["detail"] = FailureAdvice.Detail(error),
                            });
                    }
                    record.RewriteSeconds = Stopwatch.GetElapsedTime(rewriteStart).TotalSeconds;
                }
            }

            cancellationToken.ThrowIfCancellationRequested();
            record.LatencySeconds = Stopwatch.GetElapsedTime(releasedAt).TotalSeconds;
            _history.Insert(record, _settings.KeepAudio ? wav : null);
            HistoryChanged?.Invoke();

            SetState(State.Idle);

            // Where the user was looking when they spoke, not where they are looking now.
            //
            // The paste goes to whatever holds focus at the moment it fires, which is the right
            // answer only if that is still the same place. It stopped being the same place every
            // time a dictation took a minute: the user gave up waiting and moved on, and the
            // transcript arrived in whatever they had moved on to. On macOS, where this was found,
            // that put 172 and 292 characters of speech into the app's own settings window.
            //
            // Nothing is lost when this fires -- the transcript is already in the history and on
            // the clipboard, one keystroke from where it was going.
            Interop.GetWindowThreadProcessId(Interop.GetForegroundWindow(), out var focusedNow);
            if (_pendingTarget is { } expected && focusedNow != 0 && focusedNow != expected.Pid)
            {
                TextInjector.CopyForManualPaste(delivered, Short(_pendingId));
                DictationLog.Warn(
                    () => "focus moved while transcribing; not typing into a window the user did not dictate into",
                    new Dictionary<string, string>
                    {
                        ["dictation"] = Short(_pendingId),
                        ["spokeInto"] = expected.Title.Length == 0 ? "untitled" : expected.Title,
                        ["nowFocused"] = Interop.ForegroundWindowTitle(),
                        ["waitedMs"] = ((long)Stopwatch.GetElapsedTime(releasedAt).TotalMilliseconds)
                            .ToString(),
                    });
                _insertions.Record(record.Id, delivered, text);
                Fail("Copied — press Ctrl+V. You left that window while it was transcribing.");
                return;
            }

            await TextInjector.InsertAsync(delivered, Short(_pendingId)).ConfigureAwait(false);
            // The failure is carried out rather than left to be noticed. The words landed either
            // way, but somebody who held the rewrite key and got their own words back should be
            // told that is what happened — most often because the backend is a recogniser, which
            // cannot rewrite text at all.
            _insertions.Record(record.Id, delivered, text);
            Inserted?.Invoke(new Insertion(delivered.Length, rewriteFailed));
            DictationLog.Info(() => "dictation complete", new Dictionary<string, string>
            {
                ["dictation"] = Short(_pendingId),
                ["chars"] = delivered.Length.ToString(),
                ["totalMs"] = ((long)Stopwatch.GetElapsedTime(releasedAt).TotalMilliseconds)
                    .ToString(),
            });
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            DictationLog.Info(
                () => "transcription cancelled",
                new Dictionary<string, string> { ["dictation"] = Short(_pendingId) });
            SetState(State.Idle);
        }
        catch (Exception error) when (error is ProviderException or HttpRequestException or TaskCanceledException)
        {
            // The recording is kept so this can be retried from the history window, or
            // automatically at the next launch. A failed dictation is not lost work.
            //
            // What is stored is the advice rather than the exception. A history row that reads
            // `HTTP 429: {"error":{"code":"rate_limit_exceeded"…` is a log line somebody has to
            // decode weeks later; the advice says what happened and whether it is worth retrying.
            var advice = FailureAdvice.Describe(error);
            var detail = FailureAdvice.Detail(error);

            // The whole thing, in the log, on one record. Whatever the interface shows, this is
            // what somebody diagnosing it has to be able to read.
            DictationLog.Error(() => "transcription failed", new Dictionary<string, string>
            {
                ["advice"] = advice.Message,
                ["queued"] = advice.IsQueued ? "yes" : "no",
                ["retryable"] = advice.IsRetryable ? "yes" : "no",
                ["provider"] = _settings.Provider.ToString(),
                ["model"] = _settings.Model,
                ["dictation"] = Short(_pendingId),
                ["detail"] = detail,
            });

            record.Status = DictationStatus.Failed;
            record.ErrorMessage = advice.Message;
            record.ErrorDetail = detail;
            _history.Insert(record, wav);
            HistoryChanged?.Invoke();

            Fail(advice.Message);
        }
    }

    /// <summary>Phase 1 wins on the fields it captured, having been taken before focus could move.</summary>
    private ScreenContext? MergeContext()
    {
        var identity = _pendingContext;
        _pendingContext = null;

        if (identity is null || _fullCapture is null) return identity;

        ScreenContext full;
        try
        {
            full = _fullCapture.GetAwaiter().GetResult();
        }
        catch (Exception e) when (e is OperationCanceledException or AggregateException)
        {
            return identity;
        }
        finally
        {
            _fullCapture = null;
            _groundingCts?.Dispose();
            _groundingCts = null;
        }

        full.AppName ??= identity.AppName;
        full.WindowTitle ??= identity.WindowTitle;
        full.Role ??= identity.Role;
        full.IsEditable ??= identity.IsEditable;
        full.SelectedText ??= identity.SelectedText;

        // The URL is only known after the walk, so the blocklist gets a second look.
        return _settings.IsBlocked(full.AppName, full.BrowserUrl) ? null : full;
    }

    // ---- Retry -------------------------------------------------------------------------------

    /// <summary>Reissues one stored dictation.</summary>
    public async Task<bool> RetryAsync(DictationRecord record)
    {
        var key = _settings.ResolvedApiKey();
        var promptPath = PromptBuilder.FindPromptDirectory();
        if (string.IsNullOrEmpty(key) || promptPath is null) return false;

        var wav = _history.AudioFor(record);
        if (wav is null)
        {
            record.ErrorMessage = "The recording is no longer on disk.";
            _history.Update(record);
            return false;
        }

        record.RetryCount++;
        var service = new TranscriptionService(
            ProviderFactory.Create(_settings.Provider, key, _settings.Model),
            Prompt(promptPath).SystemInstruction(record.Fidelity));


        try
        {
            // The context the original request carried, not none. A retry that drops it is a
            // different request from the one that failed — ungrounded, on a row that still names
            // the same provider and model — so a transcript that comes back worse looks like the
            // backend having a bad day rather than like the retry having asked a different
            // question. Null for rows written before contexts were stored, and for dictations that
            // were never grounded, which is the same thing as far as the request is concerned.
            var result = await service.TranscribeAsync(wav, record.Context).ConfigureAwait(false);
            record.Status = DictationStatus.Completed;
            record.Text = result.Transcript.Text.Trim();
            record.ErrorMessage = null;
            _history.Update(record);
            HistoryChanged?.Invoke();
            return true;
        }
        catch (Exception error) when (error is ProviderException or HttpRequestException or TaskCanceledException)
        {
            record.Status = DictationStatus.Failed;
            record.ErrorMessage = FailureAdvice.Describe(error).Message;
            record.ErrorDetail = FailureAdvice.Detail(error);
            _history.Update(record);
            HistoryChanged?.Invoke();
            return false;
        }
    }

    /// <summary>
    /// Drains everything that failed while the network was down. Sequential on purpose: firing a
    /// backlog concurrently is the fastest way to turn it into a rate-limited one.
    /// </summary>
    public async Task<(int Succeeded, int Failed)> RetryAllAsync()
    {
        var succeeded = 0;
        var failed = 0;
        foreach (var record in _history.Retryable())
        {
            if (await RetryAsync(record).ConfigureAwait(false)) succeeded++; else failed++;
        }
        return (succeeded, failed);
    }

    // ---- State -------------------------------------------------------------------------------

    private void SetState(State state)
    {
        Current = state;
        if (state != State.Failed) LastError = null;
        StateChanged?.Invoke(state);
    }

    private void Fail(string message)
    {
        LastError = message;
        Current = State.Failed;
        StateChanged?.Invoke(State.Failed);
    }
}
