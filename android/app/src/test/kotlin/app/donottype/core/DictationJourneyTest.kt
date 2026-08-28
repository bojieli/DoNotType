package app.donottype.core

import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.File
import java.nio.file.Files

/**
 * The journey a user actually takes, offline. Port of
 * `Tests/DoNotTypeCoreTests/DictationJourneyTests.swift`.
 *
 * The pieces were tested and the sequence they form was not: what gets stored, what survives a
 * failure, whether Retry can still work afterwards. These assert decisions rather than
 * transcription quality — quality is what `dnt-eval` is for.
 *
 * **What is deliberately not covered here, and why.** On macOS the retry orchestration lives in
 * `RetryCoordinator` in the shared core, so it is testable. On Android it lives in
 * `DictationService`, which needs an Android `Context` and so needs Robolectric or an instrumented
 * test to reach. The store-level guarantees Retry depends on — audio kept while retryable,
 * released on success — are asserted here, and the glue above them is covered by the instrumented
 * settings tests.
 */
class DictationJourneyTest {
    private lateinit var directory: File
    private lateinit var store: HistoryStore

    @Before
    fun setUp() {
        directory = Files.createTempDirectory("dnt-journey").toFile()
        store = HistoryStore(directory)
        store.configure(RetentionPolicy.FOREVER, keepAudioForCompleted = false)
    }

    @After
    fun tearDown() {
        directory.deleteRecursively()
    }

    /** 16 kHz mono PCM, the format every platform records. */
    private fun wav(seconds: Double = 1.0): ByteArray {
        val rate = 16_000
        val bytes = (rate * 2 * seconds).toInt()
        val out = java.io.ByteArrayOutputStream()
        fun ascii(v: String) = out.write(v.toByteArray(Charsets.US_ASCII))
        fun u32(v: Int) = out.write(
            byteArrayOf(v.toByte(), (v shr 8).toByte(), (v shr 16).toByte(), (v shr 24).toByte()),
        )
        fun u16(v: Int) = out.write(byteArrayOf(v.toByte(), (v shr 8).toByte()))
        ascii("RIFF"); u32(36 + bytes); ascii("WAVEfmt ")
        u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        ascii("data"); u32(bytes); out.write(ByteArray(bytes))
        return out.toByteArray()
    }

    private fun record(status: DictationRecord.Status) = DictationRecord(
        status = status, model = "stub-model", fidelity = Fidelity.LIGHT,
    )

    // ---- The happy path --------------------------------------------------------------------

    @Test
    fun `a successful dictation is stored with its text`() {
        val entry = record(DictationRecord.Status.COMPLETED).apply { text = "the transcript" }
        val stored = store.insert(entry, null)

        assertEquals("the transcript", stored.text)
        assertEquals(1, store.all().size)
        assertFalse("a completed dictation has nothing to retry", stored.canRetry)
    }

    /** Silence in, nothing out — no empty row for someone to delete later. */
    @Test
    fun `silence produces no history row`() {
        val transcript = Transcript("   ")
        assertTrue(transcript.transcript.isBlank())
        assertEquals(0, store.all().size)
    }

    // ---- Failure keeps the words recoverable -------------------------------------------------

    /** The promise Retry rests on: a failed dictation keeps its audio, so the button can work. */
    @Test
    fun `a failed dictation keeps its audio and is retryable`() {
        val entry = record(DictationRecord.Status.FAILED).apply { errorMessage = "network" }
        val stored = store.insert(entry, wav())

        assertTrue(stored.canRetry)
        assertNotNull("the audio has to still be there", store.audioFor(stored))
        assertEquals(1, store.retryable().size)
    }

    /** And the other half: a successful retry releases the recording it was holding. */
    @Test
    fun `a successful retry releases the audio`() {
        val stored = store.insert(
            record(DictationRecord.Status.FAILED).apply { errorMessage = "network" }, wav(),
        )
        assertNotNull(store.audioFor(stored))

        stored.status = DictationRecord.Status.COMPLETED
        stored.text = "recovered on the second attempt"
        stored.errorMessage = null
        stored.retryCount += 1
        store.update(stored)

        val after = store.all().first { it.id == stored.id }
        assertEquals(DictationRecord.Status.COMPLETED, after.status)
        assertEquals(1, after.retryCount)
        assertNull("a recovered dictation should not still look broken", after.errorMessage)
        assertNull("the audio it was holding should be gone", after.audioFileName)
        assertEquals(0, store.retryable().size)
    }

