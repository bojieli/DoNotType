package app.donottype.core

import kotlin.math.abs
import kotlin.math.sin
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Mirrors `AudioChunkerTests.swift` and `AudioChunkerTests.cs`.
 *
 * Getting the WAV arithmetic subtly wrong would corrupt audio silently, and nothing downstream
 * would notice a missing second of speech -- it would simply come back as a shorter transcript.
 */
class AudioChunkerTest {
    /**
     * Builds a WAV whose loud passages are separated by true silence, so a correct splitter has
     * somewhere obvious to cut and an incorrect one has somewhere obvious to be caught.
     */
    private fun speech(vararg segments: Pair<Double, Double>): ByteArray {
        val pcm = java.io.ByteArrayOutputStream()
        var phase = 0.0
        for ((loud, silence) in segments) {
            repeat((loud * 16_000).toInt()) {
                phase += 2 * Math.PI * 220 / 16_000
                val sample = (sin(phase) * 12_000).toInt().toShort()
                pcm.write(sample.toInt() and 0xFF)
                pcm.write((sample.toInt() shr 8) and 0xFF)
            }
            pcm.write(ByteArray((silence * 16_000).toInt() * 2))
        }
        return AudioChunker.wrapInWavContainer(pcm.toByteArray())
    }

    private fun seconds(value: Double) = speech(value to 0.0)

    @Test
    fun `short recordings are not split`() {
        val chunks = AudioChunker.split(seconds(20.0))
        assertEquals(1, chunks.size)
        assertEquals(20.0, chunks[0].durationSeconds, 0.05)
    }

    /** Unparseable data is passed through whole rather than mangled. */
    @Test
    fun `non wav data is passed through untouched`() {
        val junk = "not a wav file at all".toByteArray()
        val chunks = AudioChunker.split(junk)
        assertEquals(1, chunks.size)
        assertTrue(junk.contentEquals(chunks[0].data))
    }

    /**
     * Every sample must appear in exactly one chunk. A splitter that drops a second of audio loses
     * a word, and nothing downstream would ever notice.
     */
    @Test
    fun `no audio is lost or duplicated`() {
        val original = speech(*Array(6) { 55.0 to 4.0 })
        val chunks = AudioChunker.split(original)
        assertTrue(chunks.size > 1)

        val rejoined = java.io.ByteArrayOutputStream()
        chunks.forEach { rejoined.write(AudioChunker.pcmBody(it.data)!!) }
        assertTrue(
            "chunks must reassemble into the original samples",
            AudioChunker.pcmBody(original)!!.contentEquals(rejoined.toByteArray()),
        )
    }

    @Test
    fun `chunk offsets are contiguous`() {
        val chunks = AudioChunker.split(speech(*Array(6) { 55.0 to 4.0 }))
        for (index in 1 until chunks.size) {
            assertEquals(
                chunks[index - 1].startSeconds + chunks[index - 1].durationSeconds,
                chunks[index].startSeconds,
                0.01,
            )
        }
    }

    /** The point of the whole exercise: cuts land in silence, not mid-word. */
    @Test
    fun `cuts land in silence`() {
        val segments = Array(6) { 55.0 to 4.0 }
        val chunks = AudioChunker.split(speech(*segments))
        assertTrue(chunks.size > 1)

        for (chunk in chunks.dropLast(1)) {
            val body = AudioChunker.pcmBody(chunk.data)!!
            val tail = body.copyOfRange(maxOf(0, body.size - 1_600), body.size) // final 50 ms
            var peak = 0
            var index = 0
            while (index + 1 < tail.size) {
                val sample =
                    ((tail[index].toInt() and 0xFF) or (tail[index + 1].toInt() shl 8)).toShort()
                peak = maxOf(peak, abs(sample.toInt()))
                index += 2
            }
            assertTrue("chunk ${chunk.index} ends mid-speech (peak $peak)", peak < 500)
        }
    }

    /** A trailing two-second fragment transcribes badly, so the last cut is skipped. */
    @Test
    fun `final chunk is not a stub`() {
        val chunks = AudioChunker.split(speech(55.0 to 4.0, 55.0 to 4.0, 63.0 to 0.0))
        assertTrue(chunks.last().durationSeconds > 15)
    }

    @Test
    fun `continuous speech without VAD pause is not split`() {
        assertEquals(1, AudioChunker.split(seconds(300.0)).size)
    }

    @Test
    fun `short dip is not a word boundary`() {
        assertEquals(1, AudioChunker.split(speech(55.0 to 0.2, 65.0 to 0.0)).size)
    }

    @Test
    fun `streaming waits for threshold and emits during capture`() {
        val body = AudioChunker.pcmBody(speech(55.0 to 4.0, 35.0 to 0.0))!!
        val segmenter = AudioChunker.StreamingSegmenter()
        assertTrue(segmenter.append(body.copyOfRange(0, 90 * 32_000)).isEmpty())
        val ready = segmenter.append(body.copyOfRange(90 * 32_000, body.size))
        assertEquals(1, ready.size)
        assertEquals(57.0, ready[0].durationSeconds, 0.1)
        assertEquals(37.0, segmenter.finish()!!.durationSeconds, 0.1)
    }

