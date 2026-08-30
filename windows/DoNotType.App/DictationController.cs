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
        /// A compatibility second request. A different thing to be waiting on, and usually the
        /// slower of the two — the transcript already exists by then, so an overlay that still says
        /// "Transcribing…" is describing something that has finished. Short model-backed rewrites
        /// return both fields during transcription and never enter this state.
        /// </summary>
        Deriving,
        Failed,
    }

    private readonly AudioRecorder _recorder = new();
    private readonly HotkeyMonitor _hotkey = new();
    private readonly ScreenReader _screen = new();
    private readonly CorrectionObserver _corrections;
    private readonly HistoryStore _history;
    private readonly AppSettings _settings;

    private ScreenContext? _pendingContext;
    private CancellationTokenSource? _groundingCts;
    private CancellationTokenSource? _dictationCts;
    private Task<ScreenContext>? _fullCapture;
    private LiveDictationSession? _liveSession;
    private volatile bool _disposed;

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
    /// <summary>Latched only when Enter, rather than the normal trigger, ends the recording.</summary>
    private FinishAndSendAction _pendingFinishAndSend = FinishAndSendAction.Disabled;

    /// <summary>Which process was focused when the key went down, and its window title.</summary>
    /// <remarks>
    /// The process id rather than the title: two windows of the same app are the same target, and
    /// a title changes while the user works without the target having moved at all.
    /// </remarks>
    private (uint Pid, string Title)? _pendingTarget;
    private ScreenReader.FocusIdentity? _pendingFocusIdentity;

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
    public enum Submission
    {
        NotRequested,
        Sent,
        SkippedFocusMoved,
        SkippedUnavailable,
    }

    public sealed record Insertion(int Characters, bool RewriteFailed, Submission Submission);

    public event Action<Insertion>? Inserted;
    /// <summary>A harmless completed outcome that still needs to be visible to the user.</summary>
    public event Action<string>? Noticed;

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
    /// <summary>The configured dictation trigger was physically pressed or released.</summary>
    public event Action<bool>? TriggerHoldChanged;

    /// <summary>New spellings learned from an edit, exposed for an undo affordance.</summary>
    public event Action<IReadOnlyList<string>>? DictionaryLearned;

    public HistoryStore History => _history;
    public IReadOnlyList<AudioLevelMeter.Bar> DrainLevels() => _recorder.DrainLevels();
    public bool IsTriggerHeld => _hotkey.IsHeld;

    /// <summary>Whether the current recognition will submit after insertion.</summary>
    public bool WillSubmit => _pendingFinishAndSend != FinishAndSendAction.Disabled
        && Current is State.Transcribing or State.Deriving;

    public DictationController(AppSettings settings)
    {
        _settings = settings;
        _corrections = new CorrectionObserver(_screen);
        _history = new HistoryStore(HistoryStore.DefaultDirectory());
        _history.Configure(settings.Retention, settings.KeepAudio);
        _recorder.PcmCaptureFailed = _ =>
        {
            // Stop() waits for the capture worker holding the recorder lock, so this exchange is
            // complete before the finish path decides between live and post-recording modes.
            var failed = Interlocked.Exchange(ref _liveSession, null);
            failed?.Dispose();
        };

        _hotkey.IsRecording = () => Current == State.Recording;
        _hotkey.IsDictationActive = () =>
            Current is State.Recording or State.Transcribing or State.Deriving;
        _hotkey.Pressed += BeginRecording;
        _hotkey.Released += FinishRecording;
        _hotkey.HoldChanged += held => TriggerHoldChanged?.Invoke(held);
        _hotkey.Cancelled += CancelActiveDictation;
        _hotkey.FinishWithEnterRequested += FinishWithEnter;
        _hotkey.Faulted += HandleHotkeyFailure;

        // Both are cheap only because the verbatim transcript is always kept.
        _hotkey.UndoRequested += () => _ = UndoLastInsertionAsync(revertToVerbatim: false);
        _hotkey.RevertToVerbatimRequested += () => _ = UndoLastInsertionAsync(revertToVerbatim: true);
    }

    private readonly InsertionTracker _insertions = new();
    private IReadOnlyList<string> _lastLearnedTerms = [];

    public bool CanUndo => _insertions.CanUndo;
    public bool CanRevertToVerbatim => _insertions.CanRevertToVerbatim;
    public bool CanUndoDictionaryLearning => _lastLearnedTerms.Count > 0;

    public void UndoLastDictionaryLearning()
    {
        if (_lastLearnedTerms.Count == 0) return;
        _settings.ForgetLearnedDictionaryTerms(_lastLearnedTerms);
        _lastLearnedTerms = [];
    }
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
        _hotkey.FinishAndSendKey = _settings.FinishAndSendAction;
        _hotkey.Start();
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _hotkey.Dispose();
        _recorder.PcmCaptureFailed = null;
        _recorder.Dispose();
        AbandonLiveSession();
        _corrections.Dispose();
        _dictationCts?.Cancel();
        // The tasks using these sources own their disposal. Disposing a CTS while an HTTP request
        // is still unregistering its callback turns an ordinary app exit into a shutdown race.
        _groundingCts?.Cancel();
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
            _liveSession = CreateLiveSession();
            _recorder.PcmCaptured = _liveSession is null ? null : _liveSession.Append;
            _recorder.PreferredDeviceName = _settings.MicrophoneName;
            InteractionSounds.Enabled = _settings.InteractionSounds;
            _recorder.Start();
            InteractionSounds.PlayStart();
            SetState(State.Recording);

            // One id from the key press to the insertion, on every line and on the history row.
            // Without it a log with three dictations in it is three interleaved stories, and the
            // question being asked is always about one of them.
            _pendingId = Guid.NewGuid();
            _pendingFinishAndSend = FinishAndSendAction.Disabled;
            _pendingStyle = _hotkey.UsedSecondary && _settings.SecondaryTrigger is not null
                ? _settings.SecondaryStyle
                : RewriteStyle.Verbatim;
            // Where the words are meant to go, decided now rather than when they arrive.
            Interop.GetWindowThreadProcessId(Interop.GetForegroundWindow(), out var targetPid);
            _pendingTarget = targetPid == 0 ? null : (targetPid, Interop.ForegroundWindowTitle());
            _pendingFocusIdentity = _screen.CaptureFocusIdentity();

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
            _liveSession?.SetContext(_pendingContext);

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
                _ = _fullCapture.ContinueWith(
                    completed =>
                    {
                        if (completed.Status != TaskStatus.RanToCompletion) return;
                        var full = MergeCapturedContext(_pendingContext, completed.Result);
                        _liveSession?.SetContext(full);
                    },
                    CancellationToken.None,
                    TaskContinuationOptions.ExecuteSynchronously,
                    TaskScheduler.Default);
            }
        }
        catch (MicrophoneUnavailableException error)
        {
            AbandonLiveSession();
            _recorder.PcmCaptured = null;
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
            AbandonLiveSession();
            _recorder.PcmCaptured = null;
            Fail(error.Message);
        }
    }

    private bool _openedMicrophoneSettings;

    private void HandleHotkeyFailure(string message)
    {
        // The failing subscriber may have opened the microphone before it threw. Clean every
        // partially established resource so the visible "try again" instruction actually works.
        try
        {
            _recorder.Cancel();
        }
        catch (Exception error)
        {
            DictationLog.Warn(
                () => "could not clean up after a hotkey failure",
                new Dictionary<string, string> { ["detail"] = error.Message });
        }
        _recorder.PcmCaptured = null;
        AbandonLiveSession();
        _groundingCts?.Cancel();
        _pendingContext = null;
        _pendingFinishAndSend = FinishAndSendAction.Disabled;
        _pendingFocusIdentity = null;
        Fail(message);
    }

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

    /// <summary>Cancels a live fast path that no finish operation will take ownership of.</summary>
    private void AbandonLiveSession()
    {
        var abandoned = Interlocked.Exchange(ref _liveSession, null);
        // Dispose is deliberately non-blocking: it observes the worker and outstanding HTTP tasks,
        // then releases their CTS/semaphore only after those tasks have stopped using them.
        abandoned?.Dispose();
    }

    private void CancelRecording()
    {
        if (Current != State.Recording) return;
        _recorder.Cancel();
        _recorder.PcmCaptured = null;
        AbandonLiveSession();
        _groundingCts?.Cancel();
        _pendingContext = null;
        _pendingFinishAndSend = FinishAndSendAction.Disabled;
        _pendingFocusIdentity = null;
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
        _liveSession?.Cancel();
    }

    private void FinishWithEnter(FinishAndSendAction action)
    {
        if (Current != State.Recording) return;
        _pendingFinishAndSend = action;
        DictationLog.Info(() => "Enter finish requested", new Dictionary<string, string>
        {
            ["dictation"] = Short(_pendingId),
            ["action"] = action.ToString(),
        });
        FinishRecording();
    }

    /// <summary>
    /// Event-compatible shell around the asynchronous finish path.
    /// </summary>
    /// <remarks>
    /// Hotkey events are synchronous and cannot await a Task. Keeping the implementation itself as
    /// <c>async void</c> would send any exception thrown before the request-level handler directly
    /// to WinForms' unhandled-exception path and terminate the tray app. This shell starts a Task;
    /// <see cref="FinishRecordingAsync"/> contains the final safety boundary for that Task.
    /// </remarks>
    private void FinishRecording() => _ = FinishRecordingAsync();

    private async Task FinishRecordingAsync()
    {
        try
        {
            await FinishRecordingCoreAsync().ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            if (!_disposed) SetState(State.Idle);
        }
        catch (Exception error)
        {
            _groundingCts?.Cancel();
            AbandonLiveSession();
            _recorder.PcmCaptured = null;

            DictationLog.Error(
                () => "unexpected failure while finishing a dictation",
                new Dictionary<string, string>
                {
                    ["dictation"] = Short(_pendingId),
                    ["type"] = error.GetType().Name,
                    ["detail"] = FailureAdvice.Detail(error),
                });

            if (_disposed) return;
            var message = error switch
            {
                MicrophoneUnavailableException microphone => microphone.Message,
                ProviderException or HttpRequestException or TaskCanceledException =>
                    FailureAdvice.Describe(error).Message,
                _ => "Dictation failed unexpectedly. Try again; details are available in Logs.",
            };
            Fail(message);
        }
    }

    private async Task FinishRecordingCoreAsync()
    {
        if (Current != State.Recording) return;

        var wav = _recorder.Stop();
        _recorder.PcmCaptured = null;
        InteractionSounds.PlayStop();
        if (wav is null)
        {
            // A tap rather than a hold is not an error, but hiding the pill makes the gesture look
            // lost. Say what happened without turning the tray icon into a warning.
            DictationLog.Info(
                () => "recording too short to send",
                new Dictionary<string, string> { ["dictation"] = Short(_pendingId) });
            _groundingCts?.Cancel();
            AbandonLiveSession();
            Notice("Recording was too short — try again");
            return;
        }

        // Nothing without speech in it is ever sent. A model handed room tone does not reliably
        // return silence — it returns a plausible sentence, and a dictation tool that types words
        // nobody said has done the one thing this project exists to prevent. prompt/system.md rule 7 asks
        // for an empty transcript, but it only reaches model providers: a speech recogniser has no
        // system instruction, so for Deepgram, xAI and Voxtral the rule is never sent at all. Not
        // transmitting the audio is the only defence that holds for every backend.
        SpeechActivity.Reading activity;
        try
        {
            activity = SpeechActivity.MeasureWav(wav);
        }
        catch (Exception error)
        {
            _groundingCts?.Cancel();
            AbandonLiveSession();
            DictationLog.Error(
                () => "speech detector failed",
                new Dictionary<string, string>
                {
                    ["dictation"] = Short(_pendingId),
                    ["detail"] = error.Message,
                });
            Fail($"Speech detector failed: {error.Message}");
            return;
        }
        if (_liveSession is null && !activity.HasSpeech)
        {
            DictationLog.Info(
                () => "nothing was said, so nothing was sent",
                new Dictionary<string, string>
                {
                    ["dictation"] = Short(_pendingId),
                    ["audio"] = activity.Summary,
                });
            _groundingCts?.Cancel();
            Notice("No speech detected — recording wasn't sent");
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
        var finishAndSend = _pendingFinishAndSend;
        var submitTarget = _pendingFocusIdentity;
        var dictationId = _pendingId;
        var target = _pendingTarget;
        var live = _liveSession;
        var cancellation = new CancellationTokenSource();
        _dictationCts = cancellation;
        try
        {
            await TranscribeAsync(
                wav, live, cancellation.Token, finishAndSend, submitTarget, dictationId, target)
                .ConfigureAwait(false);
        }
        finally
        {
            // TranscribeAsync can return to Idle immediately before this continuation runs. Do not
            // clear a new recording's session if the user presses the hotkey in that small window.
            Interlocked.CompareExchange(ref _liveSession, null, live);
            if (ReferenceEquals(_dictationCts, cancellation)) _dictationCts = null;
            cancellation.Dispose();
        }
    }

    private LiveDictationSession? CreateLiveSession()
    {
        try
        {
            var key = _settings.ResolvedApiKey();
            var promptPath = PromptBuilder.FindPromptDirectory();
            if (string.IsNullOrEmpty(key) || promptPath is null) return null;

            var service = new TranscriptionService(
                ProviderFactory.Create(_settings.Provider, key, _settings.Model),
                Prompt(promptPath).SystemInstruction(
                    _settings.Fidelity, _settings.ChineseScript, _settings.FormattingSample))
            {
                Fidelity = _settings.Fidelity,
                Typography = _settings.TypographySpacing,
                KeytermBiasing = _settings.KeytermBiasing,
                PersonalDictionary = _settings.PersonalDictionaryTerms(),
            };
            return new LiveDictationSession(
                (wav, context, token) => BuildTranscriber(
                        service, wav, context, reportProgress: false)
                    .TranscribeAsync(token),
                service.Provider.Name,
                service.Provider.Model);
        }
        catch (Exception error)
        {
            DictationLog.Warn(
                () => "live transcription could not be prepared; using post-recording path",
                new Dictionary<string, string> { ["detail"] = error.Message });
            return null;
        }
    }


    /// <summary>
    /// Wraps the configured primary with a fallback, when one is set. Built per dictation because
    /// the provider, its key and the delay are all live settings.
    /// </summary>
    private FallbackTranscriber BuildTranscriber(
        TranscriptionService primary, byte[] wav, ScreenContext? context,
        bool reportProgress = true, StyledRequest? styled = null)
    {
        Task<TranscriptionResult> RunPrimary(CancellationToken token) =>
            primary.TranscribeLongAsync(
                wav, context,
                onProgress: reportProgress
                    ? (done, total) => ChunkProgress?.Invoke(done, total)
                    : null,
                cancellationToken: token, styled: styled);

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
            Prompt(promptPath).SystemInstruction(
                    _settings.Fidelity, _settings.ChineseScript, _settings.FormattingSample))
        {
            Fidelity = _settings.Fidelity,
            Typography = _settings.TypographySpacing,
            KeytermBiasing = _settings.KeytermBiasing,
            PersonalDictionary = _settings.PersonalDictionaryTerms(),
        };

        Task<TranscriptionResult> RunSecondary(CancellationToken token) =>
            secondary.TranscribeLongAsync(
                wav, context, cancellationToken: token, styled: styled);

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

    private async Task TranscribeAsync(
        byte[] wav,
        LiveDictationSession? liveSession,
        CancellationToken cancellationToken,
        FinishAndSendAction finishAndSend,
        ScreenReader.FocusIdentity? submitTarget,
        Guid dictationId,
        (uint Pid, string Title)? target)
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
            if (liveSession is not null) await liveSession.DisposeAsync().ConfigureAwait(false);
            Fail("No API key. Open Settings to add one.");
            return;
        }

        var provider = ProviderFactory.Create(_settings.Provider, key, _settings.Model);
        var promptPath = PromptBuilder.FindPromptDirectory();
        if (promptPath is null)
        {
            if (liveSession is not null) await liveSession.DisposeAsync().ConfigureAwait(false);
            Fail("The prompt/ directory is missing next to the executable.");
            return;
        }

        var service = new TranscriptionService(
            provider, Prompt(promptPath).SystemInstruction(
                    _settings.Fidelity, _settings.ChineseScript, _settings.FormattingSample))
        {
            // Carried separately as well as baked into the prompt, because a recognition backend
            // has no system instruction to read it out of.
            Fidelity = _settings.Fidelity,
            Typography = _settings.TypographySpacing,
            KeytermBiasing = _settings.KeytermBiasing,
            PersonalDictionary = _settings.PersonalDictionaryTerms(),
        };

        // From here, not from the request: reading the screen and any retry are both time the
        // user spends watching the overlay, and a figure that skipped them would flatter the app.
        var releasedAt = Stopwatch.GetTimestamp();
        var record = new DictationRecord
        {
            Id = dictationId,
            Model = _settings.Model,
            Fidelity = _settings.Fidelity,
            AppName = context?.AppName,
            WindowTitle = context?.WindowTitle,
            Context = ForStorage(context),
            DurationSeconds = AudioRecorder.DurationSeconds(wav),
        };

        DictationLog.Info(() => "transcribing", new Dictionary<string, string>
        {
            ["dictation"] = Short(dictationId),
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
            // A target language replaces the second stage rather than joining it. Two jobs in
            // one request is exactly the combination this project has already measured as worse,
            // and the settings window says so beside the rewrite picker.
            var stage = _settings.TranslateTo.Length > 0
                ? TranscriptMode.Translate(_settings.TranslateTo)
                : style.IsRewrite() ? TranscriptMode.Rewrite(style) : TranscriptMode.Verbatim;
            StyledRequest? folded = stage switch
            {
                TranscriptMode.RewriteMode rewriteStage =>
                    new StyledRequest.Style(Prompt(promptPath).StyleClause(rewriteStage.Style)),
                TranscriptMode.TranslateMode translateStage =>
                    new StyledRequest.Translation(translateStage.Language),
                _ => null,
            };
            // Long recordings split across concurrent requests; short ones -- every ordinary
            // dictation -- take the single-request path unchanged.
            // Hedged when a fallback backend is configured: the primary gets the whole delay to
            // itself, and only a stalled one is ever raced. See FallbackTranscriber.
            var outcome = liveSession is null
                ? await BuildTranscriber(service, wav, context, styled: folded)
                    .TranscribeAsync(cancellationToken).ConfigureAwait(false)
                : await liveSession.FinishAsync(context).ConfigureAwait(false);
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
                ["dictation"] = Short(dictationId),
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
                // Live segmentation can produce no Silero-qualified chunks, and a backend can
                // also return an empty transcript. Both need a visible outcome; returning to idle
                // immediately makes a successful key press look ignored.
                DictationLog.Info(
                    () => "nothing was said",
                    new Dictionary<string, string> { ["dictation"] = Short(dictationId) });
                Notice("No speech was transcribed");
                return;
            }

            record.Status = DictationStatus.Completed;
            record.Text = text;

            // Model providers can return the rewrite beside the verbatim transcript in the same
            // request. Recognition providers and older responses fall back to the existing text
            // stage, so the user-facing pair is identical whichever backend answered.
            var delivered = text;
            var rewriteFailed = false;
            if (stage.NeedsSecondPass)
            {
                var mode = stage;
                var instruction = Prompt(promptPath).SecondStageInstruction(mode);
                var styledInResponse = result.Transcript.Styled?.Trim();
                if (!string.IsNullOrWhiteSpace(styledInResponse))
                {
                    record.StyledText = styledInResponse;
                    record.Mode = mode.Id;
                    delivered = styledInResponse;
                    DictationLog.Info(() => "styled in one request", new Dictionary<string, string>
                    {
                        ["dictation"] = Short(dictationId),
                        ["mode"] = mode.Id,
                        ["chars"] = styledInResponse.Length.ToString(),
                        ["from"] = text.Length.ToString(),
                    });
                }
                else if (instruction is not null)
                {
                    SetState(State.Deriving);
                    var rewriteStart = Stopwatch.GetTimestamp();
                    DictationLog.Info(() => "second stage", new Dictionary<string, string>
                    {
                        ["dictation"] = Short(dictationId),
                        ["mode"] = mode.Id,
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
                                ["dictation"] = Short(dictationId),
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
                                ["dictation"] = Short(dictationId),
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
            if (target is { } expected && focusedNow != 0 && focusedNow != expected.Pid)
            {
                TextInjector.CopyForManualPaste(delivered, Short(dictationId));
                DictationLog.Warn(
                    () => "focus moved while transcribing; not typing into a window the user did not dictate into",
                    new Dictionary<string, string>
                    {
                        ["dictation"] = Short(dictationId),
                        ["spokeInto"] = expected.Title.Length == 0 ? "untitled" : expected.Title,
                        ["nowFocused"] = Interop.ForegroundWindowTitle(),
                        ["waitedMs"] = ((long)Stopwatch.GetElapsedTime(releasedAt).TotalMilliseconds)
                            .ToString(),
                    });
                _insertions.Record(record.Id, delivered, text);
                Fail("Copied — press Ctrl+V. You left that window while it was transcribing.");
                return;
            }

            var insertionTarget = _settings.LearnDictionaryFromEdits
                ? _screen.CaptureFocusedEditable()
                : null;
            await TextInjector.InsertAsync(delivered, Short(dictationId)).ConfigureAwait(false);
            // The failure is carried out rather than left to be noticed. The words landed either
            // way, but somebody who held the rewrite key and got their own words back should be
            // told that is what happened — most often because the backend is a recogniser, which
            // cannot rewrite text at all.
            _insertions.Record(record.Id, delivered, text);

            Submission submission;
            if (finishAndSend == FinishAndSendAction.Disabled)
            {
                submission = Submission.NotRequested;
            }
            else if (submitTarget is null)
            {
                submission = Submission.SkippedUnavailable;
                DictationLog.Warn(
                    () => "submission skipped because the original field could not be identified",
                    new Dictionary<string, string>
                    {
                        ["dictation"] = Short(dictationId),
                        ["action"] = finishAndSend.ToString(),
                    });
            }
            else if (_screen.CaptureFocusIdentity() != submitTarget)
            {
                submission = Submission.SkippedFocusMoved;
                DictationLog.Warn(
                    () => "submission skipped because focus moved after insertion",
                    new Dictionary<string, string>
                    {
                        ["dictation"] = Short(dictationId),
                        ["action"] = finishAndSend.ToString(),
                    });
            }
            else
            {
                submission = TextInjector.Submit(finishAndSend, Short(dictationId))
                    ? Submission.Sent
                    : Submission.SkippedUnavailable;
            }

            // A sent message is no longer editable. Keeping an undo or correction observer would
            // make it operate on whichever control the target app focuses after sending.
            if (submission == Submission.Sent)
            {
                _insertions.Clear();
            }
            else if (insertionTarget is not null)
            {
                _corrections.Watch(insertionTarget, delivered, candidates =>
                {
                    var added = _settings.LearnDictionaryTerms(candidates);
                    if (added.Count == 0) return;
                    _lastLearnedTerms = added;
                    DictionaryLearned?.Invoke(added);
                });
            }
            Inserted?.Invoke(new Insertion(delivered.Length, rewriteFailed, submission));
            DictationLog.Info(() => "dictation complete", new Dictionary<string, string>
            {
                ["dictation"] = Short(dictationId),
                ["chars"] = delivered.Length.ToString(),
                ["totalMs"] = ((long)Stopwatch.GetElapsedTime(releasedAt).TotalMilliseconds)
                    .ToString(),
                ["submission"] = submission.ToString(),
            });
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            DictationLog.Info(
                () => "transcription cancelled",
                new Dictionary<string, string> { ["dictation"] = Short(dictationId) });
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
                ["dictation"] = Short(dictationId),
                ["detail"] = detail,
            });

            record.Status = DictationStatus.Failed;
            record.ErrorMessage = advice.Message;
            record.ErrorDetail = detail;
            _history.Insert(record, wav);
            HistoryChanged?.Invoke();

            Fail(advice.Message);
        }
        finally
        {
            if (liveSession is not null) await liveSession.DisposeAsync().ConfigureAwait(false);
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

        return MergeCapturedContext(identity, full);
    }

    private ScreenContext? MergeCapturedContext(ScreenContext? identity, ScreenContext full)
    {
        if (identity is null) return null;
        full.AppName ??= identity.AppName;
        full.WindowTitle ??= identity.WindowTitle;
        full.Role ??= identity.Role;
        full.IsEditable ??= identity.IsEditable;
        full.SelectedText ??= identity.SelectedText;
        return _settings.IsBlocked(full.AppName, full.BrowserUrl) ? null : full;
    }

    // ---- Retry -------------------------------------------------------------------------------

    /// <summary>Transcribes one stored recording again.</summary>
    /// <remarks>
    /// Both the retry of a dictation that failed and the redo of one the user thinks came back
    /// wrong: the request is the same either way.
    /// </remarks>
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
            Prompt(promptPath).SystemInstruction(
                record.Fidelity, _settings.ChineseScript, _settings.FormattingSample))
        {
            Fidelity = record.Fidelity,
            Typography = _settings.TypographySpacing,
            KeytermBiasing = _settings.KeytermBiasing,
            PersonalDictionary = _settings.PersonalDictionaryTerms(),
        };


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
            record.ErrorDetail = null;
            // The rewrite beside it was derived from the transcript that has just been replaced,
            // so it goes with it. Keeping it would be worse than losing it: DeliveredText prefers
            // the styled version, so a redo of a rewritten dictation would replace the words and
            // still show the old ones -- a button that appears to do nothing.
            record.StyledText = null;
            record.Mode = TranscriptMode.Verbatim.Id;
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
        if (_disposed) return;
        Current = state;
        if (state != State.Failed) LastError = null;
        StateChanged?.Invoke(state);
    }

    private void Fail(string message)
    {
        if (_disposed) return;
        LastError = message;
        Current = State.Failed;
        StateChanged?.Invoke(State.Failed);
    }

    /// <summary>Reports a no-op without blocking the next hotkey press.</summary>
    private void Notice(string message)
    {
        if (_disposed) return;
        SetState(State.Idle);
        Noticed?.Invoke(message);
    }
}
