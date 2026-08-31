using System.IO.Compression;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using DoNotType.Core;

namespace DoNotType.App;

/// <summary>Version 1 of the portable settings document shared by all four clients.</summary>
public static class SettingsTransfer
{
    public const string Format = "app.donottype.settings";
    public const int Version = 1;
    public const int MaximumBytes = 1_048_576;
    private const string QrPrefix = "DNT1:";
    private const int MaximumQrEnvelopeBytes = 16_384;

    public sealed class Document
    {
        [JsonPropertyName("format")] public string FormatName { get; set; } = Format;
        [JsonPropertyName("version")] public int VersionNumber { get; set; } = Version;
        [JsonPropertyName("selectedProvider")] public string SelectedProvider { get; set; } = "google";
        [JsonPropertyName("providers")] public Dictionary<string, ProviderValues> Providers { get; set; } = [];
        [JsonPropertyName("fidelity")] public string Fidelity { get; set; } = "light";
        [JsonPropertyName("fallback")] public FallbackValues? Fallback { get; set; }
        [JsonPropertyName("retention")] public string Retention { get; set; } = "forever";
        [JsonPropertyName("keepAudio")] public bool KeepAudio { get; set; }
        [JsonPropertyName("dictionary")] public DictionaryValues Dictionary { get; set; } = new();

        /// <summary>
        /// Shared rather than platform-specific: typography is not a desktop concept, and a
        /// transcript spaced one way here and another on the phone reading the same profile is the
        /// drift this block prevents. Null when the document predates it.
        /// </summary>
        [JsonPropertyName("typography")] public TypographyValues? Typography { get; set; }
        [JsonPropertyName("desktop")] public DesktopValues? Desktop { get; set; }
        [JsonPropertyName("windows")] public WindowsValues? Windows { get; set; }
    }

    public sealed class ProviderValues
    {
        [JsonPropertyName("model")] public string Model { get; set; } = string.Empty;
        [JsonPropertyName("textModel")] public string? TextModel { get; set; }
        [JsonPropertyName("endpoint")] public string? Endpoint { get; set; }
        [JsonPropertyName("apiKey")] public string? ApiKey { get; set; }
    }

    public sealed class FallbackValues
    {
        [JsonPropertyName("provider")] public string Provider { get; set; } = string.Empty;
        [JsonPropertyName("afterSeconds")] public double AfterSeconds { get; set; } = 8;
    }

    public sealed class DictionaryValues
    {
        [JsonPropertyName("manual")] public List<string> Manual { get; set; } = [];
        [JsonPropertyName("learned")] public List<string> Learned { get; set; } = [];
        [JsonPropertyName("learnsFromEdits")] public bool LearnsFromEdits { get; set; }
    }

    public sealed class TypographyValues
    {
        [JsonPropertyName("spacing")] public string Spacing { get; set; } = "spaced";
        [JsonPropertyName("chineseScript")] public string ChineseScript { get; set; } = "spoken";
        /// <summary>
        /// Which dictation style is selected. Absent in a profile written before styles existed,
        /// which then keeps whatever the importing device already had.
        /// </summary>
        [JsonPropertyName("dictationStyle")] public string? DictationStyle { get; set; }

        /// <summary>
        /// The user's own style text for each stage. Two fields rather than one, because the two
        /// stages are different jobs: the dictation style may not reword and the rewrite style is
        /// there to.
        /// </summary>
        [JsonPropertyName("customDictationStyle")] public string? CustomDictationStyle { get; set; }

        [JsonPropertyName("customRewriteStyle")] public string? CustomRewriteStyle { get; set; }

        /// <summary>
        /// Empty, or absent altogether in a profile written before translation existed, means the
        /// dictation stays in the language that was spoken.
        /// </summary>
        [JsonPropertyName("translateTo")] public string? TranslateTo { get; set; }
    }

