using System.Threading.Channels;
using DoNotType.Core;

namespace DoNotType.App;

/// <summary>Transcribes pause-finalised, Silero-qualified parts while capture continues.</summary>
internal sealed class LiveDictationSession : IDisposable, IAsyncDisposable
{
    private readonly Channel<byte[]> _audio = Channel.CreateUnbounded<byte[]>(
        new UnboundedChannelOptions { SingleReader = true, SingleWriter = true });
    private readonly Func<byte[], ScreenContext?, CancellationToken,
        Task<FallbackTranscriber.Outcome>> _transcribe;
    private readonly string _primaryName;
    private readonly string _primaryModel;
    private readonly AudioChunker.StreamingSegmenter _segmenter = new();
    private readonly SemaphoreSlim _permits = new(3);
    private readonly CancellationTokenSource _cancel = new();
    private readonly SortedDictionary<int, Task<FallbackTranscriber.Outcome?>> _tasks = [];
    private readonly object _contextGate = new();
    private readonly object _lifecycleGate = new();
    private readonly TaskCompletionSource _finishCompleted =
        new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly Task _worker;
    private ScreenContext? _context;
    private bool _finished;
    private bool _cancelled;
    private bool _finishStarted;
    private bool _disposeStarted;
    private Task? _cleanup;

    private static readonly Log LiveLog = new("live");

    public LiveDictationSession(
        Func<byte[], ScreenContext?, CancellationToken, Task<FallbackTranscriber.Outcome>> transcribe,
        string primaryName,
        string primaryModel)
    {
        _transcribe = transcribe;
        _primaryName = primaryName;
        _primaryModel = primaryModel;
        _worker = ConsumeAsync();
    }

    public void Append(byte[] pcm)
    {
        lock (_lifecycleGate)
        {
            if (!_finished) _audio.Writer.TryWrite(pcm);
        }
    }

    public void SetContext(ScreenContext? context)
    {
        lock (_contextGate) _context = context;
    }

    public async Task<FallbackTranscriber.Outcome> FinishAsync(ScreenContext? context)
    {
        SetContext(context);
        lock (_lifecycleGate)
        {
            ObjectDisposedException.ThrowIf(_disposeStarted, this);
            if (_finishStarted)
            {
                throw new InvalidOperationException("This live dictation is already finishing.");
            }
            _finishStarted = true;
            CompleteAudioUnderLifecycleGate();
        }

        try
        {
            await _worker.ConfigureAwait(false);
            if (_segmenter.Finish() is { } tail) Submit(tail);

            var outcomes = (await Task.WhenAll(_tasks.Values).ConfigureAwait(false))
                .Where(outcome => outcome is not null)
                .Select(outcome => outcome!.Value)
                .ToArray();
            var results = outcomes.Select(outcome => outcome.Result).ToArray();
            var result = new TranscriptionResult(
                new Transcript(
                    AudioChunker.Stitch(results.Select(piece => piece.Transcript.Text)),
                    results.FirstOrDefault()?.Transcript.Language ?? string.Empty),
                results.Aggregate(
                    new TokenUsage(), (total, piece) => TokenUsage.Add(total, piece.Usage)),
                string.Join("\n", results.Select(piece => piece.RawOutput)),
                results.Length);
            return new FallbackTranscriber.Outcome(result, Attribution(outcomes));
        }
        finally
        {
            _finishCompleted.TrySetResult();
        }
    }

    public void Cancel()
    {
        lock (_lifecycleGate)
        {
            if (!_cancelled)
            {
                _cancelled = true;
                CompleteAudioUnderLifecycleGate();
                CancelSourceUnderLifecycleGate();
            }
        }
    }

    public void Dispose() => _ = BeginDispose();

    public async ValueTask DisposeAsync()
    {
        await BeginDispose().ConfigureAwait(false);
    }

    private Task BeginDispose()
    {
        lock (_lifecycleGate)
        {
            if (_cleanup is not null) return _cleanup;

            _disposeStarted = true;
            if (!_cancelled)
            {
                _cancelled = true;
                CompleteAudioUnderLifecycleGate();
                CancelSourceUnderLifecycleGate();
            }
            if (!_finishStarted) _finishCompleted.TrySetResult();
            return _cleanup = CleanupAsync(_finishStarted);
        }
    }

    private void CompleteAudioUnderLifecycleGate()
    {
        if (_finished) return;
        _finished = true;
        _audio.Writer.TryComplete();
    }

    private void CancelSourceUnderLifecycleGate()
    {
        try
        {
            _cancel.Cancel();
        }
        catch (Exception error)
        {
            // Cancellation callbacks belong to transports outside this class. A broken callback
            // cannot prevent the channel, worker and remaining requests from being observed and
            // released below.
            LiveLog.Warn(
                () => "a live transcription cancellation callback failed",
                new Dictionary<string, string>
                {
                    ["type"] = error.GetType().Name,
                    ["detail"] = error.Message,
                });
        }
    }

    private async Task CleanupAsync(bool finishOwned)
    {
        Exception? cleanupError = null;
        try
        {
            await _finishCompleted.Task.ConfigureAwait(false);
            try
            {
                await _worker.ConfigureAwait(false);
            }
            catch (Exception error)
            {
                cleanupError = error;
            }

            try
            {
                await Task.WhenAll(_tasks.Values).ConfigureAwait(false);
            }
            catch (Exception error)
            {
                cleanupError ??= error;
            }

            if (!finishOwned && cleanupError is not null
                && cleanupError is not OperationCanceledException)
            {
                LiveLog.Warn(
                    () => "abandoned live transcription failed during cleanup",
                    new Dictionary<string, string>
                    {
                        ["type"] = cleanupError.GetType().Name,
                        ["detail"] = cleanupError.Message,
                    });
            }
        }
        finally
        {
            _permits.Dispose();
            _cancel.Dispose();
        }
    }

    private async Task ConsumeAsync()
    {
        try
        {
            await foreach (var pcm in _audio.Reader.ReadAllAsync(_cancel.Token).ConfigureAwait(false))
            {
                foreach (var chunk in _segmenter.Append(pcm)) Submit(chunk);
            }
        }
        catch (OperationCanceledException) { }
    }

    private void Submit(AudioChunker.Chunk chunk)
    {
        ScreenContext? context;
        lock (_contextGate) context = _context;
        _tasks[chunk.Index] = TranscribeChunkAsync(chunk, context);
    }

    private async Task<FallbackTranscriber.Outcome?> TranscribeChunkAsync(
        AudioChunker.Chunk chunk, ScreenContext? context)
    {
        if (!SpeechActivity.MeasureWav(chunk.Data).HasSpeech) return null;
        await _permits.WaitAsync(_cancel.Token).ConfigureAwait(false);
        try
        {
            return await _transcribe(chunk.Data, context, _cancel.Token).ConfigureAwait(false);
        }
        finally
        {
            _permits.Release();
        }
    }

    private FallbackTranscriber.Attribution Attribution(
        IReadOnlyList<FallbackTranscriber.Outcome> outcomes)
    {
        if (outcomes.Count == 0)
        {
            return new FallbackTranscriber.Attribution(_primaryName, _primaryModel, false);
        }
        return new FallbackTranscriber.Attribution(
            string.Join(" + ", outcomes.Select(value => value.Attribution.Provider).Distinct()),
            string.Join(" + ", outcomes.Select(value => value.Attribution.Model).Distinct()),
            outcomes.Any(value => value.Attribution.WasFallback));
    }
}
