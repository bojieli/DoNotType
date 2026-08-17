package app.donottype.core

import java.io.File
import java.nio.file.Files
import org.json.JSONArray
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class HistoryStoreHardeningTest {
    private lateinit var directory: File

    @Before
    fun setUp() {
        directory = Files.createTempDirectory("dnt-history-hardening").toFile()
    }

    @After
    fun tearDown() {
        directory.deleteRecursively()
    }

    @Test
    fun `each replacement leaves one complete index and no partial sibling`() {
        val store = HistoryStore(directory)
        store.configure(RetentionPolicy.FOREVER, keepAudioForCompleted = false)

        repeat(40) { index ->
            store.insert(
                DictationRecord(
                    status = DictationRecord.Status.COMPLETED,
                    text = "record $index",
                    model = "test",
                ),
                audio = null,
            )
            JSONArray(File(directory, "history.json").readText())
        }

        assertFalse(File(directory, "history.json.tmp").exists())
        assertEquals(40, HistoryStore(directory).all().size)
    }

    @Test
    fun `an index cannot make audio access escape its directory`() {
        val outside = File(directory, "outside.wav").apply { writeBytes(byteArrayOf(1, 2, 3)) }
        val record = DictationRecord(status = DictationRecord.Status.FAILED, model = "test").apply {
            audioFileName = "../${outside.name}"
        }
        File(directory, "history.json").writeText(JSONArray().put(record.toJson()).toString())

        val store = HistoryStore(directory)
        val loaded = store.all().single()
        assertNull(store.audioFor(loaded))
        store.delete(loaded.id)
        assertTrue("history deletion escaped its audio directory", outside.exists())
    }

    @Test
    fun `failed index replacement does not delete retry audio`() {
        val store = HistoryStore(directory)
        store.configure(RetentionPolicy.FOREVER, keepAudioForCompleted = false)
        val stored = store.insert(
            DictationRecord(status = DictationRecord.Status.FAILED, model = "test"),
            byteArrayOf(1, 2, 3),
        )
        assertTrue(store.audioFor(stored)!!.isNotEmpty())

        // A directory at the temporary filename deterministically makes the next replacement fail.
        assertTrue(File(directory, "history.json.tmp").mkdir())
        store.delete(stored.id)

        assertTrue(
            "audio must outlive an index that still refers to it",
            store.audioFor(stored)!!.isNotEmpty(),
        )
        assertEquals(1, store.all().size)
        assertEquals(1, HistoryStore(directory).all().size)
    }

    @Test
    fun `never retention is empty before the process exits`() {
        val store = HistoryStore(directory)
        store.configure(RetentionPolicy.NEVER, keepAudioForCompleted = true)

        store.insert(
            DictationRecord(status = DictationRecord.Status.COMPLETED, model = "test"),
            byteArrayOf(1, 2, 3),
        )

        assertTrue(store.all().isEmpty())
        assertFalse(File(directory, "history.json").exists())
    }

    @Test
    fun `records cannot mutate the store without an update`() {
        val store = HistoryStore(directory)
        val returned = store.insert(
            DictationRecord(
                status = DictationRecord.Status.COMPLETED,
                text = "durable",
                model = "test",
            ),
            audio = null,
        )

        returned.text = "changed outside"
        val fromList = store.all().single()
        fromList.text = "also changed outside"

        assertEquals("durable", store.all().single().text)
        assertEquals("durable", HistoryStore(directory).all().single().text)
    }

    @Test
    fun `restart removes only unreferenced managed audio`() {
        val first = HistoryStore(directory)
        val retained = first.insert(
            DictationRecord(status = DictationRecord.Status.FAILED, model = "test"),
            byteArrayOf(1, 2, 3),
        )
        val audioDirectory = File(directory, "audio")
        val orphan = File(audioDirectory, "${java.util.UUID.randomUUID()}.wav")
            .apply { writeBytes(byteArrayOf(4, 5, 6)) }
        val unrelated = File(audioDirectory, "notes.wav")
            .apply { writeBytes(byteArrayOf(7, 8, 9)) }

        val restarted = HistoryStore(directory)
        restarted.all()

        assertTrue(restarted.audioFor(retained)!!.isNotEmpty())
        assertFalse(orphan.exists())
        assertTrue(unrelated.exists())
    }

    @Test
    fun `unreadable index preserves unreferenced audio for recovery`() {
        val audioDirectory = File(directory, "audio").apply { mkdirs() }
        val recoverable = File(audioDirectory, "${java.util.UUID.randomUUID()}.wav")
            .apply { writeBytes(byteArrayOf(1, 2, 3)) }
        File(directory, "history.json").writeText("not json")

        HistoryStore(directory).all()

        assertTrue(recoverable.exists())
    }
}
