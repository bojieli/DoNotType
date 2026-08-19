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
        assertEquals(TranscriptMode.Rewrite(RewriteStyle.CASUAL), TranscriptMode.from("rewrite"))
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

    /**
     * The parity table from `docs/mode-parity.md`, repeated here verbatim.
     *
     * Four implementations of one grammar, and the failure mode is not a crash: it is a phone and a
     * laptop disagreeing about what `summary` means, which nobody would think to look for. The
     * table is duplicated in each language on purpose — a shared fixture file would be read by
     * whichever platform remembered to read it.
     */
    @Test
    fun `the mode grammar is identical on every platform`() {
        val table: List<Pair<String, String?>> = listOf(
            "verbatim" to "verbatim",
            "raw" to "verbatim",
            "transcribe" to "verbatim",
            "none" to "verbatim",
            "rewrite" to "rewrite:casual",
            "rewrite:formal" to "rewrite:formal",
            "rewrite:concise" to "rewrite:concise",
            "rewrite:casual" to "rewrite:casual",
            "rewrite:" to "rewrite:casual",
            "rewrite:verbatim" to null,
            "summary" to "summary:brief",
            "summary:" to "summary:brief",
            "summary:brief" to "summary:brief",
            "summary:bullets" to "summary:bullets",
            "summary:actions" to "summary:actions",
            "summarise" to "summary:brief",
            "summarize" to "summary:brief",
            "SUMMARY:Bullets" to "summary:bullets",
            "  summary  " to "summary:brief",
            "" to null,
            "nonsense" to null,
            "rewrite:nonsense" to null,
            "summary:nonsense" to null,
        )
        table.forEach { (typed, expected) ->
            assertEquals(
                "`$typed` must parse the same here as on macOS, Windows and iOS",
                expected,
                TranscriptMode.from(typed)?.id,
            )
        }
    }

    /**
     * The word shown while the second request is in flight, which is the one thing on screen
     * during the slowest part of a two-request mode. Four interfaces read it, so it is in the
     * table with everything else that must not drift.
     */
    @Test
    fun `the progress label is identical on every platform`() {
        val table = listOf(
            "verbatim" to "Finishing…",
            "rewrite:formal" to "Rewriting…",
            "rewrite:concise" to "Tightening…",
            "rewrite:casual" to "Loosening…",
            "summary:brief" to "Summarising…",
            "summary:bullets" to "Summarising into bullets…",
            "summary:actions" to "Picking out the actions…",
        )
        table.forEach { (typed, expected) ->
            assertEquals(typed, expected, TranscriptMode.from(typed)?.progressLabel)
        }
    }
}
