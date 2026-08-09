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
    public ProviderKind Provider { get; set; } = ProviderKind.Gemini;
    public string Model { get; set; } = ProviderKind.Gemini.DefaultModel();
    public Fidelity Fidelity { get; set; } = Fidelity.Light;
    public HotkeyMonitor.Trigger Trigger { get; set; } = HotkeyMonitor.Trigger.RightControl;
    public HotkeyMonitor.Mode HotkeyMode { get; set; } = HotkeyMonitor.Mode.Automatic;
    public bool GroundingEnabled { get; set; } = true;
    public RetentionPolicy Retention { get; set; } = RetentionPolicy.Forever;
    public bool KeepAudio { get; set; }

    /// <summary>Base64 DPAPI blob. Never the key itself.</summary>
    public string? ProtectedApiKey { get; set; }

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
                return JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(Path), Options)
                    ?? new AppSettings();
            }
        }
        catch (Exception e) when (e is JsonException or IOException)
        {
            // A corrupt settings file should not stop the app from starting.
        }
        return new AppSettings();
    }

    public void Save()
    {
        System.IO.Directory.CreateDirectory(Directory);
        File.WriteAllText(Path, JsonSerializer.Serialize(this, Options));
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

    /// <summary>Falls back to the environment so a developer need not populate settings first.</summary>
    public string? ResolvedApiKey() =>
        ApiKey is { Length: > 0 } stored
            ? stored
            : Environment.GetEnvironmentVariable(Provider.ApiKeyEnvVar());

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