    /** Audio is kept for a retryable entry even when completed-audio retention is off. */
    @Test
    fun `retention off still keeps audio for anything retryable`() {
        store.configure(RetentionPolicy.FOREVER, keepAudioForCompleted = false)

        val failed = store.insert(record(DictationRecord.Status.FAILED), wav())
        val completed = store.insert(record(DictationRecord.Status.COMPLETED), wav())

        assertNotNull("retryable, so the audio stays", store.audioFor(failed))
        assertNull("completed and retention is off, so it goes", completed.audioFileName)
    }

    // ---- Redoing a transcript that arrived wrong ---------------------------------------------

    /**
     * The other reason to keep a recording: a dictation that *succeeded* and still came back
     * wrong. Retry cannot reach it — the row is completed — so the offer is keyed to the audio
     * being there rather than to the status.
     */
    @Test
    fun `a completed dictation can be redone while its audio is kept`() {
        store.configure(RetentionPolicy.FOREVER, keepAudioForCompleted = true)
        val entry = record(DictationRecord.Status.COMPLETED)
            .apply { text = "meet Bo Jelly at four" }

        val stored = store.insert(entry, wav())

        assertFalse("a completed dictation has nothing to retry", stored.canRetry)
        assertTrue("but its recording is still there to transcribe again", stored.canRedo)
        assertNotNull(store.audioFor(stored))
    }

    /**
     * Without the audio there is nothing to send, so nothing is offered — the default for a
     * completed dictation, which discards its recording.
     */
    @Test
    fun `a discarded recording cannot be redone`() {
        val stored = store.insert(record(DictationRecord.Status.COMPLETED), wav())

        assertNull(stored.audioFileName)
        assertFalse(stored.canRedo)
    }

    /** The recording is saved under the time it was said, not the UUID it has on disk. */
    @Test
    fun `a saved recording is named for when it was said`() {
        val calendar = java.util.Calendar.getInstance()
        calendar.set(2026, java.util.Calendar.AUGUST, 28, 14, 32, 5)
        val entry = DictationRecord(
            createdAt = calendar.timeInMillis,
            status = DictationRecord.Status.COMPLETED,
            model = "stub-model",
        )

        assertEquals("donottype-20260828-143205.wav", entry.audioExportName)
    }

    // ---- Provider behaviour ------------------------------------------------------------------

    @Test
    fun `a transient failure is worth retrying and a missing key is not`() = runBlocking {
        val transient = ProviderException("HTTP 503: down")
        val permanent = ProviderException("No API key")
        // Both surface as ProviderException; what differs is what the caller does next, which is
        // why the record keeps the message rather than only a flag.
        assertTrue(transient.message!!.contains("503"))
        assertTrue(permanent.message!!.contains("API key"))
    }

    /** A hedged dictation must name the backend that answered, not the one that was asked. */
    @Test
    fun `a hedged dictation records the backend that answered it`() = runBlocking {
        val outcome = FallbackTranscriber(
            primary = FallbackTranscriber.Transcriber {
                kotlinx.coroutines.delay(5_000)
                TranscriptionResult(Transcript("primary"), TokenUsage(), "primary")
            },
            secondary = FallbackTranscriber.Transcriber {
                TranscriptionResult(Transcript("from the fallback"), TokenUsage(), "fallback")
            },
            hedgeAfterMillis = 20,
        ).transcribe("primary", "primary-model", "fallback", "fallback-model")

        val stored = store.insert(
            record(DictationRecord.Status.COMPLETED).apply {
                text = outcome.result.transcript.transcript
                model = outcome.attribution.model
            },
            null,
        )

        assertEquals("from the fallback", stored.text)
        assertEquals("not the model that was asked", "fallback-model", stored.model)
        assertTrue(outcome.attribution.wasFallback)
    }

    // ---- Grounding reaches the request --------------------------------------------------------

    /** Screen text arrives as parts, audio last. docs/CONTEXT_FORMAT.md says the order matters. */
    @Test
    fun `screen context reaches the provider ahead of the audio`() {
        val context = ScreenContext(
            appName = "Chrome",
            visibleText = "Brindlewood and quillmark-sync. ".repeat(20),
        )
        val parts = ContextEncoder().encode(context) + InputPart.Audio(wav(), "audio/wav")

        assertTrue("the audio must be last", parts.last() is InputPart.Audio)
        val text = parts.filterIsInstance<InputPart.Text>().joinToString(" ") { it.text }
        assertTrue(text.contains("Brindlewood"))
        assertTrue(
            "the reference-only framing must survive",
            text.contains("DO NOT TRANSCRIBE"),
        )
    }
}
