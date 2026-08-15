package app.donottype

import app.donottype.core.ContextEncoder
import app.donottype.core.DictationRecord
import app.donottype.core.InputPart
import app.donottype.core.ScreenContext
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * What the inspector shows.
 *
 * The claim it makes is strong — "this is what was sent" — so the test is that its output contains
 * the encoder's actual output, not that it contains something plausible.
 */
class ContextInspectorTest {

    private fun record(context: ScreenContext?) = DictationRecord(
        text = "the number is 4240",
        model = "gemini-3.6-flash",
        appName = "Mail",
        context = context,
    )

    private val sample = ScreenContext(
        appName = "Mail",
        windowTitle = "Re: the figure",
        visibleText = "the quarterly number is 4240",
        textBeforeCaret = "as discussed, ",
        selectedText = "4240",
    )

    /**
     * Every part the encoder produced has to appear. Not "some text about the screen" — the exact
     * strings that went into the request body, because that is what the view claims to be.
     */
    @Test
    fun `it contains what the encoder actually produced`() {
        val report = ContextInspector.describe(record(sample))

        val parts = ContextEncoder().encode(sample).filterIsInstance<InputPart.Text>()
        assertTrue("the encoder produced nothing to check", parts.isNotEmpty())
        parts.forEach { part ->
            assertTrue(
                "the inspector is missing a part the request contained:\n${part.text}",
                report.contains(part.text),
            )
        }
    }

    /** Including the header that tells the model not to transcribe the screen. */
    @Test
    fun `the reference-only header is visible too`() {
        val report = ContextInspector.describe(record(sample))
        assertTrue(report.contains(ContextEncoder.HEADER))
    }

    /**
     * "Nothing was sent" and "something was sent and it was blank" are different facts, and the
     * one on screen has to be the true one.
     */
    @Test
    fun `a dictation with no context says so rather than showing an empty section`() {
        val report = ContextInspector.describe(record(null))
        assertTrue(report.contains("No context was sent"))
        assertFalse(report.contains("Part 1"))
    }

    @Test
    fun `a rewrite shows both versions`() {
        val rewritten = record(sample).apply {
            styledText = "The number is 4,240."
            mode = "rewrite:formal"
        }
        val report = ContextInspector.describe(rewritten)

        assertTrue(report.contains("What you said"))
        assertTrue(report.contains("the number is 4240"))
        assertTrue(report.contains("What was inserted"))
        assertTrue(report.contains("The number is 4,240."))
        assertTrue(report.contains("rewrite:formal"))
    }

    @Test
    fun `a verbatim dictation does not claim to have been rewritten`() {
        val report = ContextInspector.describe(record(sample))
        assertFalse(report.contains("What was inserted"))
    }

    /** Whether the recording is still on disk is part of "what was sent". */
    @Test
    fun `it says whether the audio was kept`() {
        assertTrue(ContextInspector.describe(record(sample)).contains("Not retained"))

        val kept = record(sample).apply { audioFileName = "abc.wav" }
        assertTrue(ContextInspector.describe(kept).contains("Retained"))
    }
}
