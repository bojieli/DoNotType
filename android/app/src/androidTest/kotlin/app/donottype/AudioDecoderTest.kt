package app.donottype

import android.net.Uri
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.filters.LargeTest
import app.donottype.audio.AudioDecoder
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Decoding a recording, on hardware, in every format the app offers to open.
 *
 * This has to be an instrumentation test. `MediaExtractor` and `MediaCodec` are the platform's own
 * decoders and there is no version of them on a JVM, so the whole compressed-audio path — which is
 * most of what [AudioDecoder] does — is invisible to the unit suite.
 *
 * That gap is not hypothetical. The identical gap on Windows hid a real bug for as long as it
 * existed: the decoder there reported a default format instead of the file's, every buffer was
 * converted at the wrong sample rate, and a 1.5 second recording came out at 0.4 seconds. Nothing
 * threw. Nothing logged. It was found by counting samples, which is what these assertions do.
 *
 * The fixtures are the same four files the other three platforms decode, so a pass here means the
 * same thing a pass there does. See `eval/audio/formats/README.md`.
 */
@RunWith(AndroidJUnit4::class)
@LargeTest
class AudioDecoderTest {

    private val context = ApplicationProvider.getApplicationContext<android.content.Context>()

    /** Copies a bundled fixture somewhere the decoder can be handed a real `content:`-style URI. */
    private fun fixture(name: String): Uri {
        val target = File(context.cacheDir, name)
        context.assets.open(name).use { input ->
            target.outputStream().use { output -> input.copyTo(output) }
        }
        return Uri.fromFile(target)
    }

    @Test
    fun everyOfferedFormatDecodesToTheSameSpeech() {
        // Not a loop with one assertion: each format is named in the failure so a report says which
        // decoder is missing rather than "audio is broken".
        for (name in listOf("speech.wav", "speech.mp3", "speech.m4a", "speech.opus")) {
            val wav = AudioDecoder.decodeToWav(context, fixture(name))
            assertDecodesToSpeech(wav, name)
        }
    }

    /**
     * The shape every format has to arrive in, and the length it has to have.
     *
     * Duration is the assertion that matters. A decoder handed the wrong sample rate or channel
     * count still produces plausible-looking PCM — it is just the wrong speed, and the transcript
     * comes back as a fragment of what was said with no error anywhere.
     */
    private fun assertDecodesToSpeech(wav: ByteArray, name: String) {
        assertTrue("$name did not decode to a WAV container", wav.size > 44)

        val rate = readInt(wav, 24)
        val channels = readShort(wav, 22)
        val bits = readShort(wav, 34)
        assertEquals("$name: sample rate", 16_000, rate)
        assertEquals("$name: channels", 1, channels)
        assertEquals("$name: bit depth", 16, bits)

        val samples = (wav.size - 44) / 2
        val seconds = samples.toDouble() / rate
        assertTrue(
            "$name: expected about 1.5 s, got ${"%.2f".format(seconds)} s",
            seconds > 1.25 && seconds < 1.75,
        )

        // Silence would satisfy everything above. This is speech, so something in it is loud.
        var peak = 0
        for (index in 44 until wav.size - 1 step 2) {
            val sample = ((wav[index + 1].toInt() shl 8) or (wav[index].toInt() and 0xFF)).toShort()
            peak = maxOf(peak, kotlin.math.abs(sample.toInt()))
        }
        assertTrue("$name decoded to near-silence (peak $peak)", peak > 8_000)
    }

    /** A file whose extension lies, because that is a thing recorders do. */
    @Test
    fun theContainerIsSniffedRatherThanTrustedToTheExtension() {
        val mislabelled = File(context.cacheDir, "actually-an-mp3.wav")
        context.assets.open("speech.mp3").use { input ->
            mislabelled.outputStream().use { output -> input.copyTo(output) }
        }
        assertDecodesToSpeech(
            AudioDecoder.decodeToWav(context, Uri.fromFile(mislabelled)), "actually-an-mp3.wav")
    }

    /** What someone sees when they pick the wrong file, which should be a sentence, not a crash. */
    @Test
    fun somethingThatIsNotAudioSaysSoInstead() {
        val text = File(context.cacheDir, "notes.wav")
        text.writeText("This is not a recording, it is a paragraph about one.")
        try {
            AudioDecoder.decodeToWav(context, Uri.fromFile(text))
            throw AssertionError("a text file decoded as audio")
        } catch (error: AudioDecoder.DecodeException) {
            assertTrue(
                "the message should name the file: ${error.message}",
                error.message.orEmpty().isNotEmpty(),
            )
        }
    }

    private fun readInt(bytes: ByteArray, offset: Int): Int =
        (bytes[offset].toInt() and 0xFF) or
            ((bytes[offset + 1].toInt() and 0xFF) shl 8) or
            ((bytes[offset + 2].toInt() and 0xFF) shl 16) or
            ((bytes[offset + 3].toInt() and 0xFF) shl 24)

    private fun readShort(bytes: ByteArray, offset: Int): Int =
        (bytes[offset].toInt() and 0xFF) or ((bytes[offset + 1].toInt() and 0xFF) shl 8)
}
