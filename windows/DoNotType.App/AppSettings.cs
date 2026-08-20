using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using DoNotType.Core;

namespace DoNotType.App;

/// <summary>
/// Preferences and the API key.
///
/// The key is encrypted with DPAPI scoped to the current user, which is the Windows equivalent of
/// the macOS Keychain here: it cannot be read by another user account, and it never appears in
/// plaintext in the settings file.
/// </summary>
public sealed class AppSettings
{
    /// <summary>Raised when a change remains in memory but could not reach durable storage.</summary>
    public event Action<string>? SaveFailed;

    public ProviderKind Provider { get; set; } = ProviderFactory.DefaultForNewInstalls;
    public string Model { get; set; } = ProviderFactory.DefaultForNewInstalls.DefaultModel();
    public Fidelity Fidelity { get; set; } = Fidelity.Light;
    public HotkeyMonitor.Trigger Trigger { get; set; } = HotkeyMonitor.Trigger.RightControl;
    public HotkeyMonitor.Mode HotkeyMode { get; set; } = HotkeyMonitor.Mode.Automatic;
    public CancelShortcut CancelShortcut { get; set; } = DoNotType.Core.CancelShortcut.Escape;
    /// <summary>Off by default because the final key can send text to another person.</summary>
    public DoNotType.Core.FinishAndSendAction FinishAndSendAction { get; set; } =
        DoNotType.Core.FinishAndSendAction.Disabled;

    /// <summary>
    /// A second key that dictates and then rewrites, or null for one key and verbatim only.
    /// </summary>
    /// <remarks>
    /// Off by default. A rewrite changes the delivered wording, so it is opt-in — but when it is
    /// on, the choice is made by which key you hold, before speaking, rather than by a setting
    /// somebody has to remember they changed. Model-backed short dictations return both versions
    /// in one request; split or recognition paths retain the compatibility second stage.
    /// </remarks>
    public HotkeyMonitor.Trigger? SecondaryTrigger { get; set; }

    /// <summary>What the second key produces. Never verbatim: that is what the first key is for.</summary>
    public RewriteStyle SecondaryStyle { get; set; } = RewriteStyle.Casual;
    public bool GroundingEnabled { get; set; } = true;
    public RetentionPolicy Retention { get; set; } = RetentionPolicy.Forever;
    public bool KeepAudio { get; set; }

    /// <summary>
    /// Whether a recognition backend may be given a word list derived from the screen.
    ///
    /// Off by default, unlike <see cref="GroundingEnabled"/>, and the two are not one feature
    /// wearing different hats: grounding hands a model the screen text under an explicit
    /// "reference only" instruction, while a keyterm list is a bare vocabulary prior with no way
    /// to say that. See <see cref="Keyterms"/> for what it refuses to send.
    /// </summary>
    public bool KeytermBiasing { get; set; }

    /// <summary>Spellings explicitly entered or imported by the user.</summary>
    public List<string> DictionaryTerms { get; set; } = [];

    /// <summary>Spellings learned from edits after dictation, kept visible and removable.</summary>
    public List<string> LearnedDictionaryTerms { get; set; } = [];

    /// <summary>
    /// Opt-in because observing another application's text after insertion is more sensitive than
    /// storing a dictionary. Only spelling/capitalisation fixes are retained.
    /// </summary>
    public bool LearnDictionaryFromEdits { get; set; }

    public IReadOnlyList<string> PersonalDictionaryTerms()
    {
        lock (this)
        {
            NormalizeDictionary();
            return DoNotType.Core.PersonalDictionary.Sanitize(
                DictionaryTerms.Concat(LearnedDictionaryTerms));
        }
    }

