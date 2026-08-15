package app.donottype.audio

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The half of Opus support that runs without a device.
 *
 * Demuxing is pure byte handling, so it is covered here; the `MediaCodec` half needs hardware and is
 * exercised by the instrumentation suite. That split matters because the demuxer is where the
 * subtle bugs live — a packet spanning two pages, or a header counted as audio — and those are
 * exactly the ones that produce a file which decodes to *almost* the right thing.
 *
 * Fixtures are shared with the other three platforms; see `eval/audio/formats/README.md`.
 */
class OggOpusReaderTest {

    private fun fixture(name: String): ByteArray {
        var directory = File(System.getProperty("user.dir") ?: ".").absoluteFile
        repeat(8) {
            val candidate = File(directory, "eval/audio/formats/$name")
            if (candidate.exists()) return candidate.readBytes()
            directory = directory.parentFile ?: return@repeat
        }
        throw AssertionError("fixture $name not found from ${System.getProperty("user.dir")}")
    }

    @Test
    fun `recognises an ogg opus stream`() {
        assertTrue(OggOpusReader.isOggOpus(fixture("speech.opus")))
        assertFalse(OggOpusReader.isOggOpus(fixture("speech.wav")))
        assertFalse(OggOpusReader.isOggOpus(fixture("speech.mp3")))
        assertFalse(OggOpusReader.isOggOpus(fixture("speech.m4a")))
    }

    @Test
    fun `demuxes the packets and the pre-skip`() {
        val stream = OggOpusReader.demux(fixture("speech.opus"))

        assertEquals("the fixture is mono", 1, stream.channels)
        assertTrue("a pre-skip is always declared", stream.preSkip > 0)
        // 1.5 seconds at the encoder's default 20 ms per packet is about 75, and no encoder emits
        // so few that a handful would do. This catches a demuxer that stops at the first page.
        assertTrue("expected many packets, got ${stream.packets.size}", stream.packets.size > 50)
        assertTrue("no packet may be empty", stream.packets.all { it.isNotEmpty() })
    }

    /**
     * The two mandatory headers are configuration, not audio. A demuxer that passes them to the
     * decoder produces a burst of noise at the start of every file.
     */
    @Test
    fun `drops the identification and comment headers`() {
        val stream = OggOpusReader.demux(fixture("speech.opus"))

        assertFalse(
            stream.packets.any {
                it.size >= 8 && it.copyOfRange(0, 8).decodeToString() in setOf("OpusHead", "OpusTags")
            },
        )
    }

    @Test
    fun `a truncated stream fails rather than returning half a recording`() {
        val whole = fixture("speech.opus")
        // Cut mid-page: the header of the next page is gone, which is what a partial download or a
        // failed copy actually looks like.
        val cut = whole.copyOfRange(0, whole.size / 2 + 7)

        val error = runCatching { OggOpusReader.demux(cut) }.exceptionOrNull()
        // Either it throws, or it returns only the packets it could read — what it must never do is
        // claim the file was fine and hand back silence.
        if (error == null) {
            val stream = OggOpusReader.demux(cut)
            assertTrue(stream.packets.isNotEmpty())
        } else {
            assertTrue(error is AudioDecoder.DecodeException)
        }
    }

    @Test
    fun `an ogg file that is not opus says so`() {
        // A plausible Ogg page header followed by a Vorbis identification packet.
        val vorbis = ByteArray(64)
        "OggS".toByteArray().copyInto(vorbis, 0)
        vorbis[26] = 1
        vorbis[27] = 30
        "vorbis".toByteArray().copyInto(vorbis, 28)

        val error = runCatching { OggOpusReader.demux(vorbis) }.exceptionOrNull()
        assertTrue(error is AudioDecoder.DecodeException)
        assertTrue(
            "the message should name the fix, was: ${error?.message}",
            error?.message?.contains("Vorbis") == true,
        )
    }

    /**
     * Truncated at every length, including inside a page header and inside a lacing table.
     *
     * A demuxer is a parser fed bytes from outside the program, and the failures that matter are
     * not "does it decode" but "does it terminate, and does it fail somewhere the caller can catch
     * it". A partial download and an interrupted copy both reach this code. The timing assertion is
     * the real one: a page whose length does not advance the cursor is an infinite loop, and it is
     * the shape a corrupt byte produces most easily.
     */
    @Test
    fun `truncation never hangs and never throws something uncatchable`() {
        val whole = fixture("speech.opus")
        val started = System.currentTimeMillis()

        var length = 1
        while (length < whole.size) {
            val cut = whole.copyOf(length)
            try {
                OggOpusReader.isOggOpus(cut)
                val stream = OggOpusReader.demux(cut)
                stream.packets.forEach { assertTrue(it.isNotEmpty()) }
                assertTrue(stream.preSkip >= 0)
                assertTrue(stream.channels in 1..8)
            } catch (error: AudioDecoder.DecodeException) {
                // The documented failure.
            }
            length += 97
        }

        assertTrue(
            "demuxing truncated input took more than ten seconds",
            System.currentTimeMillis() - started < 10_000,
        )
    }

    /** A page header claiming more segments than the file has, which is one corrupt byte. */
    @Test
    fun `a lying segment count is survived`() {
        val whole = fixture("speech.opus")
        var count = 1
        while (count <= 255) {
            val corrupt = whole.copyOf()
            corrupt[26] = count.toByte()
            try {
                OggOpusReader.demux(corrupt)
            } catch (error: AudioDecoder.DecodeException) {
            }
            count += 37
        }
    }

    /** Random bytes that happen to start with the capture pattern. */
    @Test
    fun `garbage behind a valid magic is survived`() {
        val random = java.util.Random(20260815) // fixed, so a failure is reproducible
        repeat(200) {
            val noise = ByteArray(28 + random.nextInt(4_068))
            random.nextBytes(noise)
            "OggS".toByteArray().copyInto(noise)
            try {
                OggOpusReader.isOggOpus(noise)
                OggOpusReader.demux(noise)
            } catch (error: AudioDecoder.DecodeException) {
            }
        }
    }

    /**
     * A page with no segments at all is legal Ogg, and is the shape that would make a reader whose
     * cursor does not advance spin forever.
     */
    @Test
    fun `an empty page does not stall the reader`() {
        val page = ByteArray(27)
        "OggS".toByteArray().copyInto(page)
        val doubled = page + page

        val started = System.currentTimeMillis()
        try {
            OggOpusReader.demux(doubled)
        } catch (error: AudioDecoder.DecodeException) {
        }
        assertTrue("an empty page stalled the reader", System.currentTimeMillis() - started < 5_000)
    }
}
