package app.donottype.core

import java.io.File
import kotlin.math.PI
import kotlin.math.roundToInt
import kotlin.math.sin
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The bars in the keyboard's recording indicator, against the same fixtures the Swift and C# suites
 * use — so every client is held to the same numbers rather than to the same description of them.
 *
 * See `eval/audio/MANIFEST.md` for what each recording is.
 */
class AudioLevelMeterTest {

    /** Every fixture with somebody talking in it. */
    private val speechFixtures = listOf(
        "gemini-version.wav",
        "git-command.wav",
        "jargon-spelling.wav",
        "novel-codename.wav",
        "novel-name.wav",
        "novel-repo.wav",
        "person-name.wav",
        "port-number.wav",
        "real-acronym-chain.wav",
        "real-acronym.wav",
        "real-brand.wav",
        "real-codeswitch.wav",
        "real-jargon.wav",
        "real-mandarin.wav",
        "real-talk-gemini15.wav",
        "formats/speech.wav",
    )

    private fun fixture(relative: String): ByteArray {
        var directory = File(System.getProperty("user.dir") ?: ".").absoluteFile
        repeat(8) {
            val candidate = File(directory, relative)
            if (candidate.exists()) return candidate.readBytes()
            directory = directory.parentFile ?: return@repeat
        }
        throw AssertionError("fixture $relative not found")
    }

    /** The bars a whole recording would draw, in order. */
    private fun bars(name: String): List<AudioLevelMeter.Bar> {
        val body = AudioChunker.pcmBody(fixture("eval/audio/$name"))
            ?: throw AssertionError("$name is not a WAV this test can read")
        return AudioLevelMeter().append(body)
    }

    private fun pcm(samples: List<Int>): ByteArray {
        val bytes = ByteArray(samples.size * 2)
        samples.forEachIndexed { index, sample ->
            bytes[index * 2] = (sample and 0xFF).toByte()
            bytes[index * 2 + 1] = ((sample shr 8) and 0xFF).toByte()
        }
        return bytes
    }

    private fun percentile(values: List<Double>, fraction: Double): Double {
        val sorted = values.sorted()
        return sorted[minOf(sorted.size - 1, (sorted.size * fraction).toInt())]
    }

    // ---- The scale -------------------------------------------------------------------------------

    /** The table in AudioLevelMeter's documentation, which is where the span came from. */
    @Test
    fun `the scale is the documented table`() {
        listOf(
            -240.0 to 0.00, // digital silence
            -58.0 to 0.04, // room tone
            -44.0 to 0.30, // quiet speech
            -21.0 to 0.72, // conversational speech
            -14.0 to 0.85, // loud speech
            -5.0 to 1.00, // the loudest frame in any fixture
        ).forEach { (decibels, level) ->
            assertEquals(
                "$decibels dBFS should draw $level of a bar",
                level,
                AudioLevelMeter.level(decibels),
                0.01,
            )
        }
    }

    @Test
    fun `the scale is clamped at both ends`() {
        assertEquals(0.0, AudioLevelMeter.level(-120.0), 0.0)
        assertEquals(0.0, AudioLevelMeter.level(AudioLevelMeter.FLOOR_DECIBELS), 0.0)
        assertEquals(1.0, AudioLevelMeter.level(AudioLevelMeter.CEILING_DECIBELS), 0.0)
        assertEquals(1.0, AudioLevelMeter.level(0.0), 0.0)
    }

    // ---- Clipping --------------------------------------------------------------------------------

    /** Audio clamped at the rail says so. */
    @Test
    fun `audio at the rail clips`() {
        val bars = AudioLevelMeter().append(pcm(List(16_000) { 32_100 }))
        assertTrue(bars.isNotEmpty())
        assertTrue(bars.all { it.isClipping && it.level == 1.0 })
    }

    /** A full bar is not a clipped one: this tone uses the whole meter and touches nothing. */
    @Test
    fun `a loud clean tone fills the meter without clipping`() {
        // −6 dBFS peak: half of full scale, which is loud and entirely undamaged.
        val tone = List(16_000) { (16_384 * sin(it * 2 * PI * 220 / 16_000)).roundToInt() }
        val bars = AudioLevelMeter().append(pcm(tone))
        assertTrue(bars.isNotEmpty())
        assertFalse(bars.any { it.isClipping })
    }

    /** One sample landing on the rail is a peak, not a clipped waveform. */
    @Test
    fun `a single sample at the rail is not clipping`() {
        val frame = MutableList(960) { 1_000 } // one bar
        frame[100] = 32_767
        frame[400] = -32_768
        assertFalse(AudioLevelMeter().append(pcm(frame)).any { it.isClipping })
    }

