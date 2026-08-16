package app.donottype.core

import java.io.File
import kotlin.math.roundToInt
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The gate that stops silence reaching a model, against the same fixtures the Swift and C# suites
 * use — so all four clients are held to the same numbers.
 *
 * See `eval/audio/silence/README.md` for what each recording is and why.
 */
class SpeechActivityTest {

    private fun fixture(relative: String): ByteArray {
        var directory = File(System.getProperty("user.dir") ?: ".").absoluteFile
        repeat(8) {
            val candidate = File(directory, relative)
            if (candidate.exists()) return candidate.readBytes()
            directory = directory.parentFile ?: return@repeat
        }
        throw AssertionError("fixture $relative not found")
    }

    private fun silence(name: String) = fixture("eval/audio/silence/$name.wav")

    private fun speechPcm() = AudioChunker.pcmBody(fixture("eval/audio/formats/speech.wav"))!!

    // ---- Nothing that is not speech gets through -------------------------------------------------

    /** The whole point. Each of these, handed to a model, is an invitation to invent a sentence. */
    @Test
    fun `nothing without speech is ever sent`() {
        listOf("digital-silence", "room-tone", "steady-noise", "hum", "too-short").forEach { name ->
            val reading = SpeechActivity.measureWav(silence(name))
            assertFalse(
                "$name would have been sent to a model — ${reading.summary}",
                reading.hasSpeech,
            )
            assertEquals("$name — ${reading.summary}", 0, reading.speechMilliseconds)
        }
    }

    /**
     * A hum is loud — louder than quiet speech — and still not speech. Gating on volume would send
     * this and drop somebody talking softly, which is the wrong way round.
     */
    @Test
    fun `a loud hum is still not speech`() {
        val hum = SpeechActivity.measureWav(silence("hum"))
        val quiet = SpeechActivity.measure(attenuated(speechPcm(), 30.0))

        assertFalse(hum.summary, hum.hasSpeech)
        assertTrue(quiet.summary, quiet.hasSpeech)
        assertTrue(
            "the hum really is the louder recording, which is what makes this test worth having",
            hum.peakDecibels > quiet.noiseFloorDecibels,
        )
    }

    /**
     * One keyboard click has enormous dynamic range and lasts 20 ms. Duration is what separates it
     * from speech, not level.
     */
    @Test
    fun `a keyboard click is not a sentence`() {
        val reading = SpeechActivity.measureWav(silence("click"))
        assertFalse(reading.summary, reading.hasSpeech)
        assertTrue(reading.summary, reading.speechMilliseconds < 100)
    }

    /**
     * The recording this gate was rebuilt around: one mouse click in a very quiet room. 380 ms
     * above the floor is past the 200 ms threshold, and a −37 dB transient over a −63 dB floor is
     * 26 dB of range — in a silent room any sound clears a relative margin. What it does not have
     * is a voice's spectrum.
     */
    @Test
    fun `a mouse click in a quiet room is not a sentence`() {
        val reading = SpeechActivity.measureWav(silence("mouse-click-quiet-room"))
        assertTrue(
            "the premise is that duration alone lets it through — ${reading.summary}",
            reading.speechMilliseconds > SpeechActivity.MINIMUM_SPEECH_MILLISECONDS,
        )
        assertFalse(reading.summary, reading.hasSpeech)
    }

    // ---- Everything that is speech gets through --------------------------------------------------

    /**
     * The constraint on the spectral test. "Yes." is a single 320 ms burst — the same duration and
     * shape as the mouse click above, so any rule separating them by length or burst count would
     * drop this.
     */
    @Test
    fun `a one word answer is still a sentence`() {
        val reading = SpeechActivity.measureWav(fixture("eval/audio/short-word.wav"))
        assertTrue(
            "this must be short enough that the spectral test admits it — ${reading.summary}",
            reading.speechMilliseconds < SpeechActivity.STRONG_SPEECH_MILLISECONDS,
        )
        assertTrue(reading.summary, reading.hasSpeech)
    }

    /** Stated as a number so narrowing it has to be an argument rather than an edit. */
    @Test
    fun `the voice band separates a click from a voice`() {
        val click = SpeechActivity.measureWav(silence("mouse-click-quiet-room"))
        val word = SpeechActivity.measureWav(fixture("eval/audio/short-word.wav"))

        assertTrue(click.summary, click.voiceBandRatio < SpeechActivity.MINIMUM_VOICE_BAND_RATIO)
        assertTrue(word.summary, word.voiceBandRatio > SpeechActivity.MINIMUM_VOICE_BAND_RATIO)
        assertTrue(
            "the threshold is only defensible while these are far apart",
            word.voiceBandRatio - click.voiceBandRatio > 0.08,
        )
    }

    /**
     * The failure that would matter more than the one this prevents. A stray "Thank you." is
     * annoying; dropping a sentence somebody said is unforgivable.
     */
    @Test
    fun `real speech is always sent`() {
        val reading = SpeechActivity.measure(speechPcm())
        assertTrue(reading.summary, reading.hasSpeech)
        assertTrue(reading.summary, reading.speechMilliseconds > 800)
    }

    /** Somebody dictating quietly on a bus, or a phone held at arm's length. */
    @Test
    fun `quiet speech is still speech`() {
        val speech = speechPcm()
        listOf(12, 20, 32, 40, 46).forEach { attenuation ->
            val reading = SpeechActivity.measure(attenuated(speech, attenuation.toDouble()))
            assertTrue(
                "speech at −$attenuation dB would have been dropped — ${reading.summary}",
                reading.hasSpeech,
            )
        }
    }

    /**
     * The margin between the two, as a number, so a change to the threshold has to argue with it
     * rather than quietly narrow it.
     */
    @Test
    fun `the margin between speech and noise is wide`() {
        val loudestNoise = listOf("digital-silence", "room-tone", "steady-noise", "hum", "click")
            .maxOf { SpeechActivity.measureWav(silence(it)).speechMilliseconds }
        val quietestSpeech = SpeechActivity.measure(attenuated(speechPcm(), 46.0)).speechMilliseconds

        assertTrue("noise reached $loudestNoise ms", loudestNoise <= 100)
        assertTrue("quiet speech only reached $quietestSpeech ms", quietestSpeech >= 400)
        assertTrue(
            "the threshold is only defensible while these are far apart",
            quietestSpeech > loudestNoise * 4,
        )
    }

    // ---- Shape ------------------------------------------------------------------------------------

    @Test
    fun `an empty recording is not speech`() {
        assertFalse(SpeechActivity.measure(ByteArray(0)).hasSpeech)
        assertFalse(SpeechActivity.measureWav(ByteArray(0)).hasSpeech)
    }

    /** A recording shorter than one frame cannot be measured, and is not assumed to be speech. */
    @Test
    fun `a fragment shorter than a frame is not speech`() {
        assertFalse(SpeechActivity.measure(ByteArray(16_000 / 100 * 2)).hasSpeech)
    }

    private fun attenuated(pcm: ByteArray, decibels: Double): ByteArray {
        val factor = Math.pow(10.0, -decibels / 20.0)
        val output = ByteArray(pcm.size)
        for (index in 0 until pcm.size / 2) {
            val low = pcm[index * 2].toInt() and 0xFF
            val high = pcm[index * 2 + 1].toInt()
            val sample = ((high shl 8) or low).toShort()
            val scaled = (sample * factor).roundToInt().coerceIn(-32_768, 32_767)
            output[index * 2] = (scaled and 0xFF).toByte()
            output[index * 2 + 1] = ((scaled shr 8) and 0xFF).toByte()
        }
        return output
    }
}
