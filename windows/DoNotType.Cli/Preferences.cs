using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using DoNotType.Core;

namespace DoNotType.Cli;

/// <summary>
/// Reads what the tray app is configured with.
/// </summary>
/// <remarks>
/// <para>
/// Deliberately reads <c>settings.json</c> as raw JSON rather than importing the app's
/// <c>AppSettings</c> type. That type lives in a WinForms assembly and carries hotkey enums a
/// console tool has no use for; and the coupling would run the wrong way -- the CLI would start
/// deciding what the app's settings look like. The same choice the macOS CLI makes when it reads
/// the app's preferences domain instead of linking its Settings class.
/// </para>
/// <para>
/// Missing values fall back to what a fresh install would use, so this works on a machine where the
/// app has never run.
/// </para>
/// </remarks>
public static class Preferences
{
    public static string Directory => HistoryStore.DefaultDirectory();

    private static string Path => System.IO.Path.Combine(Directory, "settings.json");

    private static JsonElement? _cache;
    private static bool _loaded;

    private static JsonElement? Root
    {
        get
        {
            if (_loaded) return _cache;
            _loaded = true;
            try
            {
                if (File.Exists(Path))
                {
                    _cache = JsonDocument.Parse(File.ReadAllText(Path)).RootElement.Clone();
                }
            }
            catch (Exception e) when (e is JsonException or IOException)
            {
                // A corrupt settings file must not stop the CLI from working with flags alone.
            }
            return _cache;
        }
    }

    public static bool IsAvailable => Root is not null;

    public static ProviderKind Provider =>
        Enum.TryParse<ProviderKind>(String("Provider"), ignoreCase: true, out var kind)
            ? kind
            : ProviderFactory.DefaultForNewInstalls;

    public static Fidelity Fidelity =>
        Enum.TryParse<Fidelity>(String("Fidelity"), ignoreCase: true, out var value)
            ? value
            : Fidelity.Light;

    /// <summary>
    /// The three typography preferences, read for the same reason every other one here is: the CLI
    /// and the app are the same product, and a transcript that came out of dnt.exe should not be
    /// spaced differently from one the hotkey produced a minute earlier.
    /// </summary>
    public static TypographySpacing TypographySpacing =>
        Enum.TryParse<TypographySpacing>(
            String("TypographySpacing"), ignoreCase: true, out var value)
            ? value
            : Typography.DefaultSpacing;

    public static ChineseScript ChineseScript =>
        Enum.TryParse<ChineseScript>(String("ChineseScript"), ignoreCase: true, out var value)
            ? value
            : ChineseScript.Spoken;

    /// <summary>
    /// What the app's example box holds, migrating an install the app has not opened since the box
    /// replaced the style dropdown.
    /// </summary>
    /// <remarks>
    /// The fallback is not belt-and-braces: the CLI and the app read the same settings file, and a
    /// CLI run before the app's own one-time migration would otherwise send nothing where the app
    /// sends a style. Two clients disagreeing about the request is what the shared core exists to
    /// prevent.
    /// </remarks>
    public static string DictationExample(Func<DictationPreset, string?> presetText)
    {
        if (String("DictationExample") is { } stored)
        {
            return Typography.SanitizedSample(stored);
        }
        return Core.DictationExample.Migrating(
            String("DictationStyle"), String("CustomDictationStyle"), presetText);
    }

    public static string CustomRewriteStyle => String("CustomRewriteStyle") ?? string.Empty;

    public static string TranslateTo => String("TranslateTo") ?? string.Empty;

    public static string Model(ProviderKind kind)
    {
        if (Root?.TryGetProperty("Models", out var models) == true &&
            models.TryGetProperty(kind.ToString(), out var perProvider) &&
            perProvider.GetString() is { Length: > 0 } stored)
        {
            return stored;
        }
        // The pre-per-provider setting, which was Gemini's -- same fallback the app applies.
        if (kind == ProviderKind.Gemini && String("Model") is { Length: > 0 } legacy) return legacy;
        return kind.DefaultModel();
    }

    /// <summary>
    /// The key for a backend, and where it came from.
    /// </summary>
    /// <remarks>
    /// Environment first, then the app's store. That is the opposite of the app's own order, and
    /// deliberately so: a key exported in the shell you are typing in is an instruction for this
    /// invocation, while the stored one is the standing configuration.
    /// </remarks>
    public static (string Key, string Source)? ResolveKey(ProviderKind kind, bool allowStored = true)
    {
        if (Environment.GetEnvironmentVariable(kind.ApiKeyEnvVar())?.Trim() is { Length: > 0 } fromEnv)
        {
            return (fromEnv, $"environment ({kind.ApiKeyEnvVar()})");
        }
        if (!allowStored) return null;

        if (Root?.TryGetProperty("ProtectedApiKeys", out var keys) == true &&
            keys.TryGetProperty(kind.ToString(), out var blob) &&
            Unprotect(blob.GetString()) is { Length: > 0 } stored)
        {
            return (stored, "the app's settings (DPAPI)");
        }
        if (kind == ProviderKind.Gemini && Unprotect(String("ProtectedApiKey")) is { Length: > 0 } legacy)
        {
            return (legacy, "the app's settings (DPAPI)");
        }
        return null;
    }

    /// <summary>
    /// Decrypts a DPAPI blob. Returns null rather than throwing when it was written by another user
    /// or copied from another machine, which is exactly what DPAPI is supposed to prevent.
    /// </summary>
    private static string? Unprotect(string? base64)
    {
        if (string.IsNullOrEmpty(base64)) return null;
        try
        {
            var bytes = ProtectedData.Unprotect(
                Convert.FromBase64String(base64), null, DataProtectionScope.CurrentUser);
            return Encoding.UTF8.GetString(bytes);
        }
        catch (Exception e) when (e is CryptographicException or FormatException or PlatformNotSupportedException)
        {
            return null;
        }
    }

    private static string? String(string name) =>
        Root?.TryGetProperty(name, out var value) == true ? value.GetString() : null;
}