    /**
     * The measurement the sample-counting rule replaced an energy threshold for. `real-brand` at
     * twice its recorded gain clamps 1.5% of its samples — audible distortion, and the point at
     * which somebody can still fix it by turning the gain down.
     */
    @Test
    fun `the onset of clipping is visible`() {
        val body = AudioChunker.pcmBody(fixture("eval/audio/real-brand.wav"))!!
        val doubled = ArrayList<Int>(body.size / 2)
        for (index in 0 until body.size / 2) {
            val low = body[index * 2].toInt() and 0xFF
            val high = body[index * 2 + 1].toInt()
            val sample = ((high shl 8) or low).toShort().toInt() * 2
            doubled += sample.coerceIn(-32_768, 32_767)
        }

        val bars = AudioLevelMeter().append(pcm(doubled))
        val clipping = bars.count { it.isClipping }.toDouble() / bars.size
        assertTrue(
            "only ${"%.1f".format(clipping * 100)}% of bars report a recording " +
                "clamping 1.5% of its samples",
            clipping > 0.10,
        )
    }

    // ---- What a voice looks like -----------------------------------------------------------------

    /**
     * The failure the decibel scale exists to fix. A peak-driven multiplier sat pinned at the top
     * of the meter through most of a normally-recorded voice, so it could say "sound is arriving"
     * and nothing else.
     */
    @Test
    fun `speech neither pins the meter nor reads as clipping`() {
        speechFixtures.forEach { name ->
            val bars = bars(name)
            val pinned = bars.count { it.level >= 0.999 }.toDouble() / bars.size
            assertTrue(
                "$name spends ${"%.0f".format(pinned * 100)}% of itself at full scale",
                pinned < 0.01,
            )

            // Three of these recordings do touch the rail here and there — they are normalised,
            // and `real-brand` marks 0.6% of its bars — but a voice recorded at a sane level must
            // never *read* as clipping, which is a claim about how often.
            val clipping = bars.count { it.isClipping }.toDouble() / bars.size
            assertTrue(
                "$name reports clipping on ${"%.1f".format(clipping * 100)}% of its bars",
                clipping < 0.01,
            )
        }
    }

    /** Speech lives in the top of the meter, so the bars read at a glance. */
    @Test
    fun `speech uses the top of the meter`() {
        speechFixtures.forEach { name ->
            val loudest = percentile(bars(name).map { it.level }, 0.90)
            assertTrue(
                "$name draws only ${"%.2f".format(loudest)} of a bar when it is loud",
                loudest > 0.6,
            )
        }
    }

    /**
     * And moves inside it: a meter that is tall but static answers "is the mic on", not "how loud".
     * Measured spread across these fixtures is 0.25–0.77 of the meter's height.
     */
    @Test
    fun `the meter moves with the voice`() {
        speechFixtures.forEach { name ->
            val levels = bars(name).map { it.level }
            val spread = percentile(levels, 0.90) - percentile(levels, 0.10)
            assertTrue(
                "$name moves through only ${"%.2f".format(spread)} of the meter",
                spread > 0.20,
            )
        }
    }

    /**
     * A quiet room is flat. It is not empty — the meter reports level, and a room has one — but
     * nothing in it should read as somebody speaking.
     */
    @Test
    fun `a quiet room is flat`() {
        listOf("digital-silence", "room-tone", "too-short").forEach { name ->
            val loudest = bars("silence/$name.wav").maxOf { it.level }
            assertTrue("$name draws ${"%.2f".format(loudest)} of a bar", loudest < 0.10)
        }
    }

    /**
     * Steady noise is not flat, and should not be. `hum` and `steady-noise` sit at −34 dBFS, which
     * is louder than quiet speech and reads as roughly half a bar. That is the honest answer to
     * "how loud is the input", and it is why the decision about whether to send a recording is
     * SpeechActivity's rather than this meter's: one measures volume, the other measures whether
     * anybody spoke.
     */
    @Test
    fun `steady noise is shown as the volume it is`() {
        listOf("hum", "steady-noise").forEach { name ->
            val bars = bars("silence/$name.wav")
            assertTrue("$name should be visible", bars.maxOf { it.level } > 0.3)
            assertFalse(bars.any { it.isClipping })
        }
    }

    // ---- Framing ---------------------------------------------------------------------------------

    /**
     * `AudioRecord.read` returns whatever it has, never a whole number of frames — and is free to
     * stop between the two bytes of a sample.
     */
    @Test
    fun `partial frames and samples are carried across calls`() {
        val body = AudioChunker.pcmBody(fixture("eval/audio/formats/speech.wav"))!!
        val expected = AudioLevelMeter().append(body)

        val chunked = AudioLevelMeter()
        val actual = ArrayList<AudioLevelMeter.Bar>()
        // Odd sizes, so boundaries land mid-frame and mid-sample.
        val sizes = listOf(7, 971, 4_099, 63)
        var offset = 0
        var index = 0
        while (offset < body.size) {
            val size = minOf(sizes[index % sizes.size], body.size - offset)
            actual += chunked.append(body.copyOfRange(offset, offset + size))
            offset += size
            index += 1
        }

        assertTrue(expected.isNotEmpty())
        assertEquals(expected, actual)
    }

    @Test
    fun `audio shorter than one bar draws nothing yet`() {
        val meter = AudioLevelMeter()
        // Two frames of a three-frame bar: 640 samples of 16 kHz audio, 1280 bytes.
        assertTrue(meter.append(ByteArray(1_280)).isEmpty())
        assertEquals(1, meter.append(ByteArray(640)).size)
    }
}
