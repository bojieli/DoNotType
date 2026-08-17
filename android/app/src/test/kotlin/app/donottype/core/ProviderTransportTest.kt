package app.donottype.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * The rules that decide how long a connection is trusted.
 *
 * The failure these exist to catch was invisible to every functional test the app had. Transcripts
 * were correct, retries recovered, nothing threw — and on desktop, where it was measured, a quarter
 * of dictations took a minute because a request went out on a connection that had quietly died
 * while idle. What went wrong was *which connection carried the request*, so that is what is
 * checked, without touching a network.
 */
class ProviderTransportTest {

    @Before
    fun clearState() = ProviderTransport.reset()

    /**
     * Warm-up opens a connection to the host and must not call the API path: any answer from the
     * host proves the connection, while a GET to the endpoint would be a real request with a real
     * bill attached.
     */
    @Test
    fun `the warm-up target is the host and not the endpoint`() {
        assertEquals(
            "https://generativelanguage.googleapis.com/",
            ProviderTransport.origin(
                "https://generativelanguage.googleapis.com/v1beta/interactions",
            ),
        )
    }

    /** A non-default port is part of which connection this is, so it survives. */
    @Test
    fun `an origin keeps its port`() {
        assertEquals(
            "http://localhost:8000/",
            ProviderTransport.origin("http://localhost:8000/v1/chat/completions"),
        )
    }

    /** A base URL somebody pasted wrongly must not crash a dictation before it starts. */
    @Test
    fun `an unparseable endpoint has no origin`() {
        assertNull(ProviderTransport.origin("not a url"))
    }

    /**
     * A host nothing has spoken to is stale by definition: there is no connection to trust, and
     * saying otherwise would skip the warm-up that opens one.
     */
    @Test
    fun `a host never used is stale`() {
        assertTrue(ProviderTransport.isStale("api.example.com"))
    }

    /**
     * The window is bounded and the bound is the measured one: no request that followed the
     * previous one inside a minute was ever slow, and thirty seconds doubles that margin.
     */
    @Test
    fun `the idle window is thirty seconds`() {
        assertEquals(30_000L, ProviderTransport.MAX_IDLE_MS)
    }

    /**
     * Two minutes was never a wait anybody wanted — a healthy request answers in 2.6 s at p95 —
     * only a long delay before the retry that was going to fix it. Warm-up gets far less, because
     * its job is to find a dead connection fast rather than to wait for a slow one.
     */
    @Test
    fun `the read timeout is not two minutes`() {
        assertEquals(25_000, ProviderTransport.REQUEST_TIMEOUT_MS)
        assertTrue(ProviderTransport.WARM_UP_TIMEOUT_MS < ProviderTransport.REQUEST_TIMEOUT_MS)
    }

    /**
     * Every backend the app ships knows where it will be connecting, so every one of them can be
     * warmed. A client returning null here would silently go back to paying for the handshake in
     * front of the user.
     */
    @Test
    fun `every shipped client knows its origin`() {
        val clients: List<TranscriptionProvider> = listOf(
            GeminiClient("k"),
            OpenAiCompatibleClient(
                name = "openrouter",
                apiKey = "k",
                model = "m",
                endpoint = "https://openrouter.ai/api/v1/chat/completions",
            ),
            DeepgramClient("k"),
            MistralClient("k"),
            XAISpeechClient("k"),
        )

        for (client in clients) {
            assertNotNull("${client.name} cannot be warmed up", client.endpointOrigin)
            assertTrue("${client.name}", client.endpointOrigin!!.endsWith("/"))
            assertFalse("${client.name}", client.endpointOrigin!!.contains("/v1"))
        }
    }
}
