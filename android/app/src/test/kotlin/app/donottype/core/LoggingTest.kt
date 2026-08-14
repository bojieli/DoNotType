package app.donottype.core

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * The log has one job beyond being useful: being safe to share.
 *
 * Most of this is about that. A logger that leaks a key is worse than no logger, because the leak
 * only shows up once the file has already been sent to a stranger.
 */
class LoggingTest {

    private lateinit var sink: MemoryLogSink

    @Before
    fun setUp() {
        sink = MemoryLogSink()
        LogRouter.install(listOf(sink), LogLevel.TRACE)
    }

    @After
    fun tearDown() {
        LogRouter.install(emptyList(), LogLevel.OFF)
    }

    @Test
    fun `levels filter from the bottom`() {
        LogRouter.setLevel(LogLevel.WARN)
        val log = Log("test")
        log.debug { "invisible" }
        log.info { "also invisible" }
        log.warn { "visible" }
        log.error { "visible too" }

        assertEquals(listOf("visible", "visible too"), sink.events.map { it.message })
    }

    @Test
    fun `off silences even errors`() {
        LogRouter.setLevel(LogLevel.OFF)
        Log("test").error { "nope" }
        assertTrue(sink.events.isEmpty())
    }

    /** The reason messages are lambdas: a trace call in a hot path must not build its string. */
    @Test
    fun `a filtered message is never constructed`() {
        LogRouter.setLevel(LogLevel.ERROR)
        var built = false
        Log("test").debug {
            built = true
            "expensive"
        }
        assertFalse("a filtered message must not be constructed", built)
    }

    @Test
    fun `level names accept the spellings people type`() {
        assertEquals(LogLevel.WARN, LogLevel.from("warn"))
        assertEquals(LogLevel.WARN, LogLevel.from("WARNING"))
        assertEquals(LogLevel.OFF, LogLevel.from("silent"))
        assertEquals(LogLevel.DEBUG, LogLevel.from(" Debug "))
        assertNull(LogLevel.from("chatty"))
    }

    @Test
    fun `a registered secret is masked wherever it appears`() {
        val key = "AIzaSyD-Not-A-Real-Key-000000000000000"
        LogRouter.redact(key)

        Log("test").error(mapOf("body" to "invalid key $key")) {
            "HTTP 400 from https://example.com/v1?key=$key"
        }

        val event = sink.events.first()
        assertFalse(event.message.contains(key))
        assertFalse(event.fields.getValue("body").contains(key))
        assertTrue(event.message.contains("redacted"))
    }

    /**
     * The case registration cannot cover: a key belonging to some other tool, echoed back by a
     * provider this process never authenticated to.
     */
    @Test
    fun `unregistered key shapes are still masked`() {
        Log("test").info { "using sk-abcdefghijklmnopqrstuvwxyz012345 for that call" }
        assertFalse(sink.events[0].message.contains("sk-abcdefghijklmnopqrstuvwxyz012345"))
    }

    @Test
    fun `ordinary text survives redaction`() {
        // Every one of these has been mistaken for a secret by a naive length rule at some point.
        listOf(
            "gemini-3.6-flash",
            "voxtral-mini-latest",
            "transcription",
            "550e8400-e29b-41d4",
            "com.google.android.apps.authenticator2",
            "AudioChunker.wrapInWavContainer",
        ).forEach {
            assertFalse("$it is not a credential", Redaction.looksSecret(it))
        }
    }

    @Test
    fun `a long opaque token is masked`() {
        assertTrue(Redaction.looksSecret("a1b2c3d4e5f6g7h8i9j0k1l2m3n4o5p6q7r8"))
    }

    @Test
    fun `url credentials are stripped before logging`() {
        val redacted = ProviderHttp.redactUrl(
            "https://api.example.com/v1/listen?key=supersecretvalue&model=nova-3",
        )
        assertFalse(redacted.contains("supersecretvalue"))
        assertTrue("non-secret parameters stay readable", redacted.contains("model=nova-3"))
    }

    @Test
    fun `content is withheld by default but its size is not`() {
        Log("test").content("transcript") { "the thing I actually said" }

        val event = sink.events.first()
        assertEquals("25", event.fields["chars"])
        assertNull("transcripts must not be logged unless asked for", event.fields["text"])
    }

    @Test
    fun `content is included when turned on`() {
        LogRouter.setIncludesContent(true)
        Log("test").content("transcript") { "the thing I actually said" }
        assertEquals("the thing I actually said", sink.events.first().fields["text"])
    }

    @Test
    fun `recent filters by level and search`() {
        val log = Log("dictation")
        log.info { "started recording" }
        log.error(mapOf("provider" to "gemini")) { "upload failed" }
        Log("hotkey").info { "key down" }

        assertEquals(1, LogRouter.recent(minimumLevel = LogLevel.ERROR).size)
        assertEquals(1, LogRouter.recent(containing = "hotkey").size)
        assertEquals("fields are searched", 1, LogRouter.recent(containing = "gemini").size)
        assertEquals(3, LogRouter.recent().size)
    }

    @Test
    fun `fields render sorted so two runs compare`() {
        val event = LogEvent(
            id = 1,
            timestamp = 0,
            level = LogLevel.INFO,
            category = "http",
            message = "response",
            fields = mapOf("status" to "200", "ms" to "412", "provider" to "gemini"),
        )
        assertTrue(
            event.render(includeTime = false).endsWith("ms=412 provider=gemini status=200"),
        )
    }
}