    /// <summary>Subset of the macOS block with platform-independent meaning.</summary>
    public sealed class DesktopValues
    {
        [JsonPropertyName("secondaryStyle")] public string? SecondaryStyle { get; set; }
        [JsonPropertyName("interactionSounds")] public bool? InteractionSounds { get; set; }
        [JsonPropertyName("groundingEnabled")] public bool? GroundingEnabled { get; set; }
        [JsonPropertyName("keytermBiasing")] public bool? KeytermBiasing { get; set; }
        [JsonPropertyName("logLevel")] public string? LogLevel { get; set; }
        [JsonPropertyName("logContent")] public bool? LogContent { get; set; }
        [JsonPropertyName("fileMode")] public string? FileMode { get; set; }
    }

    public sealed class WindowsValues
    {
        [JsonPropertyName("trigger")] public string Trigger { get; set; } = "rightControl";
        [JsonPropertyName("hotkeyMode")] public string HotkeyMode { get; set; } = "automatic";
        [JsonPropertyName("cancelShortcut")] public string CancelShortcut { get; set; } = "escape";
        [JsonPropertyName("finishAndSendAction")] public string FinishAndSendAction { get; set; } = "disabled";
        [JsonPropertyName("secondaryTrigger")] public string? SecondaryTrigger { get; set; }
        [JsonPropertyName("secondaryStyle")] public string SecondaryStyle { get; set; } = "formal";

        /// <summary>
        /// The key bound to Translate. Absent in a profile written before Translate had a key of
        /// its own, when a target language overrode both of the other keys instead — so an old
        /// document leaves the importing device's binding alone rather than clearing it.
        /// </summary>
        [JsonPropertyName("translateTrigger")] public string? TranslateTrigger { get; set; }
        [JsonPropertyName("interactionSounds")] public bool InteractionSounds { get; set; } = true;
        [JsonPropertyName("groundingEnabled")] public bool GroundingEnabled { get; set; } = true;
        [JsonPropertyName("keytermBiasing")] public bool KeytermBiasing { get; set; }
        [JsonPropertyName("blockedProcesses")] public List<string> BlockedProcesses { get; set; } = [];
        [JsonPropertyName("blockedURLPrefixes")] public List<string> BlockedUrlPrefixes { get; set; } = [];
        [JsonPropertyName("logLevel")] public string LogLevel { get; set; } = "info";
        [JsonPropertyName("logContent")] public bool LogContent { get; set; }
        [JsonPropertyName("fileMode")] public string FileMode { get; set; } = "verbatim";
    }