    /// <summary>Adds learned spellings atomically and returns only entries that were actually new.</summary>
    public IReadOnlyList<string> LearnDictionaryTerms(IEnumerable<string> candidates)
    {
        lock (this)
        {
            NormalizeDictionary();
            var combined = DictionaryTerms.Concat(LearnedDictionaryTerms).ToList();
            var seen = new HashSet<string>(combined, StringComparer.OrdinalIgnoreCase);
            var added = new List<string>();
            foreach (var raw in candidates)
            {
                string term;
                try { term = DoNotType.Core.PersonalDictionary.Normalize(raw); }
                catch (DoNotType.Core.PersonalDictionary.ValidationException) { continue; }
                if (combined.Count >= DoNotType.Core.PersonalDictionary.MaxTerms || !seen.Add(term))
                    continue;
                LearnedDictionaryTerms.Add(term);
                combined.Add(term);
                added.Add(term);
            }
            if (added.Count > 0) Save();
            return added;
        }
    }

    public void ForgetLearnedDictionaryTerms(IEnumerable<string> terms)
    {
        lock (this)
        {
            var removed = new HashSet<string>(terms, StringComparer.OrdinalIgnoreCase);
            LearnedDictionaryTerms.RemoveAll(removed.Contains);
            Save();
        }
    }

    /// <summary>The pinned microphone's name, or null to follow the system default.</summary>
    public string? MicrophoneName { get; set; }

    /// <summary>Whether a tone marks the start and end of a recording.</summary>
    /// <remarks>
    /// On by default. The overlay is at the bottom of the screen and the user is looking at what
    /// they are dictating into, so a sound is the only feedback that reaches somebody who is not
    /// looking — and "did it hear me" is the question the first second has to answer.
    /// </remarks>
    public bool InteractionSounds { get; set; } = true;

    /// <summary>
    /// Backend started alongside the primary when it has not answered in time. Null disables it.
    ///
    /// Off by default. Hedging costs a second request and can hand back a less accurate transcript,
    /// so it is something to turn on after being bitten by the primary's latency tail.
    /// </summary>
    public ProviderKind? FallbackProvider { get; set; }

    /// <summary>
    /// How long the primary gets alone before the fallback starts — the accuracy-against-latency
    /// dial. Clamped on read so a hand-edited settings file cannot race from zero.
    /// </summary>
    public int FallbackAfterSeconds { get; set; } = 8;

    /// <summary>The fallback, ignored when it is the primary: that would double cost for nothing.</summary>
    public ProviderKind? ResolvedFallbackProvider() =>
        FallbackProvider is { } kind && kind != Provider ? kind : null;

    public TimeSpan ResolvedFallbackDelay() =>
        TimeSpan.FromSeconds(Math.Clamp(FallbackAfterSeconds, 1, 120));

    /// <summary>Base64 DPAPI blob for the legacy single-key setting. Never the key itself.</summary>
    public string? ProtectedApiKey { get; set; }

    /// <summary>
    /// Per-provider DPAPI blobs, keyed by <see cref="ProviderKind"/> name.
    ///
    /// Switching backends to compare them is the whole point of having more than one, and a single
    /// shared key would make every switch a re-typing exercise — which in practice means nobody
    /// switches. <see cref="ProtectedApiKey"/> is still read as Gemini's, so an existing settings
    /// file keeps working without a migration step that could lose someone their key.
    /// </summary>
    public Dictionary<string, string> ProtectedApiKeys { get; set; } = [];

    /// <summary>Per-provider model override, so choosing Deepgram does not send a Gemini model ID.</summary>
    public Dictionary<string, string> Models { get; set; } = [];

    /// <summary>
    /// How much the app writes to its log file.
    /// </summary>
    /// <remarks>
    /// A setting rather than only an environment variable, because a WinExe launched from Explorer
    /// or from the Startup folder inherits no shell environment at all — DNT_LOG_LEVEL is reachable
    /// from a terminal and invisible to everyone else, which is exactly backwards from who needs it.
    /// </remarks>
    public LogLevel LogLevel { get; set; } = LogLevel.Info;

    /// <summary>
    /// Whether transcripts and screen text may go into the log.
    /// </summary>
    /// <remarks>
    /// Off, and it stays off unless someone deliberately turns it on: the log file is the artifact
    /// most likely to be attached to a bug report, and an app whose promise is that your words stay
    /// yours should not write a second copy of them by default.
    /// </remarks>
    public bool LogContent { get; set; }

