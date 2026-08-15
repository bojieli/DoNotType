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

    private IAudioUploader? _uploader;
    private ScreenContext? _pendingContext;
    private CancellationTokenSource? _groundingCts;
    private Task<ScreenContext>? _fullCapture;

    public State Current { get; private set; } = State.Idle;
    public string? LastError { get; private set; }

    /// <summary>Everything a dictation does, under one category so `dnt logs --grep` finds it.</summary>
    private static readonly Log DictationLog = new("dictate");

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
    public float Level => _recorder.Level;

    public DictationController(AppSettings settings)
    {
        _settings = settings;
        _history = new HistoryStore(HistoryStore.DefaultDirectory());
        _history.Configure(settings.Retention, settings.KeepAudio);

        _hotkey.IsRecording = () => Current == State.Recording;
        _hotkey.Pressed += BeginRecording;
        _hotkey.Released += FinishRecording;
        _hotkey.Cancelled += CancelRecording;
    }

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
        _hotkey.Start();
    }

    public void Dispose()
    {
        _hotkey.Dispose();
        _recorder.Dispose();
        _groundingCts?.Dispose();
    }

    // ---- Recording ---------------------------------------------------------------------------

    private void BeginRecording()
    {
        if (Current != State.Idle) return;

        try
        {
            _recorder.Start();
            SetState(State.Recording);

            // One id from the key press to the insertion, on every line and on the history row.
            // Without it a log with three dictations in it is three interleaved stories, and the
            // question being asked is always about one of them.
            _pendingId = Guid.NewGuid();
            _pendingStyle = _hotkey.UsedSecondary && _settings.SecondaryTrigger is not null
                ? _settings.SecondaryStyle
                : RewriteStyle.Verbatim;

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

            // Same trick for the network: opening the upload session now means the handshake is
            // paid for during recording rather than after it.
            if (_settings.ResolvedApiKey() is { Length: > 0 } key)
            {
                var provider = ProviderFactory.Create(_settings.Provider, key, _settings.Model);
                if (provider.SupportsPreUpload)
                {
                    _uploader = provider.CreateUploader();
                    _uploader?.Prepare(1_000_000);
                }
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
        _uploader?.Cancel();
        _uploader = null;
        _groundingCts?.Cancel();
        _pendingContext = null;
        SetState(State.Idle);
    }

    private async void FinishRecording()
    {
        if (Current != State.Recording) return;

        var wav = _recorder.Stop();
        if (wav is null)
        {
            // A tap rather than a hold. Not worth interrupting anyone over — but logged, because
            // "I pressed the key and nothing happened" is a real report and this is the most
            // common innocent explanation for it.
            DictationLog.Info(
                () => "recording too short to send",
                new Dictionary<string, string> { ["dictation"] = Short(_pendingId) });
            _uploader?.Cancel();
            _uploader = null;
            _groundingCts?.Cancel();
            SetState(State.Idle);
            return;
        }

        DictationLog.Info(() => "recording finished", new Dictionary<string, string>
        {
            ["dictation"] = Short(_pendingId),
            ["bytes"] = wav.Length.ToString(),
            ["seconds"] = AudioChunker.DurationSeconds(wav).ToString("F2"),
        });

        SetState(State.Transcribing);
        await TranscribeAsync(wav).ConfigureAwait(false);
    }


    /// <summary>
    /// Wraps the configured primary with a fallback, when one is set. Built per dictation because
    /// the provider, its key and the delay are all live settings.
    /// </summary>
    private FallbackTranscriber BuildTranscriber(
        TranscriptionService primary, byte[] wav, ScreenContext? context, InputPart? audioPart)
    {
        Task<TranscriptionResult> RunPrimary(CancellationToken token) =>
            primary.TranscribeLongAsync(
                wav, context, audioPart,
                onProgress: (done, total) => ChunkProgress?.Invoke(done, total),
                cancellationToken: token);

        var kind = _settings.ResolvedFallbackProvider();
        var key = kind is null
            ? null
            : _settings.KeyFor(kind.Value)
                ?? Environment.GetEnvironmentVariable(kind.Value.ApiKeyEnvVar());
        var promptPath = PromptBuilder.FindPromptFile();

        if (kind is null || string.IsNullOrEmpty(key) || promptPath is null)
        {
            return new FallbackTranscriber(
                RunPrimary, primary.Provider.Name, primary.Provider.Model);
        }

        var secondary = new TranscriptionService(
            ProviderFactory.Create(kind.Value, key, _settings.ModelFor(kind.Value)),
            PromptBuilder.FromFile(promptPath).SystemInstruction(_settings.Fidelity))
        {
            Fidelity = _settings.Fidelity,
            KeytermBiasing = _settings.KeytermBiasing,
        };

        // The pre-uploaded reference is Google's Files API and means nothing to another backend,
        // so the hedge always sends inline bytes.
        Task<TranscriptionResult> RunSecondary(CancellationToken token) =>
            secondary.TranscribeLongAsync(wav, context, null, cancellationToken: token);

        return new FallbackTranscriber(
            RunPrimary, primary.Provider.Name, primary.Provider.Model,
            RunSecondary, secondary.Provider.Name, secondary.Provider.Model,
            _settings.ResolvedFallbackDelay());
    }

    private async Task TranscribeAsync(byte[] wav)
    {
        var context = MergeContext();

        var key = _settings.ResolvedApiKey();
        if (string.IsNullOrEmpty(key))
        {
            Fail("No API key. Open Settings to add one.");
            return;
        }

        var provider = ProviderFactory.Create(_settings.Provider, key, _settings.Model);
        var promptPath = PromptBuilder.FindPromptFile();
        if (promptPath is null)
        {
            Fail("PROMPT.md is missing next to the executable.");
            return;
        }

        var service = new TranscriptionService(
            provider, PromptBuilder.FromFile(promptPath).SystemInstruction(_settings.Fidelity))
        {
            // Carried separately as well as baked into the prompt, because a recognition backend
            // has no system instruction to read it out of.
            Fidelity = _settings.Fidelity,
            KeytermBiasing = _settings.KeytermBiasing,
        };

        // From here, not from the request: reading the screen, a failed pre-upload and any retry
        // are all time the user spends watching the overlay, and a figure that skipped them would
        // flatter the app.
        var releasedAt = Stopwatch.GetTimestamp();
        var record = new DictationRecord
        {
            Id = _pendingId,
            Model = _settings.Model,
            Fidelity = _settings.Fidelity,
            AppName = context?.AppName,
            WindowTitle = context?.WindowTitle,
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
            // Pre-uploaded when the session opened and the upload landed; inline otherwise. The
            // fallback is silent by design: a flaky network should cost latency, never words.
            InputPart? audioPart = null;
            if (_uploader is not null)
            {
                try { audioPart = await _uploader.PlanAsync(wav).ConfigureAwait(false); }
                catch (ProviderException) { audioPart = null; }
                _uploader = null;
            }

            var requestStart = Stopwatch.GetTimestamp();
            // Long recordings split across concurrent requests; short ones -- every ordinary
            // dictation -- take the single-request path unchanged.
            // Hedged when a fallback backend is configured: the primary gets the whole delay to
            // itself, and only a stalled one is ever raced. See FallbackTranscriber.
            var outcome = await BuildTranscriber(service, wav, context, audioPart)
                .TranscribeAsync()
                .ConfigureAwait(false);
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
            if (_pendingStyle.IsRewrite())
            {
                var mode = TranscriptMode.Rewrite(_pendingStyle);
                var instruction = PromptBuilder.FromFile(promptPath).SecondStageInstruction(mode);
                if (instruction is not null)
                {
                    SetState(State.Deriving);
                    var rewriteStart = Stopwatch.GetTimestamp();
                    DictationLog.Info(() => "second stage", new Dictionary<string, string>
                    {
                        ["dictation"] = Short(_pendingId),
                        ["style"] = _pendingStyle.Id(),
                        ["chars"] = text.Length.ToString(),
                    });
                    try
                    {
                        var styled = await service.RewriteAsync(text, instruction)
                            .ConfigureAwait(false);
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
                                ["style"] = _pendingStyle.Id(),
                                ["detail"] = FailureAdvice.Detail(error),
                            });
                    }
                    record.RewriteSeconds = Stopwatch.GetElapsedTime(rewriteStart).TotalSeconds;
                }
            }

            record.LatencySeconds = Stopwatch.GetElapsedTime(releasedAt).TotalSeconds;
            _history.Insert(record, _settings.KeepAudio ? wav : null);
            HistoryChanged?.Invoke();

            SetState(State.Idle);
            await TextInjector.InsertAsync(delivered, Short(_pendingId)).ConfigureAwait(false);
            // The failure is carried out rather than left to be noticed. The words landed either
            // way, but somebody who held the rewrite key and got their own words back should be
            // told that is what happened — most often because the backend is a recogniser, which
            // cannot rewrite text at all.
            Inserted?.Invoke(new Insertion(delivered.Length, rewriteFailed));
            DictationLog.Info(() => "dictation complete", new Dictionary<string, string>
            {
                ["dictation"] = Short(_pendingId),
                ["chars"] = delivered.Length.ToString(),
                ["totalMs"] = ((long)Stopwatch.GetElapsedTime(releasedAt).TotalMilliseconds)
                    .ToString(),
            });
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
        var promptPath = PromptBuilder.FindPromptFile();
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
            PromptBuilder.FromFile(promptPath).SystemInstruction(record.Fidelity));


        try
        {
            var result = await service.TranscribeAsync(wav, null).ConfigureAwait(false);
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
            record.ErrorMessage = error.Message;
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
