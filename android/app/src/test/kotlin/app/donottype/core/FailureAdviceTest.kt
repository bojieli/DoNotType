package app.donottype.core

import java.net.UnknownHostException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * What a person is told when a dictation fails.
 *
 * These are the sentences a user actually sees, so they are asserted as text. The rules match
 * `Sources/DoNotTypeCore/Reachability.swift` and `windows/DoNotType.Core/FailureAdvice.cs`
 * deliberately: the same failure on a phone and a laptop should read the same way, and the tests
 * are duplicated in each language because a shared fixture would be read by whichever platform
 * remembered to read it.
 */
class FailureAdviceTest {

    private fun http(status: Int, body: String = "") =
        FailureAdvice.describe(ProviderException("HTTP $status: $body", status, body))

    @Test
    fun `offline is queued and needs no action`() {
        val advice = FailureAdvice.describe(ProviderException("whatever"), isOnline = false)
        assertTrue(advice.isQueued)
        assertFalse(advice.needsUserAction)
        assertTrue(advice.message.contains("reconnect"))
    }

    @Test
    fun `a bad key needs user action and is not queued`() {
        val advice = http(401)
        assertTrue(advice.needsUserAction)
        assertFalse(advice.isRetryable)
        assertFalse(advice.isQueued)
        assertTrue(advice.message.contains("Settings"))
    }

    /**
     * The exact response xAI returns for a bad key: a 400, not a 401. Classified by status alone it
     * reads as a transient request problem, and the user is told to retry a dictation that is
     * guaranteed to fail the same way.
     */
    @Test
    fun `a bad key reported as a 400 is still a bad key`() {
        val advice = http(400, "Incorrect API key provided. You can obtain one from console.x.ai.")
        assertTrue(advice.needsUserAction)
        assertFalse(advice.isRetryable)
    }

    /** The reattribution above stays narrow: an ordinary 400 is this app's bug. */
    @Test
    fun `an ordinary 400 is not blamed on the key`() {
        val advice = http(400, "unsupported sample rate")
        assertFalse(advice.needsUserAction)
        assertTrue(advice.isQueued)
    }

    // ---- What the provider itself said ---------------------------------------------------------

    /**
     * A status code cannot express "this model does not accept audio input". The provider can, and
     * it knows what it refused.
     */
    @Test
    fun `the provider's own explanation survives`() {
        val advice = http(400, """{"error": {"message": "This model does not accept audio input."}}""")
        assertTrue(advice.message, advice.message.contains("does not accept audio input"))
    }

    @Test
    fun `a message at the top level is found too`() {
        val advice = http(404, """{"message": "Unknown model: gemini-9"}""")
        assertTrue(advice.message, advice.message.contains("gemini-9"))
    }

    /** A user reading an error on a phone is not debugging. */
    @Test
    fun `nothing unreadable is shown`() {
        val bodies = listOf(
            """{"trace_id": "abc123", "status": {"code": 13}}""",
            "<html><head><title>502 Bad Gateway</title></head></html>",
        )
        bodies.forEach { body ->
            val advice = http(500, body)
            assertFalse(advice.message, advice.message.contains("{"))
            assertFalse(advice.message, advice.message.contains("<"))
        }
    }

    /**
     * A gateway answers in lower case and this leads the message, so it is capitalised on the way
     * past — its words are what has to survive, not its typography.
     */
    @Test
    fun `a short gateway message is kept`() {
        val advice = http(503, "upstream connect error before headers")
        assertTrue(advice.message, advice.message.lowercase().contains("upstream connect error"))
    }

    @Test
    fun `a long message is cut rather than filling the screen`() {
        val advice = http(400, List(200) { "verbose" }.joinToString(" "))
        assertTrue(advice.message, advice.message.length <= 260)
    }

    @Test
    fun `a multi-line message becomes one line`() {
        val advice = http(400, "it failed\nand here is why\nat length")
        assertFalse(advice.message, advice.message.contains("\n"))
    }

    // ---- Advice that can actually work ---------------------------------------------------------

