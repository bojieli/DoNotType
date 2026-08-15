package app.donottype.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.json.JSONObject
import org.junit.Test

/**
 * The screen context on a history row: what the inspector reads, and what a retry reuses.
 */
class ContextPersistenceTest {

    private fun sample() = ScreenContext(
        appName = "Mail",
        windowTitle = "Re: the 4240 figure",
        browserUrl = "https://example.test/thread",
        role = "EditText",
        isEditable = true,
        visibleText = "the quarterly number is 4240",
        textBeforeCaret = "as discussed, ",
        textAfterCaret = " — please confirm",
        selectedText = "4240",
    )

    @Test
    fun `every field survives a round trip through the history file`() {
        val record = DictationRecord(text = "hello", context = sample())
        val reloaded = DictationRecord.fromJson(JSONObject(record.toJson().toString()))

        val context = reloaded.context
        assertNotNull(context)
        assertEquals("Mail", context!!.appName)
        assertEquals("Re: the 4240 figure", context.windowTitle)
        assertEquals("https://example.test/thread", context.browserUrl)
        assertEquals("EditText", context.role)
        assertEquals(true, context.isEditable)
        assertEquals("the quarterly number is 4240", context.visibleText)
        assertEquals("as discussed, ", context.textBeforeCaret)
        assertEquals(" — please confirm", context.textAfterCaret)
        assertEquals("4240", context.selectedText)
    }

    /**
     * A row written before contexts were stored has to keep loading. The history file is the
     * user's, not a cache, and a schema change that empties it is data loss.
     */
    @Test
    fun `a row written before contexts existed still loads`() {
        val json = JSONObject(
            """
            {
              "id": "9f1d3d2e",
              "status": "completed",
              "text": "an older dictation",
              "model": "gemini-3.6-flash",
              "fidelity": "light"
            }
            """.trimIndent(),
        )

        val record = DictationRecord.fromJson(json)
        assertEquals("an older dictation", record.text)
        assertNull(record.context)
    }

    /**
     * What the inspector renders is what went over the wire, because it runs the same encoder the
     * request did rather than describing it.
     */
    @Test
    fun `the stored context encodes to the same parts the request sent`() {
        val context = sample()
        val atRequestTime = ContextEncoder().encode(context)

        val reloaded = ScreenContext.fromJson(JSONObject(context.toJson().toString()))!!
        val atInspectionTime = ContextEncoder().encode(reloaded)

        assertEquals(atRequestTime.size, atInspectionTime.size)
        assertEquals(
            atRequestTime.filterIsInstance<InputPart.Text>().map { it.text },
            atInspectionTime.filterIsInstance<InputPart.Text>().map { it.text },
        )
    }

    /**
     * A dictation that was never grounded stores nothing rather than an empty shell, so the
     * inspector can tell "nothing was sent" from "something was sent and it was blank".
     */
    @Test
    fun `an ungrounded dictation stores no context`() {
        val record = DictationRecord(text = "hello")
        assertNull(DictationRecord.fromJson(JSONObject(record.toJson().toString())).context)
    }

    /**
     * The screenshot is deliberately not persisted: the index is one file read whole at launch,
     * and a PNG in every row would make its size a function of how many dictations somebody has
     * ever made.
     */
    @Test
    fun `a screenshot is not written into the index`() {
        val context = sample().copy(screenshotPng = ByteArray(64) { 0x7F })
        val written = context.toJson().toString()

        assertFalse(written.contains("screenshot"))
        assertTrue(written.contains("Mail"))
    }

}
