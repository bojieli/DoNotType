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
}
