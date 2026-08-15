package app.donottype.core

import app.donottype.audio.AudioDecoder
import java.io.IOException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import org.json.JSONObject

/**
 * What went wrong, in a sentence, and what to do about it.
 *
 * Failures reached the keyboard as whatever was thrown: `HTTP 429: {"error":{"code":
 * "rate_limit_exceeded","message":"…"}}`, or the class name of an exception. That is a log line.
 * Somebody who has just spoken a sentence has two questions — is this my fault, and did I lose what
 * I said — and neither is answered by a status code, least of all on a phone where the message has
 * one line to fit in.
 *
 * The rules are the ones in `Sources/DoNotTypeCore/Reachability.swift` and
 * `windows/DoNotType.Core/FailureAdvice.cs`, deliberately identical: the same failure on a phone
 * and a laptop should read the same way. `docs/MANUAL-CHECKS.md` sets the standard — "the message
 * should say the key is wrong, not 'The operation couldn't be completed'".
 */
object FailureAdvice {

    /**
     * @param message one line, shown on the keyboard and stored on the history row.
     * @param isQueued whether the dictation is safe and can be sent later.
     * @param isRetryable whether retrying now is worth anything.
     * @param needsUserAction whether the user has to change something before this can ever work.
     *   False for a request this app got wrong: nothing in Settings fixes that, and sending
     *   somebody there when nothing they can change will help is worse than telling them it is not
     *   their fault.
     */
    data class Guidance(
        val message: String,
        val isQueued: Boolean,
        val isRetryable: Boolean,
        val needsUserAction: Boolean,
    )

    /**
     * Errors worth retrying, as opposed to ones that will fail identically forever.
     *
     * Retrying a bad API key just burns the user's time; a timeout or a 503 is exactly what retry
     * exists for.
     */
    fun isTransient(error: Throwable): Boolean = when (error) {
        is SocketTimeoutException, is UnknownHostException -> true
        is ProviderException -> when {
            // The status, not a substring of the message. Asking whether the text contained
            // "HTTP 4" searched the provider's own body too, so a 500 whose body quoted an
            // upstream "HTTP 404" was classified as permanent and never retried.
            error.status > 0 -> error.status == 408 || error.status == 429 || error.status >= 500
            error.message.orEmpty().contains("billed 0 audio tokens") -> false
            else -> true
        }
        is IOException -> true
        else -> false
    }

    fun describe(error: Throwable, isOnline: Boolean = true): Guidance {
        if (!isOnline) {
            return Guidance(
                "Offline — saved, and it will send itself when you reconnect.",
                isQueued = true, isRetryable = true, needsUserAction = false,
            )
        }

        return when {
            error is ProviderException && error.status > 0 ->
                describeHttp(error.status, error.body)

            // No status: a parse failure, an empty output, or a message this app wrote itself.
            error is ProviderException -> Guidance(
                error.message ?: "The request failed.",
                isQueued = true, isRetryable = true, needsUserAction = false,
            )

            error is AudioDecoder.DecodeException -> Guidance(
                // Already written for a person, at the point of failure.
                error.message ?: "That recording could not be read.",
                isQueued = false, isRetryable = false, needsUserAction = true,
            )

            error is UnknownHostException || error is SocketTimeoutException || error is IOException ->
                Guidance(
                    "Network trouble — saved, and it will send itself when you reconnect.",
                    isQueued = true, isRetryable = true, needsUserAction = false,
                )

            else -> Guidance(
                error.message ?: error::class.simpleName.orEmpty(),
                isQueued = true, isRetryable = true, needsUserAction = false,
            )
        }
    }

