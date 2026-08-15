using System.Text.Json;
using System.Text.Json.Nodes;

namespace DoNotType.Core;

/// <summary>
/// What went wrong, in a sentence, and what to do about it.
/// </summary>
/// <remarks>
/// <para>
/// Failures reached the interface as whatever was thrown: `HTTP 429: {"error":{"code":
/// "rate_limit_exceeded","message":"..."}}`, or a `HttpRequestException` naming a socket. That is a
/// log line. Somebody who has just spoken a sentence has two questions — is this my fault, and did
/// I lose what I said — and neither is answered by a status code.
/// </para>
/// <para>
/// The rules are the ones in `Sources/DoNotTypeCore/Reachability.swift`, deliberately identical:
/// the same failure on a laptop and a desktop should read the same way. docs/MANUAL-CHECKS.md sets
/// the standard — "the message should say the key is wrong, not 'The operation couldn't be
/// completed'".
/// </para>
/// </remarks>
public static class FailureAdvice
{
    /// <param name="Message">One line, shown in the overlay and stored on the history row.</param>
    /// <param name="IsQueued">Whether the dictation is safe and can be sent later.</param>
    /// <param name="IsRetryable">Whether retrying now is worth anything.</param>
    /// <param name="NeedsUserAction">
    /// Whether the user has to change something before this can ever work. False for a request
    /// this app got wrong: nothing in Settings fixes that, and sending somebody there when nothing
    /// they can change will help is worse than telling them it is not their fault.
    /// </param>
    public sealed record Guidance(
        string Message, bool IsQueued, bool IsRetryable, bool NeedsUserAction);

    public static Guidance Describe(Exception error, bool isOnline = true)
    {
        if (!isOnline)
        {
            return new Guidance(
                "Offline — saved, and it will send itself when you reconnect.",
                IsQueued: true, IsRetryable: true, NeedsUserAction: false);
        }

        if (error is ProviderException provider)
        {
            if (provider.Status > 0) return DescribeHttp(provider.Status, provider.Body);

            // No status: a parse failure, an empty output, or a message this app wrote itself.
            return new Guidance(
                provider.Message, IsQueued: true, IsRetryable: provider.IsTransient,
                NeedsUserAction: false);
        }

        if (error is AudioDecoder.DecodeException)
        {
            // Already written for a person, at the point of failure.
            return new Guidance(
                error.Message, IsQueued: false, IsRetryable: false, NeedsUserAction: true);
        }

        if (error is HttpRequestException or TaskCanceledException or IOException)
        {
            return new Guidance(
                "Network trouble — saved, and it will send itself when you reconnect.",
                IsQueued: true, IsRetryable: true, NeedsUserAction: false);
        }

        return new Guidance(
            error.Message, IsQueued: true, IsRetryable: true, NeedsUserAction: false);
    }

