package app.donottype.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Mirrors Tests/DoNotTypeCoreTests/HallucinationGuardTests.swift. The numbers come from real
 * dictations the macOS app stored, not from invented examples.
 */
class HallucinationGuardTest {

    @Test
    fun `the exact marker is recognised`() {
        assertTrue(HallucinationGuard.isNoSpeechMarker("[NO_SPEECH]"))
    }

    @Test
    fun `the marker survives the decoration models add to it`() {
        listOf("[NO_SPEECH].", " [NO_SPEECH] ", "\"[NO_SPEECH]\"", "[no_speech]", "NO_SPEECH")
            .forEach { assertTrue(it, HallucinationGuard.isNoSpeechMarker(it)) }
    }

    /**
     * The strictness is the point: a loose match on the words would delete a real dictation of
     * somebody saying them.
     */
    @Test
    fun `speech about no speech is not the marker`() {
        listOf(
            "No speech was detected in the recording.",
            "there was no speech",
            "The [NO_SPEECH] token is what the model writes.",
        ).forEach { assertFalse(it, HallucinationGuard.isNoSpeechMarker(it)) }
    }

    @Test
    fun `the marker becomes an empty transcript`() {
        val (transcript, verdict) =
            HallucinationGuard.inspect(Transcript("[NO_SPEECH]", "en"), 0.7)
        assertEquals("", transcript.transcript)
        assertEquals(HallucinationGuard.Verdict.NoSpeechMarker, verdict)
        assertEquals("en", transcript.language)
    }

    /** 876 characters from 0.68 seconds of room tone: 1288 characters a second. */
    @Test
    fun `the measured fabrication is caught`() {
        assertTrue(HallucinationGuard.exceedsPlausibleRate("a".repeat(876), 0.68))
    }

    /** Every real dictation measured through the app, at its recorded length. */
    @Test
    fun `real dictations are kept`() {
        listOf(27 to 3.37, 72 to 8.18, 100 to 14.58, 221 to 32.20, 244 to 32.37, 30 to 2.03)
            .forEach { (characters, seconds) ->
                assertFalse(
                    "$characters chars in ${seconds}s should be plausible",
                    HallucinationGuard.exceedsPlausibleRate("a".repeat(characters), seconds),
                )
            }
    }

    /** A fast speaker is roughly 17 characters a second. */
    @Test
    fun `a fast speaker is not suppressed`() {
        assertFalse(HallucinationGuard.exceedsPlausibleRate("a".repeat(170), 10.0))
    }

    /**
     * The case that caught the first threshold: an ordinary sentence over two seconds of audio is
     * 35 characters a second and entirely real.
     */
    @Test
    fun `an ordinary sentence over short audio is kept`() {
        val sentence = "I said the version is three point five, and Kaelith owns the rollout."
        assertTrue(sentence.length > HallucinationGuard.MAXIMUM_CHARACTERS_PER_SECOND * 2)
        assertFalse(HallucinationGuard.exceedsPlausibleRate(sentence, 2.0))
    }

    @Test
    fun `a short clip with one long word is kept`() {
        assertFalse(HallucinationGuard.exceedsPlausibleRate("internationalisation", 1.0))
    }

    @Test
    fun `unknown duration is never suspicious`() {
        assertFalse(HallucinationGuard.exceedsPlausibleRate("a".repeat(2000), null))
        assertFalse(HallucinationGuard.exceedsPlausibleRate("a".repeat(2000), 0.0))
    }

    @Test
    fun `the verdict carries the measurement`() {
        val (transcript, verdict) =
            HallucinationGuard.inspect(Transcript("a".repeat(625), "en"), 0.76)
        assertEquals("", transcript.transcript)
        val rate = verdict as HallucinationGuard.Verdict.ImpossibleRate
        assertEquals(625, rate.characters)
        assertEquals(0.76, rate.seconds, 0.001)
        assertTrue(verdict.summary, verdict.summary.contains("822"))
    }

    @Test
    fun `an ordinary transcript passes through untouched`() {
        val original = Transcript("Could you rebuild and reinstall the app?", "en")
        val (transcript, verdict) = HallucinationGuard.inspect(original, 8.18)
        assertEquals(original, transcript)
        assertEquals(HallucinationGuard.Verdict.Kept, verdict)
    }
}