    private fun describeHttp(status: Int, body: String): Guidance {
        // xAI answers a bad key with 400 and a sentence about it, not with 401. Read by status
        // alone that lands in the default branch and becomes advice that cannot ever work, for a
        // request that will fail identically every time. Observed live.
        if (status == 400 && mentionsApiKey(body)) {
            return Guidance(
                "The API key was rejected. Check it in Settings.",
                isQueued = false, isRetryable = false, needsUserAction = true,
            )
        }

        // What the provider itself said leads, when it said something readable, because it is
        // more specific than any status code can be — it knows what it refused. The advice follows.
        // The other way round buried "This model does not accept audio input." behind a sentence
        // about HTTP 400, and repeated ourselves when the provider had already said the same thing:
        // "The API key was rejected. Check it in Settings. Invalid API key provided."
        fun say(
            summary: String,
            next: String,
            queued: Boolean,
            retryable: Boolean,
            needsAction: Boolean,
        ): Guidance {
            val lead = message(body) ?: summary
            return Guidance(
                if (next.isEmpty()) lead else "$lead $next",
                isQueued = queued,
                isRetryable = retryable,
                needsUserAction = needsAction,
            )
        }

        return when (status) {
            401, 403 -> say(
                "The API key was rejected.", "Check it in Settings.",
                queued = false, retryable = false, needsAction = true,
            )

            402 -> say(
                "Billing problem on the provider account — the key is valid but has no quota.", "",
                queued = false, retryable = false, needsAction = true,
            )

            404 -> say(
                "That model is not available on this account.", "Pick another in Settings.",
                queued = false, retryable = false, needsAction = true,
            )

            413 -> say(
                "The recording was too large for the provider.",
                "Long ones are normally split automatically, so this is worth reporting.",
                queued = false, retryable = false, needsAction = true,
            )

            429 -> say(
                "Rate limited.", "Saved, and it will retry shortly.",
                queued = true, retryable = true, needsAction = false,
            )

            408 -> say(
                "The provider took too long to answer.", "Saved, retry from History.",
                queued = true, retryable = true, needsAction = false,
            )

            in 500..599 -> say(
                "The provider is having trouble.", "Saved, retry from History.",
                queued = true, retryable = true, needsAction = false,
            )

            // A 4xx is a request this app got wrong and will get wrong again in exactly the same
            // way, so it is kept but not offered as a retry.
            in 400..499 -> say(
                "The provider rejected the request (HTTP $status).",
                "Retrying will not change it — this is likely a fault here, and worth reporting.",
                queued = true, retryable = false, needsAction = false,
            )

            else -> say(
                "Request failed (HTTP $status).", "Saved, retry from History.",
                queued = true, retryable = true, needsAction = false,
            )
        }
    }

    /**
     * Deliberately narrow. A 400 is normally a request this app got wrong, which is not the user's
     * problem to fix — only one that names the key is reattributed to the key.
     */
    private fun mentionsApiKey(body: String): Boolean {
        val lowered = body.lowercase()
        return lowered.contains("api key") || lowered.contains("api_key") ||
            lowered.contains("apikey")
    }

    /**
     * The human-readable part of an error body, if there is one.
     *
     * Every OpenAI-compatible provider answers with `{"error": {"message": "…"}}`, and that
     * sentence is routinely the most useful thing available. Parsed rather than printed raw, so a
     * body that is not a sentence — a trace ID, an HTML error page, a wall of JSON — is dropped
     * instead of pasted onto somebody's keyboard. A user reading an error is not debugging.
     */
    internal fun message(body: String): String? {
        val trimmed = body.trim()
        if (trimmed.isEmpty()) return null

        if (trimmed.startsWith("{")) {
            return runCatching { messageIn(JSONObject(trimmed)) }.getOrNull()?.let(::tidy)
        }

        // Not JSON. A short plain-text body is usually a gateway saying something useful; a long
        // one, or one starting a tag, is an error page.
        if (trimmed.length > 200 || trimmed.startsWith("<")) return null
        return tidy(trimmed)
    }

    /** The shapes providers actually use. */
    private fun messageIn(json: JSONObject): String? {
        for (key in listOf("message", "error_description", "detail")) {
            val text = json.optString(key)
            if (text.isNotEmpty()) return text
        }
        for (key in listOf("error", "err", "failure")) {
            json.optJSONObject(key)?.let { nested -> messageIn(nested)?.let { return it } }
            val text = json.optString(key)
            if (text.isNotEmpty()) return text
        }
        return null
    }

    /** One line, ending in a full stop, short enough for a phone. */
    private fun tidy(text: String): String? {
        val flattened = text.split('\n', '\r')
            .map { it.trim() }
            .filter { it.isNotEmpty() }
            .joinToString(" ")
        if (flattened.isEmpty()) return null

        val capped = if (flattened.length <= 140) flattened else flattened.take(137).trimEnd() + "…"

        // It leads the message now, so it starts a sentence, and gateways answer in lower case.
        // Only a plain word is capitalised: the first token is often an identifier the provider is
        // quoting back — `models/gemini-9 is not found` — and "Models/gemini-9" is a different name.
        val opened = if (capped.substringBefore(' ').all { it.isLetter() }) {
            capped.replaceFirstChar { it.uppercase() }
        } else {
            capped
        }
        return if (opened.endsWith(".") || opened.endsWith("…")) opened else "$opened."
    }
}