    /// <summary>Last mode chosen on the Recordings tab, so it opens where it was left.</summary>
    public string FileMode { get; set; } = "verbatim";

    /// <summary>Where the log file lives, next to the history it explains.</summary>
    // Fully qualified: this class has its own `Path` property for the settings file.
    public static string LogDirectory =>
        System.IO.Path.Combine(HistoryStore.DefaultDirectory(), "logs");

    /// <summary>
    /// Installs logging for the process, and registers every configured key for masking.
    /// </summary>
    /// <remarks>
    /// Registered up front rather than at the point of use: a key reaches a log by routes nobody
    /// planned — a provider echoing it back inside an error body, for one — and the only reliable
    /// defence is knowing the exact bytes before the first request.
    /// </remarks>
    public void StartLogging()
    {
        var resolved = LogRouter.Bootstrap(LogRouter.Configuration.App(LogDirectory) with
        {
            Level = LogLevel,
            IncludesContent = LogContent,
        });

        foreach (var kind in Enum.GetValues<ProviderKind>()) LogRouter.Redact(KeyFor(kind));

        new Log("app").Info(() => "started", new Dictionary<string, string>
        {
            ["level"] = resolved.Level.Id(),
            ["log"] = resolved.FilePath ?? "none",
            ["provider"] = Provider.ToString().ToLowerInvariant(),
            ["model"] = Model,
        });
    }

    /// <summary>
    /// Shipped non-empty. A blocklist that starts empty is one nobody ever fills in, and this app
    /// transmits screen contents.
    /// </summary>
    public List<string> BlockedProcesses { get; set; } =
    [
        "1Password", "Bitwarden", "KeePass", "KeePassXC", "LastPass",
        "mstsc", "CredentialUIBroker",
    ];

    public List<string> BlockedUrlPrefixes { get; set; } =
    [
        "https://login.microsoftonline.com",
        "https://accounts.google.com",
    ];

    // ---- Persistence -------------------------------------------------------------------------

