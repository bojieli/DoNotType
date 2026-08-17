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
}