    @Test
    fun `generated chunks are valid wav files`() {
        for (chunk in AudioChunker.split(speech(*Array(6) { 55.0 to 4.0 }))) {
            assertEquals('R'.code.toByte(), chunk.data[0])
            assertEquals('W'.code.toByte(), chunk.data[8])

            // The RIFF size field must match the real length or strict decoders reject the file.
            val declared = (chunk.data[4].toInt() and 0xFF) or
                ((chunk.data[5].toInt() and 0xFF) shl 8) or
                ((chunk.data[6].toInt() and 0xFF) shl 16) or
                ((chunk.data[7].toInt() and 0xFF) shl 24)
            assertEquals(chunk.data.size - 8, declared)
            assertEquals(0, AudioChunker.pcmBody(chunk.data)!!.size % 2)
        }
    }

    /** Real recorders emit LIST/INFO chunks before the data. */
    @Test
    fun `data chunk is found past extra metadata chunks`() {
        val plain = seconds(2.0)
        val body = AudioChunker.pcmBody(plain)!!

        val out = java.io.ByteArrayOutputStream()
        out.write(plain.copyOfRange(0, 36))
        out.write("LIST".toByteArray())
        out.write(byteArrayOf(4, 0, 0, 0))
        out.write("INFO".toByteArray())
        out.write("data".toByteArray())
        out.write(
            byteArrayOf(
                (body.size and 0xFF).toByte(),
                ((body.size shr 8) and 0xFF).toByte(),
                ((body.size shr 16) and 0xFF).toByte(),
                ((body.size shr 24) and 0xFF).toByte(),
            ),
        )
        out.write(body)

        assertEquals(body.size, AudioChunker.pcmBody(out.toByteArray())!!.size)
    }

    @Test
    fun `stitch joins with a single space and drops empty pieces`() {
        assertEquals("one two three four", AudioChunker.stitch(listOf("one two", "three four")))
        assertEquals("one two", AudioChunker.stitch(listOf("  one  ", "", "\n", " two")))
        assertEquals("", AudioChunker.stitch(emptyList()))
    }
}

/**
 * The boundary scorer's distance penalty, and the default policy it operates under.
 *
 * Mirrors `BoundaryScoreTests` in Swift and the equivalent cases in C#. The C# port had drifted:
 * a record struct ignores its primary constructor's defaults for `new()`, so that client's default
 * policy was every field zero and it split at the first 20 ms quiet frame. Pinning the values in
 * all three is cheaper than finding that again.
 */
class BoundaryPolicyParityTest {
    @Test
    fun `the default policy is the one the other cores use`() {
        val policy = AudioChunker.BoundaryPolicy()
        kotlin.test.assertEquals(45.0, policy.minimumSeconds)
        kotlin.test.assertEquals(60.0, policy.targetSeconds)
        kotlin.test.assertEquals(75.0, policy.horizonSeconds)
        kotlin.test.assertEquals(0.32, policy.minimumPauseSeconds)
        kotlin.test.assertEquals(0.5, policy.preferredPauseSeconds)
    }

    /**
     * A clean sentence break inside the window beats a shallow breath sitting on the target.
     *
     * The distance penalty used to be the raw difference from the target — linear, unbounded, and
     * in the same units as nothing else in the score — so a 1.4 s pause twelve seconds early lost
     * to a 0.4 s one on the target every time.
     */
    @Test
    fun `a long pause inside the window beats a short one on the target`() {
        // Ordinary pauses first: the floor is the 2nd percentile of frame energy, so a fixture
        // whose only quiet is the pause under test estimates its floor from speech itself.
        val pcm = speech(
            4.0 to 0.7, 8.0 to 0.7, 10.0 to 0.7, 10.0 to 0.7,
            14.0 to 1.4, 11.0 to 0.4, 40.0 to 0.0,
        )
        val cut = kotlin.test.assertNotNull(AudioChunker.bestBoundary(pcm))
        val seconds = cut / 32_000.0
        kotlin.test.assertTrue(
            seconds in 47.5..49.5,
            "cut landed at $seconds s, expected the 1.4 s pause",
        )
    }

    private fun speech(vararg segments: Pair<Double, Double>): ByteArray {
        val out = java.io.ByteArrayOutputStream()
        var phase = 0.0
        for ((loud, silence) in segments) {
            repeat((loud * 16_000).toInt()) {
                phase += 2 * Math.PI * 220 / 16_000
                val sample = (kotlin.math.sin(phase) * 12_000).toInt().toShort()
                out.write(sample.toInt() and 0xFF)
                out.write((sample.toInt() shr 8) and 0xFF)
            }
            out.write(ByteArray((silence * 16_000).toInt() * 2))
        }
        return out.toByteArray()
    }
}