    private static readonly JsonSerializerOptions Options = new()
    {
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter() },
    };

    private static string Directory => HistoryStore.DefaultDirectory();

    private static string Path => System.IO.Path.Combine(Directory, "settings.json");

    public static AppSettings Load()
    {
        try
        {
            if (File.Exists(Path))
            {
                var loaded = JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(Path), Options)
                    ?? new AppSettings();
                loaded.NormalizeDictionary();
                return loaded;
            }
        }
        catch (Exception e) when (e is JsonException or IOException)
        {
            // A corrupt settings file should not stop the app from starting.
        }
        return new AppSettings();
    }

    public bool Save()
    {
        lock (this)
        {
            try
            {
                NormalizeDictionary();
                AtomicFile.ReplaceText(Path, JsonSerializer.Serialize(this, Options));
                return true;
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            {
                const string message =
                    "Settings could not be saved. Check that the DoNotType data folder is writable.";
                new Log("settings").Error(() => message, new Dictionary<string, string>
                {
                    ["type"] = error.GetType().Name,
                });
                SaveFailed?.Invoke(message);
                return false;
            }
        }
    }

    private void NormalizeDictionary()
    {
        DictionaryTerms = DoNotType.Core.PersonalDictionary.Sanitize(DictionaryTerms).ToList();
        var manual = new HashSet<string>(DictionaryTerms, StringComparer.OrdinalIgnoreCase);
        LearnedDictionaryTerms = DoNotType.Core.PersonalDictionary.Sanitize(LearnedDictionaryTerms)
            .Where(term => !manual.Contains(term))
            .Take(DoNotType.Core.PersonalDictionary.MaxTerms - DictionaryTerms.Count)
            .ToList();
    }

    // ---- API key -----------------------------------------------------------------------------

    public string? ApiKey
    {
        get
        {
            if (string.IsNullOrEmpty(ProtectedApiKey)) return null;
            try
            {
                var bytes = ProtectedData.Unprotect(
                    Convert.FromBase64String(ProtectedApiKey), null, DataProtectionScope.CurrentUser);
                return Encoding.UTF8.GetString(bytes);
            }
            catch (Exception e) when (e is CryptographicException or FormatException)
            {
                // Copied between machines or user accounts; treat as absent rather than crashing.
                return null;
            }
        }
        set
        {
            ProtectedApiKey = string.IsNullOrEmpty(value)
                ? null
                : Convert.ToBase64String(ProtectedData.Protect(
                    Encoding.UTF8.GetBytes(value), null, DataProtectionScope.CurrentUser));
        }
    }

    /// <summary>The stored key for one provider, falling back to the legacy single-key slot.</summary>
    public string? KeyFor(ProviderKind kind)
    {
        if (ProtectedApiKeys.TryGetValue(kind.ToString(), out var blob) && Unprotect(blob) is { Length: > 0 } key)
        {
            return key;
        }
        // Before keys were stored per provider there was one slot, and it held Gemini's.
        return kind == ProviderKind.Gemini ? ApiKey : null;
    }

    public void SetKeyFor(ProviderKind kind, string? value)
    {
        if (string.IsNullOrEmpty(value)) ProtectedApiKeys.Remove(kind.ToString());
        else ProtectedApiKeys[kind.ToString()] = Protect(value);
        // A deliberate provider-specific write supersedes the legacy Gemini-only slot. Otherwise
        // clearing Gemini during import would reveal the old key again on the next read.
        if (kind == ProviderKind.Gemini) ApiKey = null;
    }

    /// <summary>
    /// The model for one provider, defaulting to that provider's own default rather than to
    /// Gemini's — otherwise choosing Deepgram would send <c>gemini-3.5-flash</c> to /v1/listen.
    /// </summary>
    public string ModelFor(ProviderKind kind)
    {
        if (Models.TryGetValue(kind.ToString(), out var stored) && !string.IsNullOrWhiteSpace(stored))
        {
            return stored;
        }
        return kind == ProviderKind.Gemini && !string.IsNullOrWhiteSpace(Model)
            ? Model
            : kind.DefaultModel();
    }

    public void SetModelFor(ProviderKind kind, string? value)
    {
        var resolved = string.IsNullOrWhiteSpace(value) ? kind.DefaultModel() : value.Trim();
        Models[kind.ToString()] = resolved;
        // Kept in step so anything still reading the flat property sees the selected provider's
        // model rather than a stale one.
        if (kind == Provider) Model = resolved;
    }

    /// <summary>Falls back to the environment so a developer need not populate settings first.</summary>
    public string? ResolvedApiKey() =>
        KeyFor(Provider) is { Length: > 0 } stored
            ? stored
            : Environment.GetEnvironmentVariable(Provider.ApiKeyEnvVar());

    private static string Protect(string value) =>
        Convert.ToBase64String(ProtectedData.Protect(
            Encoding.UTF8.GetBytes(value), null, DataProtectionScope.CurrentUser));

    private static string? Unprotect(string? blob)
    {
        if (string.IsNullOrEmpty(blob)) return null;
        try
        {
            return Encoding.UTF8.GetString(ProtectedData.Unprotect(
                Convert.FromBase64String(blob), null, DataProtectionScope.CurrentUser));
        }
        catch (Exception e) when (e is CryptographicException or FormatException)
        {
            // Copied between machines or user accounts; treat as absent rather than crashing.
            return null;
        }
    }

    /// <summary>Evaluated before capture, never after.</summary>
    public bool IsBlocked(string? processName, string? url)
    {
        if (!string.IsNullOrEmpty(processName)
            && BlockedProcesses.Any(p => string.Equals(p, processName, StringComparison.OrdinalIgnoreCase)))
        {
            return true;
        }
        return !string.IsNullOrEmpty(url)
            && BlockedUrlPrefixes.Any(p => url.StartsWith(p, StringComparison.OrdinalIgnoreCase));
    }
}