    /**
     * A 4xx is a request this app got wrong and will get wrong again identically. "Saved, retry
     * from History" was offered for every unhandled one.
     */
    @Test
    fun `an unhandled client error does not promise a retry that cannot work`() {
        listOf(415, 422).forEach { status ->
            val advice = http(status)
            assertFalse("HTTP $status", advice.isRetryable)
            assertTrue(advice.message, advice.message.contains("not change it"))
            // Nothing in Settings fixes a malformed request.
            assertFalse("HTTP $status", advice.needsUserAction)
            assertTrue("HTTP $status", advice.isQueued)
        }
    }

    @Test
    fun `a server error is still worth retrying`() {
        listOf(500, 502, 503, 429, 408).forEach { status ->
            val advice = http(status)
            assertTrue("HTTP $status", advice.isRetryable)
            assertTrue("HTTP $status", advice.isQueued)
        }
    }

    @Test
    fun `a too-large recording is not offered as a retry`() {
        val advice = http(413)
        assertFalse(advice.isRetryable)
        assertTrue(advice.message, advice.message.contains("too large"))
    }

    @Test
    fun `network trouble is queued rather than blamed on anybody`() {
        val advice = FailureAdvice.describe(UnknownHostException("api.example.com"))
        assertTrue(advice.isQueued)
        assertTrue(advice.isRetryable)
        assertFalse(advice.needsUserAction)
    }

    /** Nothing here should read as a log line. */
    @Test
    fun `every message is a sentence`() {
        listOf(401, 429, 500, 418).forEach { status ->
            val message = http(status).message
            assertTrue(message.isNotBlank())
            assertTrue(message, message.first().isUpperCase())
            assertFalse(message, message.contains("HTTP 401:"))
        }
    }

    // ---- Classifying by status rather than by substring -----------------------------------------

    /**
     * The bug the status field exists to prevent. `isTransient` asked whether the message contained
     * "HTTP 4", which searched the provider's own body as well — so a 500 that quoted an upstream
     * 404 was classified as permanent and never retried.
     */
    @Test
    fun `a server error whose body quotes a client error is still transient`() {
        val error = ProviderException(
            "HTTP 502: upstream returned HTTP 404",
            status = 502,
            body = "upstream returned HTTP 404",
        )
        assertTrue(FailureAdvice.isTransient(error))
        assertTrue(FailureAdvice.describe(error).isRetryable)
    }

    @Test
    fun `a rejected key is never transient however it is worded`() {
        assertFalse(FailureAdvice.isTransient(ProviderException("HTTP 401: nope", status = 401)))
        assertFalse(FailureAdvice.isTransient(ProviderException("HTTP 403: nope", status = 403)))
    }

    @Test
    fun `the guidance and the retry rule agree about every status`() {
        listOf(400, 401, 403, 404, 408, 413, 422, 429, 500, 502, 503).forEach { status ->
            val error = ProviderException("HTTP $status", status = status)
            assertEquals(
                "HTTP $status: the retry rule and the advice disagree",
                FailureAdvice.isTransient(error),
                FailureAdvice.describe(error).isRetryable,
            )
        }
    }

    // ---- Nothing is cut -------------------------------------------------------------------------

    /**
     * The advice is for reading; the detail is for pasting into an issue. A body cut to fit loses
     * the field name that says which part of the request was wrong, and half a message cannot be
     * searched for.
     */
    @Test
    fun `the detail keeps the whole body`() {
        val body = "abcdefghij".repeat(500) // 5,000 characters
        val detail = FailureAdvice.detail(ProviderException("HTTP 400", status = 400, body = body))

        assertTrue("the body was cut", detail.contains(body))
        assertTrue(detail.contains("status=400"))
    }

    @Test
    fun `the detail names the kind of failure and its cause`() {
        val detail = FailureAdvice.detail(
            java.io.IOException("socket closed", IllegalStateException("no route")),
        )
        assertTrue(detail, detail.contains("IOException"))
        assertTrue(detail, detail.contains("caused by IllegalStateException"))
    }

    /** A log line has to stay one line, and a response body is full of newlines. */
    @Test
    fun `a log field keeps everything and stays on one line`() {
        val body = "{\n  \"error\": {\n    \"message\": \"nope\"\n  }\n}"
        val line = LogEvent(1, 0, LogLevel.ERROR, "http", "request failed", mapOf("detail" to body))
            .render()

        assertFalse(line, line.contains("\n"))
        assertTrue(line, line.contains("\\n"))
        assertTrue(line, line.contains("nope"))
    }
}
