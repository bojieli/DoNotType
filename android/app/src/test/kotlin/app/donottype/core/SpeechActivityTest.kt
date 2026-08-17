package app.donottype.core

import java.io.File
import kotlin.math.abs
import kotlin.math.pow
import kotlin.math.roundToInt
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/** Runs the packaged Silero graph against the same recordings as the Swift and .NET suites. */
class SpeechActivityTest {
    private val detector by lazy {
        SpeechActivity(fixture("Sources/DoNotTypeCore/Resources/silero_vad.onnx"))
    }

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

    // ---- Nothing that is not speech gets through --------------------------------------------

    @Test
    fun `nothing without speech is ever sent`() {
        listOf("digital-silence", "room-tone", "steady-noise", "hum", "too-short").forEach { name ->
            val reading = detector.measureWav(silence(name))
            assertFalse("$name would have been sent — ${reading.summary}", reading.hasSpeech)
            assertEquals("$name — ${reading.summary}", 0, reading.speechMilliseconds)
            assertTrue(reading.summary, reading.maximumProbability < 0.2)
        }
    }

    @Test
    fun `keyboard and mouse clicks are not sentences`() {
        listOf("click", "mouse-click-quiet-room").forEach { name ->
            val reading = detector.measureWav(silence(name))
            assertFalse("$name — ${reading.summary}", reading.hasSpeech)
            assertTrue(reading.summary, reading.maximumProbability < 0.2)
        }
    }

    // ---- Everything that is speech gets through --------------------------------------------

    @Test
    fun `a one word answer is still a sentence`() {
        val reading = detector.measureWav(fixture("eval/audio/short-word.wav"))
        assertTrue(reading.summary, reading.hasSpeech)
        assertTrue(reading.summary, reading.maximumProbability > 0.9)
        assertTrue(
            reading.summary,
            reading.speechMilliseconds >= SpeechActivity.MINIMUM_SPEECH_MILLISECONDS,
        )
    }

    @Test
    fun `real speech is always sent`() {
        val reading = detector.measure(speechPcm())
        assertTrue(reading.summary, reading.hasSpeech)
        assertTrue(reading.summary, reading.maximumProbability > 0.9)
    }

    @Test
    fun `quiet speech is still speech`() {
        val speech = speechPcm()
        listOf(12, 20, 32, 40, 46, 52).forEach { attenuation ->
            val reading = detector.measure(attenuated(speech, attenuation.toDouble()))
            assertTrue(
                "speech at −$attenuation dB would have been dropped — ${reading.summary}",
                reading.hasSpeech,
            )
        }
    }

    /** Emulates the narrow dynamic range that made the old relative noise floor eat speech. */
    @Test
    fun `continuous gain controlled speech needs no quiet floor`() {
        val reading = detector.measure(companded(speechPcm()))
        assertTrue(reading.summary, reading.hasSpeech)
        assertTrue(reading.summary, reading.maximumProbability > 0.9)
    }

    // ---- Shape and diagnostics ---------------------------------------------------------------

    @Test
    fun `empty and invalid recordings are handled`() {
        assertFalse(detector.measure(ByteArray(0)).hasSpeech)
        assertThrows(IllegalArgumentException::class.java) {
            detector.measureWav(ByteArray(0))
        }
    }

    @Test
    fun `a fragment shorter than the minimum is not speech`() {
        assertFalse(detector.measure(ByteArray(16_000 / 100 * 2)).hasSpeech)
    }

    @Test
    fun `summary names the detector and carries probabilities`() {
        val summary = detector.measure(speechPcm()).summary
        assertTrue(summary, "silero" in summary)
        assertTrue(summary, "speech=" in summary)
        assertTrue(summary, "max=" in summary)
        assertTrue(summary, "mean=" in summary)
    }

    private fun attenuated(pcm: ByteArray, decibels: Double): ByteArray {
        val factor = 10.0.pow(-decibels / 20.0)
        return mapSamples(pcm) { it * factor }
    }

    private fun companded(pcm: ByteArray): ByteArray = mapSamples(pcm) { sample ->
        val magnitude = (abs(sample.toDouble()) / 32_768.0).pow(0.2) * 12_000
        if (sample < 0) -magnitude else magnitude
    }

    private fun mapSamples(pcm: ByteArray, transform: (Short) -> Double): ByteArray {
        val output = ByteArray(pcm.size)
        for (index in 0 until pcm.size / 2) {
            val low = pcm[index * 2].toInt() and 0xFF
            val high = pcm[index * 2 + 1].toInt()
            val sample = ((high shl 8) or low).toShort()
            val mapped = transform(sample).roundToInt().coerceIn(-32_768, 32_767)
            output[index * 2] = (mapped and 0xFF).toByte()
            output[index * 2 + 1] = ((mapped shr 8) and 0xFF).toByte()
        }
        return output
    }
}