    private static Guidance DescribeHttp(int status, string body)
    {
        // xAI answers a bad key with 400 and a sentence about it, not with 401. Read by status
        // alone that lands in the default branch and becomes advice that cannot ever work, for a
        // request that will fail identically every time. Observed live.
        if (status == 400 && MentionsApiKey(body))
        {
            return new Guidance(
                "The API key was rejected. Check it in Settings.",
                IsQueued: false, IsRetryable: false, NeedsUserAction: true);
        }

        // What the provider itself said, when it said something readable. A status code cannot
        // express "this model does not accept audio input"; the provider can, and it knows what it
        // refused. Appended rather than replacing the advice, because the provider explains what
        // happened and only this app knows what to do about it.
        var detail = Message(body) is { } found ? $" {found}" : string.Empty;

        return status switch
        {
            401 or 403 => new Guidance(
                $"The API key was rejected. Check it in Settings.{detail}",
                IsQueued: false, IsRetryable: false, NeedsUserAction: true),

            402 => new Guidance(
                "Billing problem on the provider account — the key is valid but has no quota."
                    + detail,
                IsQueued: false, IsRetryable: false, NeedsUserAction: true),

            404 => new Guidance(
                $"That model is not available on this account. Pick another in Settings.{detail}",
                IsQueued: false, IsRetryable: false, NeedsUserAction: true),

            413 => new Guidance(
                "The recording was too large for the provider. Long ones are normally split "
                    + "automatically, so this is worth reporting." + detail,
                IsQueued: false, IsRetryable: false, NeedsUserAction: true),

            429 => new Guidance(
                $"Rate limited — saved, and it will retry shortly.{detail}",
                IsQueued: true, IsRetryable: true, NeedsUserAction: false),

            408 => new Guidance(
                $"The provider took too long to answer — saved, retry from History.{detail}",
                IsQueued: true, IsRetryable: true, NeedsUserAction: false),

            >= 500 and <= 599 => new Guidance(
                $"The provider is having trouble — saved, retry from History.{detail}",
                IsQueued: true, IsRetryable: true, NeedsUserAction: false),

            // A 4xx is a request this app got wrong and will get wrong again in exactly the same
            // way, so it is kept but not offered as a retry.
            >= 400 and <= 499 => new Guidance(
                $"The provider rejected the request (HTTP {status}). Retrying will not change it "
                    + "— this is likely a fault here, and worth reporting." + detail,
                IsQueued: true, IsRetryable: false, NeedsUserAction: false),

            _ => new Guidance(
                $"Request failed (HTTP {status}) — saved, retry from History.{detail}",
                IsQueued: true, IsRetryable: true, NeedsUserAction: false),
        };
    }

    /// <summary>
    /// Deliberately narrow. A 400 is normally a request this app got wrong, which is not the
    /// user's problem to fix — only one that names the key is reattributed to the key.
    /// </summary>
    private static bool MentionsApiKey(string body)
    {
        var lowered = body.ToLowerInvariant();
        return lowered.Contains("api key") || lowered.Contains("api_key")
            || lowered.Contains("apikey");
    }

    /// <summary>The human-readable part of an error body, if there is one.</summary>
    /// <remarks>
    /// Every OpenAI-compatible provider answers with `{"error": {"message": "..."}}`, and that
    /// sentence is routinely the most useful thing available. Parsed rather than printed raw, so a
    /// body that is not a sentence — a trace ID, an HTML error page, a wall of JSON — is dropped
    /// instead of pasted into the corner of somebody's screen. A user reading an overlay is not
    /// debugging.
    /// </remarks>
    internal static string? Message(string body)
    {
        var trimmed = body.Trim();
        if (trimmed.Length == 0) return null;

        try
        {
            if (JsonNode.Parse(trimmed) is { } parsed) return Tidy(MessageIn(parsed));
        }
        catch (JsonException)
        {
            // Not JSON. A short plain-text body is usually a gateway saying something useful; a
            // long one, or one starting a tag, is an error page.
            if (trimmed.Length <= 200 && !trimmed.StartsWith('<')) return Tidy(trimmed);
        }
        return null;
    }

    /// <summary>The shapes providers actually use.</summary>
    private static string? MessageIn(JsonNode? node)
    {
        if (node is JsonValue value && value.TryGetValue<string>(out var text))
        {
            return string.IsNullOrEmpty(text) ? null : text;
        }
        if (node is not JsonObject dictionary) return null;

        foreach (var key in new[] { "message", "error_description", "detail" })
        {
            if (dictionary[key] is JsonValue candidate
                && candidate.TryGetValue<string>(out var found)
                && !string.IsNullOrEmpty(found))
            {
                return found;
            }
        }
        foreach (var key in new[] { "error", "err", "failure" })
        {
            if (dictionary[key] is { } nested && MessageIn(nested) is { } deeper) return deeper;
        }
        return null;
    }

    /// <summary>One line, ending in a full stop, short enough to sit in a pill on a screen.</summary>
    private static string? Tidy(string? text)
    {
        if (text is null) return null;

        var flattened = string.Join(
            " ",
            text.Split('\n', '\r', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries));
        if (flattened.Length == 0) return null;

        var capped = flattened.Length <= 140 ? flattened : flattened[..137].TrimEnd() + "…";
        return capped.EndsWith('.') || capped.EndsWith('…') ? capped : capped + ".";
    }
}
