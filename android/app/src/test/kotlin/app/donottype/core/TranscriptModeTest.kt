package app.donottype.core

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Modes, and the wall between rewriting and summarising. */
class TranscriptModeTest {

    @Test
    fun `every offered spelling parses and round trips`() {
        TranscriptMode.ALL.forEach { mode ->
            val parsed = TranscriptMode.from(mode.id)
            assertEquals("${mode.id} must round trip", mode.id, parsed?.id)
        }
    }

    @Test
    fun `bare stage names take their default`() {
        assertEquals(TranscriptMode.Summary(SummaryStyle.BRIEF), TranscriptMode.from("summary"))
        assertEquals(TranscriptMode.Rewrite(RewriteStyle.FORMAL), TranscriptMode.from("rewrite"))
        assertEquals(TranscriptMode.Summary(SummaryStyle.BRIEF), TranscriptMode.from("summarize"))
    }

    @Test
    fun `unknown styles are rejected rather than silently downgraded`() {
        assertNull(TranscriptMode.from("summary:novel"))
        assertNull(TranscriptMode.from("rewrite:shakespeare"))
        assertNull(TranscriptMode.from("translate"))
        // Verbatim is not a rewrite style, so asking for it as one is a mistake worth catching.
        assertNull(TranscriptMode.from("rewrite:verbatim"))
    }

    @Test
    fun `only verbatim avoids a second request`() {
        assertFalse(TranscriptMode.Verbatim.needsSecondPass)
        assertTrue(TranscriptMode.Rewrite(RewriteStyle.FORMAL).needsSecondPass)
        assertTrue(TranscriptMode.Summary(SummaryStyle.ACTIONS).needsSecondPass)
    }

    /**
     * A summary is not a rewrite style, and a history row must not claim it is — that column feeds
     * "revert to what you said", which means something different for the two.
     */
    @Test
    fun `a summary has no rewrite style`() {
        assertNull(TranscriptMode.Summary(SummaryStyle.BULLETS).rewriteStyle)
        assertEquals(
            RewriteStyle.CONCISE,
            TranscriptMode.Rewrite(RewriteStyle.CONCISE).rewriteStyle,
        )
    }

    @Test
    fun `every choice is offered exactly once and verbatim is not a rewrite`() {
        val ids = TranscriptMode.ALL.map { it.id }
        assertEquals(ids.toSet().size, ids.size)
        assertTrue(ids.contains("verbatim"))
        assertFalse("verbatim must not appear as a rewrite style", ids.contains("rewrite:verbatim"))
    }

    // MARK: - History

    @Test
    fun `a record survives a json round trip with the new fields`() {
        val record = DictationRecord(
            status = DictationRecord.Status.COMPLETED,
            text = "what was said",
            styledText = "the gist",
            mode = "summary:bullets",
            sourceFileName = "meeting.m4a",
        )
        val decoded = DictationRecord.fromJson(JSONObject(record.toJson().toString()))

        assertEquals("summary:bullets", decoded.mode)
        assertEquals("meeting.m4a", decoded.sourceFileName)
        assertEquals("the gist", decoded.deliveredText)
        assertTrue(decoded.isFromFile)
        assertEquals(TranscriptMode.Summary(SummaryStyle.BULLETS), decoded.resolvedMode)
    }

    /**
     * History written before this change has no `mode` key at all. Decoding it must not fail —
     * that would empty someone's history on upgrade.
     */
    @Test
    fun `history from before modes existed still decodes`() {
        val json = JSONObject()
            .put("id", "abc")
            .put("createdAt", 1_700_000_000_000L)
            .put("status", "completed")
            .put("text", "an older dictation")
            .put("model", "gemini-3.6-flash")
            .put("fidelity", "light")

        val decoded = DictationRecord.fromJson(json)
        assertNull(decoded.mode)
        assertEquals(TranscriptMode.Verbatim, decoded.resolvedMode)
        assertEquals("an older dictation", decoded.deliveredText)
        assertFalse(decoded.isFromFile)
    }
}