    private static readonly JsonSerializerOptions PrettyOptions = new()
    {
        WriteIndented = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    private static readonly JsonSerializerOptions CompactOptions = new()
    {
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    public static Document Export(AppSettings settings)
    {
        var providers = new Dictionary<string, ProviderValues>();
        foreach (var kind in Enum.GetValues<ProviderKind>())
        {
            providers[Canonical(kind)] = new ProviderValues
            {
                Model = settings.ModelFor(kind),
                ApiKey = settings.KeyFor(kind),
            };
        }

        return new Document
        {
            SelectedProvider = Canonical(settings.Provider),
            Providers = providers,
            Fidelity = settings.Fidelity.Id(),
            Fallback = settings.ResolvedFallbackProvider() is { } fallback
                ? new FallbackValues
                {
                    Provider = Canonical(fallback),
                    AfterSeconds = settings.FallbackAfterSeconds,
                }
                : null,
            Retention = RetentionId(settings.Retention),
            KeepAudio = settings.KeepAudio,
            Dictionary = new DictionaryValues
            {
                Manual = [.. settings.DictionaryTerms],
                Learned = [.. settings.LearnedDictionaryTerms],
                LearnsFromEdits = settings.LearnDictionaryFromEdits,
            },
            Typography = new TypographyValues
            {
                Spacing = DoNotType.Core.Typography.Spelling(settings.TypographySpacing),
                ChineseScript = settings.ChineseScript.Id(),
                DictationStyle = settings.DictationStyle.Id(),
                CustomDictationStyle = settings.CustomDictationStyle,
                CustomRewriteStyle = settings.CustomRewriteStyle,
                TranslateTo = settings.TranslateTo,
            },
            Windows = new WindowsValues
            {
                Trigger = LowerCamel(settings.Trigger),
                HotkeyMode = LowerCamel(settings.HotkeyMode),
                CancelShortcut = settings.CancelShortcut == DoNotType.Core.CancelShortcut.Escape
                    ? "escape" : "disabled",
                FinishAndSendAction = LowerCamel(settings.FinishAndSendAction),
                SecondaryTrigger = settings.RewriteTrigger is { } secondary
                    ? LowerCamel(secondary) : null,
                SecondaryStyle = settings.RewriteStyle.Id(),
                TranslateTrigger = settings.TranslateTrigger is { } translateKey
                    ? translateKey.ToString()
                    : null,
                InteractionSounds = settings.InteractionSounds,
                GroundingEnabled = settings.GroundingEnabled,
                KeytermBiasing = settings.KeytermBiasing,
                BlockedProcesses = [.. settings.BlockedProcesses],
                BlockedUrlPrefixes = [.. settings.BlockedUrlPrefixes],
                LogLevel = settings.LogLevel.Id(),
                LogContent = settings.LogContent,
                FileMode = settings.FileMode,
            },
        };
    }

    public static string Encode(Document document, bool pretty = true) =>
        JsonSerializer.Serialize(document, pretty ? PrettyOptions : CompactOptions);

    public static Document Decode(string json)
    {
        if (Encoding.UTF8.GetByteCount(json) > MaximumBytes)
            throw new InvalidDataException("The settings document is larger than the 1 MB limit.");
        Document document;
        try
        {
            document = JsonSerializer.Deserialize<Document>(json, CompactOptions)
                ?? throw new InvalidDataException("The settings document is empty.");
        }
        catch (JsonException error)
        {
            throw new InvalidDataException($"This is not valid settings JSON: {error.Message}", error);
        }
        Validate(document);
        return document;
    }

    /// <summary>Compresses the portable JSON so a camera can resolve it from another screen.</summary>
    public static string EncodeQr(Document document)
    {
        var json = Encoding.UTF8.GetBytes(Encode(document, pretty: false));
        using var output = new MemoryStream();
        using (var compressor = new DeflateStream(output, CompressionLevel.SmallestSize, leaveOpen: true))
            compressor.Write(json);
        var base64Url = Convert.ToBase64String(output.ToArray())
            .TrimEnd('=')
            .Replace('+', '-')
            .Replace('/', '_');
        return QrPrefix + base64Url;
    }

    /// <summary>Accepts compressed DNT1 codes and raw JSON codes from earlier releases.</summary>
    public static Document DecodeQr(string value)
    {
        if (!value.StartsWith(QrPrefix, StringComparison.Ordinal)) return Decode(value);
        if (Encoding.UTF8.GetByteCount(value) > MaximumQrEnvelopeBytes)
            throw new InvalidDataException("The QR payload is too large.");

        var base64 = value[QrPrefix.Length..].Replace('-', '+').Replace('_', '/');
        base64 += new string('=', (4 - base64.Length % 4) % 4);
        byte[] compressed;
        try { compressed = Convert.FromBase64String(base64); }
        catch (FormatException error)
        {
            throw new InvalidDataException("The QR payload is damaged.", error);
        }

        try
        {
            using var input = new DeflateStream(
                new MemoryStream(compressed), CompressionMode.Decompress);
            using var output = new MemoryStream();
            var buffer = new byte[8192];
            while (true)
            {
                var count = input.Read(buffer, 0, buffer.Length);
                if (count == 0) break;
                output.Write(buffer, 0, count);
                if (output.Length > MaximumBytes)
                    throw new InvalidDataException(
                        "The settings document is larger than the 1 MB limit.");
            }
            return Decode(Encoding.UTF8.GetString(output.ToArray()));
        }
        catch (InvalidDataException) { throw; }
        catch (IOException error)
        {
            throw new InvalidDataException("The QR payload is damaged.", error);
        }
    }

    public static void Apply(Document document, AppSettings settings)
    {
        Validate(document);
        var selected = ParseProvider(document.SelectedProvider)
            ?? throw Unsupported("selectedProvider", document.SelectedProvider);
        ProviderKind? fallback = document.Fallback is null
            ? null
            : ParseProvider(document.Fallback.Provider)
                ?? throw Unsupported("fallback.provider", document.Fallback.Provider);
        var fidelity = document.Fidelity switch
        {
            "raw" => Fidelity.Raw,
            "light" => Fidelity.Light,
            "tidy" => Fidelity.Tidy,
            _ => throw Unsupported("fidelity", document.Fidelity),
        };
        var retention = document.Retention switch
        {
            "never" => RetentionPolicy.Never,
            "oneDay" => RetentionPolicy.OneDay,
            "oneWeek" => RetentionPolicy.OneWeek,
            "oneMonth" => RetentionPolicy.OneMonth,
            "forever" => RetentionPolicy.Forever,
            _ => throw Unsupported("retention", document.Retention),
        };
        var dictionary = document.Dictionary
            ?? throw new InvalidDataException("Dictionary settings are missing.");

        // Optional, so a profile exported before this existed still imports; but a value that is
        // present and unreadable fails the whole document rather than being silently defaulted,
        // which is how every other typed field here behaves.
        TypographySpacing? spacing = null;
        DoNotType.Core.ChineseScript? script = null;
        if (document.Typography is { } typography)
        {
            spacing = typography.Spacing switch
            {
                "spaced" => TypographySpacing.Spaced,
                "tight" => TypographySpacing.Tight,
                "unchanged" => TypographySpacing.Unchanged,
                _ => throw Unsupported("typography.spacing", typography.Spacing),
            };
            script = typography.ChineseScript switch
            {
                "spoken" => DoNotType.Core.ChineseScript.Spoken,
                "simplified" => DoNotType.Core.ChineseScript.Simplified,
                "traditional" => DoNotType.Core.ChineseScript.Traditional,
                _ => throw Unsupported("typography.chineseScript", typography.ChineseScript),
            };
        }

        var windows = document.Windows;
        HotkeyMonitor.Trigger? trigger = windows is null ? null : ParseEnum<HotkeyMonitor.Trigger>(windows.Trigger);
        HotkeyMonitor.Mode? mode = windows is null ? null : ParseEnum<HotkeyMonitor.Mode>(windows.HotkeyMode);
        DoNotType.Core.CancelShortcut? cancel = windows is null ? null : windows.CancelShortcut switch
        {
            "escape" => DoNotType.Core.CancelShortcut.Escape,
            "disabled" or "none" => DoNotType.Core.CancelShortcut.Disabled,
            _ => throw Unsupported("windows.cancelShortcut", windows.CancelShortcut),
        };
        FinishAndSendAction? finish = windows is null
            ? null : ParseEnum<FinishAndSendAction>(windows.FinishAndSendAction);
        HotkeyMonitor.Trigger? secondary = windows?.SecondaryTrigger is { Length: > 0 } rawSecondary
            ? ParseEnum<HotkeyMonitor.Trigger>(rawSecondary)
                ?? throw Unsupported("windows.secondaryTrigger", rawSecondary)
            : null;
        RewriteStyle? secondaryStyle = windows is null
            ? null : ParseStyle(windows.SecondaryStyle)
                ?? throw Unsupported("windows.secondaryStyle", windows.SecondaryStyle);
        HotkeyMonitor.Trigger? translateKey = windows?.TranslateTrigger is { Length: > 0 } rawTranslate
            ? ParseEnum<HotkeyMonitor.Trigger>(rawTranslate)
                ?? throw Unsupported("windows.translateTrigger", rawTranslate)
            : null;
        LogLevel? logLevel = windows is null
            ? null : LogLevelExtensions.Parse(windows.LogLevel)
                ?? throw Unsupported("windows.logLevel", windows.LogLevel);
        string? fileMode = windows is null
            ? null : TranscriptMode.Parse(windows.FileMode)?.Id
                ?? throw Unsupported("windows.fileMode", windows.FileMode);
        if (windows is not null && trigger is null) throw Unsupported("windows.trigger", windows.Trigger);
        if (windows is not null && mode is null) throw Unsupported("windows.hotkeyMode", windows.HotkeyMode);
        if (windows is not null && finish is null)
            throw Unsupported("windows.finishAndSendAction", windows.FinishAndSendAction);

        foreach (var pair in document.Providers)
        {
            if (ParseProvider(pair.Key) is not { } kind) continue;
            settings.SetModelFor(kind, pair.Value.Model);
            settings.SetKeyFor(kind, pair.Value.ApiKey);
        }
        settings.Provider = selected;
        settings.Model = settings.ModelFor(selected);
        settings.Fidelity = fidelity;
        settings.FallbackProvider = fallback;
        settings.FallbackAfterSeconds = (int)Math.Clamp(
            document.Fallback?.AfterSeconds ?? 8, 1, 120);
        settings.Retention = retention;
        settings.KeepAudio = document.KeepAudio;
        settings.DictionaryTerms = dictionary.Manual;
        settings.LearnedDictionaryTerms = dictionary.Learned;
        settings.LearnDictionaryFromEdits = dictionary.LearnsFromEdits;
        if (spacing is { } importedSpacing && script is { } importedScript)
        {
            settings.TypographySpacing = importedSpacing;
            settings.ChineseScript = importedScript;
            // Absent is "the profile predates styles", which keeps what this device has.
            if (document.Typography?.DictationStyle is { Length: > 0 } styleId)
            {
                settings.DictationStyle = DictationStyleExtensions.ParseDictationStyle(styleId);
            }
            if (document.Typography?.CustomDictationStyle is { } customDictation)
            {
                settings.CustomDictationStyle =
                    DoNotType.Core.Typography.SanitizedSample(customDictation);
            }
            if (document.Typography?.CustomRewriteStyle is { } customRewrite)
            {
                settings.CustomRewriteStyle =
                    DoNotType.Core.Typography.SanitizedSample(customRewrite);
            }
            settings.TranslateTo =
                TranslationTarget.Sanitized(document.Typography?.TranslateTo);
        }

        if (windows is not null)
        {
            settings.Trigger = trigger!.Value;
            settings.HotkeyMode = mode!.Value;
            settings.CancelShortcut = cancel!.Value;
            settings.FinishAndSendAction = finish!.Value;
            settings.RewriteTrigger = secondary;
            settings.RewriteStyle = secondaryStyle!.Value;
            settings.TranslateTrigger = translateKey;
            settings.InteractionSounds = windows.InteractionSounds;
            settings.GroundingEnabled = windows.GroundingEnabled;
            settings.KeytermBiasing = windows.KeytermBiasing;
            settings.BlockedProcesses = windows.BlockedProcesses;
            settings.BlockedUrlPrefixes = windows.BlockedUrlPrefixes;
            settings.LogLevel = logLevel!.Value;
            settings.LogContent = windows.LogContent;
            settings.FileMode = fileMode!;
        }
        else if (document.Desktop is { } desktop)
        {
            desktop.InteractionSounds?.Let(value => settings.InteractionSounds = value);
            desktop.GroundingEnabled?.Let(value => settings.GroundingEnabled = value);
            desktop.KeytermBiasing?.Let(value => settings.KeytermBiasing = value);
            if (desktop.LogLevel is { } raw && LogLevelExtensions.Parse(raw) is { } level)
                settings.LogLevel = level;
            desktop.LogContent?.Let(value => settings.LogContent = value);
            if (TranscriptMode.Parse(desktop.FileMode) is { } desktopMode)
                settings.FileMode = desktopMode.Id;
            if (desktop.SecondaryStyle is { } rawStyle && ParseStyle(rawStyle) is { } style)
                settings.RewriteStyle = style;
        }
        settings.Save();
    }

    private static void Validate(Document document)
    {
        if (document.FormatName != Format)
            throw new InvalidDataException("This JSON is not a DoNotType settings document.");
        if (document.VersionNumber != Version)
            throw new InvalidDataException(
                $"Settings format version {document.VersionNumber} is not supported.");
        if (document.Providers is null)
            throw new InvalidDataException("Provider settings are missing.");
        foreach (var pair in document.Providers)
        {
            if (pair.Value is null)
                throw new InvalidDataException($"Provider settings for “{pair.Key}” are invalid.");
        }
        if (document.Dictionary is null)
            throw new InvalidDataException("Dictionary settings are missing.");
        document.Dictionary.Manual ??= [];
        document.Dictionary.Learned ??= [];
        if (document.Windows is { } windows)
        {
            windows.BlockedProcesses ??= [];
            windows.BlockedUrlPrefixes ??= [];
        }
        var selected = ParseProvider(document.SelectedProvider)
            ?? throw Unsupported("selectedProvider", document.SelectedProvider);
        if (!document.Providers.ContainsKey(Canonical(selected))
            && !document.Providers.ContainsKey(selected.ToString().ToLowerInvariant()))
            throw new InvalidDataException("The selected provider is missing from provider settings.");
        var selectedValues = document.Providers.GetValueOrDefault(Canonical(selected))
            ?? document.Providers.GetValueOrDefault(selected.ToString().ToLowerInvariant());
        if (selectedValues is null)
            throw new InvalidDataException("The selected provider settings are invalid.");
        if (!string.IsNullOrWhiteSpace(selectedValues?.Endpoint))
            throw new InvalidDataException(
                "Windows does not support custom provider endpoints yet; clear the endpoint before importing.");
        if (document.Fallback is { } fallback)
        {
            if (!double.IsFinite(fallback.AfterSeconds))
                throw new InvalidDataException("The fallback delay is not a finite number.");
            var kind = ParseProvider(fallback.Provider)
                ?? throw Unsupported("fallback.provider", fallback.Provider);
            if (kind == selected)
                throw new InvalidDataException("The fallback cannot be the selected provider.");
            if (!document.Providers.ContainsKey(Canonical(kind))
                && !document.Providers.ContainsKey(kind.ToString().ToLowerInvariant()))
                throw new InvalidDataException("The fallback provider is missing from provider settings.");
            var fallbackValues = document.Providers.GetValueOrDefault(Canonical(kind))
                ?? document.Providers.GetValueOrDefault(kind.ToString().ToLowerInvariant());
            if (fallbackValues is null)
                throw new InvalidDataException("The fallback provider settings are invalid.");
            if (!string.IsNullOrWhiteSpace(fallbackValues?.Endpoint))
                throw new InvalidDataException(
                    "Windows does not support custom fallback endpoints yet; clear the endpoint before importing.");
        }
    }

    private static string Canonical(ProviderKind kind) => kind switch
    {
        ProviderKind.Gemini => "google",
        ProviderKind.XAI => "xai",
        _ => kind.ToString().ToLowerInvariant(),
    };

    private static ProviderKind? ParseProvider(string? raw) => raw?.Trim().ToLowerInvariant() switch
    {
        "google" or "gemini" => ProviderKind.Gemini,
        "openrouter" => ProviderKind.OpenRouter,
        "deepgram" => ProviderKind.Deepgram,
        "mistral" => ProviderKind.Mistral,
        "xai" => ProviderKind.XAI,
        _ => null,
    };

    private static string RetentionId(RetentionPolicy policy) => policy switch
    {
        RetentionPolicy.Never => "never",
        RetentionPolicy.OneDay => "oneDay",
        RetentionPolicy.OneWeek => "oneWeek",
        RetentionPolicy.OneMonth => "oneMonth",
        _ => "forever",
    };

    private static string LowerCamel<T>(T value) where T : struct, Enum
    {
        var text = value.ToString();
        return char.ToLowerInvariant(text[0]) + text[1..];
    }

    private static T? ParseEnum<T>(string? raw) where T : struct, Enum =>
        Enum.TryParse<T>(raw, true, out var value) ? value : null;

    private static RewriteStyle? ParseStyle(string? raw) => raw?.ToLowerInvariant() switch
    {
        "verbatim" => RewriteStyle.Verbatim,
        "formal" => RewriteStyle.Formal,
        "concise" => RewriteStyle.Concise,
        "casual" => RewriteStyle.Casual,
        _ => null,
    };

    private static InvalidDataException Unsupported(string field, string? value) =>
        new($"This version does not support “{value ?? "<missing>"}” for {field}.");

    private static void Let<T>(this T value, Action<T> apply) => apply(value);
}
