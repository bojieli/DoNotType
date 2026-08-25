package app.donottype.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Thought tokens are their own field, and a reported zero is not the same as silence.
 *
 * Measured 2026-08-25 on a 22-second clip: `minimal` and `low` both report exactly 0 on
 * `gemini-3.5-flash` and `gemini-3.6-flash`, `medium` reports 500 and 700, and `total_tokens`
 * equals input + output + thought. Collapsing a reported zero to null would make "the model did
 * not think" indistinguishable from "the provider does not say", which is the whole reason the
 * field is reported. See docs/MODELS.md.
 */
class TokenUsageTest {
    @Test
    fun `thought tokens add across chunks`() {
        val total = TokenUsage.add(
            TokenUsage(thoughtTokens = 500),
            TokenUsage(thoughtTokens = 700),
        )
        assertEquals(1200, total.thoughtTokens)
    }

    @Test
    fun `a reported zero survives the sum as a zero`() {
        assertEquals(
            0,
            TokenUsage.add(TokenUsage(thoughtTokens = 0), TokenUsage(thoughtTokens = 0))
                .thoughtTokens,
        )
        assertEquals(
            0,
            TokenUsage.add(TokenUsage(thoughtTokens = 0), TokenUsage()).thoughtTokens,
        )
    }

    @Test
    fun `an unreporting provider stays unreported rather than becoming zero`() {
        assertNull(TokenUsage.add(TokenUsage(), TokenUsage()).thoughtTokens)
    }
}
