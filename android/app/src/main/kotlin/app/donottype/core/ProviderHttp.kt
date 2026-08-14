package app.donottype.core

/**
 * The one place a provider request is described, and therefore the one place it can be logged.
 *
 * Every backend opens its own `HttpURLConnection`, which is fine until the question becomes "what
 * did the app actually send, and what came back?" — the first question of every transcription bug
 * report, and one that previously needed a proxy or a rebuild to answer. Now it is two lines per
 * request at debug level.
 *
 * Bodies are deliberately absent. A request body is the user's audio and their screen; a response
 * body is their transcript. What is logged is the shape: endpoint, model, bytes each way, status,
 * duration. That is enough to tell a rejected key from a stalled network from a model that answered
 * instantly with nothing.
 */
object ProviderHttp {
    private val log = Log("http")

    fun request(provider: String, model: String, endpoint: String, bytes: Int) {
        log.debug(
            mapOf(
                "provider" to provider,
                "model" to model,
                "url" to redactUrl(endpoint),
                "bytes" to bytes.toString(),
            ),
        ) { "request" }
    }

    fun response(provider: String, model: String, status: Int, bytes: Int, millis: Long) {
        log.debug(
            mapOf(
                "provider" to provider,
                "model" to model,
                "status" to status.toString(),
                "bytes" to bytes.toString(),
                "ms" to millis.toString(),
            ),
        ) { "response" }
    }

    fun failed(provider: String, model: String, error: Throwable, millis: Long) {
        // The timing matters as much as the message: a connection refused in 4 ms and a read
        // timeout at 120 s are the same exception type and completely different problems.
        log.warn(
            mapOf(
                "provider" to provider,
                "model" to model,
                "error" to (error.message ?: error::class.simpleName.orEmpty()),
                "ms" to millis.toString(),
            ),
        ) { "request failed" }
    }

    /**
     * Strips credentials out of a URL before it is logged.
     *
     * Not hypothetical: several APIs take the key as `?key=`, and `Redaction` would only catch it
     * by shape. Removing the value outright catches the rest.
     */
    fun redactUrl(url: String): String {
        val query = url.indexOf('?')
        if (query < 0) return url
        val sensitive = setOf("key", "api_key", "apikey", "token", "access_token", "auth")
        val rebuilt = url.substring(query + 1).split("&").joinToString("&") { pair ->
            val name = pair.substringBefore('=')
            if (name.lowercase() in sensitive) "$name=‹redacted›" else pair
        }
        return url.substring(0, query) + "?" + rebuilt
    }
}
