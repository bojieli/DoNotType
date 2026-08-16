namespace DoNotType.Core;

/// <summary>
/// The one place a provider request is made, and therefore the one place it can be logged.
/// </summary>
/// <remarks>
/// <para>
/// Every backend called <c>SendAsync</c> itself, which was fine until the question became "what did
/// the app actually send, and what came back?" -- the first question of every transcription bug
/// report, and one that could only be answered with a proxy or a rebuild.
/// </para>
/// <para>
/// Bodies are deliberately absent. A request body is the user's audio and their screen; a response
/// body is their transcript; those go through <see cref="Log.Content"/>, which is off unless someone
/// asks for it. What is left is enough to tell a rejected key from a stalled network from a model
/// that answered instantly with nothing.
/// </para>
/// </remarks>
public static class ProviderHttp
{
    private static readonly Log Log = new("http");

    public static async Task<HttpResponseMessage> SendLoggedAsync(
        this HttpClient client,
        HttpRequestMessage request,
        string provider,
        string model,
        CancellationToken cancellationToken = default)
    {
        var started = DateTimeOffset.Now;
        var outgoing = request.Content?.Headers.ContentLength ?? 0;

        Log.Debug(() => "request", new Dictionary<string, string>
        {
            ["provider"] = provider,
            ["model"] = model,
            ["url"] = RedactUrl(request.RequestUri?.ToString() ?? "?"),
            ["bytes"] = outgoing.ToString(),
        });

        HttpResponseMessage response;
        try
        {
            response = await client.SendAsync(request, cancellationToken).ConfigureAwait(false);
        }
        catch (Exception error)
        {
            // The timing matters as much as the message: a connection refused in 4 ms and a read
            // timeout at 150 s are the same exception type and completely different problems.
            Log.Warn(() => "request failed", new Dictionary<string, string>
            {
                ["provider"] = provider,
                ["model"] = model,
                ["error"] = error.Message,
                ["ms"] = ((long)(DateTimeOffset.Now - started).TotalMilliseconds).ToString(),
            });
            throw;
        }

        Log.Debug(() => "response", new Dictionary<string, string>
        {
            ["provider"] = provider,
            ["model"] = model,
            ["status"] = ((int)response.StatusCode).ToString(),
            ["bytes"] = (response.Content.Headers.ContentLength ?? 0).ToString(),
            ["ms"] = ((long)(DateTimeOffset.Now - started).TotalMilliseconds).ToString(),
        });
        return response;
    }

    /// <summary>
    /// Strips credentials out of a URL before it is logged.
    /// </summary>
    /// <remarks>
    /// Not hypothetical: several APIs take the key as <c>?key=</c>, and <see cref="Redaction"/>
    /// would only catch it by shape. Removing the value outright catches the rest.
    /// </remarks>
    public static string RedactUrl(string url)
    {
        var query = url.IndexOf('?');
        if (query < 0) return url;

        string[] sensitive = ["key", "api_key", "apikey", "token", "access_token", "auth"];
        var rebuilt = string.Join("&", url[(query + 1)..].Split('&').Select(pair =>
        {
            var name = pair.Split('=')[0];
            return sensitive.Contains(name.ToLowerInvariant()) ? $"{name}=‹redacted›" : pair;
        }));
        return url[..query] + "?" + rebuilt;
    }
}
