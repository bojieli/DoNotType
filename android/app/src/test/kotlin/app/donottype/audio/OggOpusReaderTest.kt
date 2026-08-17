package app.donottype.audio

import app.donottype.core.OggOpusWriter
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
        assertTrue(
            "a partial recording must not be returned as if it were complete",
            error is AudioDecoder.DecodeException,
        )
    }

    @Test
    fun `an ogg file that is not opus says so`() {
        // A plausible Ogg page header followed by a Vorbis identification packet.
        val vorbis = ByteArray(58)
        "OggS".toByteArray().copyInto(vorbis, 0)
        vorbis[5] = 0x04
        vorbis[26] = 1
        vorbis[27] = 30
        "vorbis".toByteArray().copyInto(vorbis, 28)
        setChecksum(vorbis)

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
            OggOpusReader.isOggOpus(cut)
            assertTrue(
                "a cut at byte $length was accepted as a complete recording",
                runCatching { OggOpusReader.demux(cut) }.exceptionOrNull()
                    is AudioDecoder.DecodeException,
            )
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
        var count = 2
        while (count <= 255) {
            val corrupt = whole.copyOf()
            corrupt[26] = count.toByte()
            assertTrue(
                runCatching { OggOpusReader.demux(corrupt) }.exceptionOrNull()
                    is AudioDecoder.DecodeException,
            )
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
            OggOpusReader.isOggOpus(noise)
            assertTrue(
                runCatching { OggOpusReader.demux(noise) }.exceptionOrNull()
                    is AudioDecoder.DecodeException,
            )
        }
    }

    @Test
    fun `a payload that fails its page checksum is rejected`() {
        val corrupt = fixture("speech.opus").copyOf()
        corrupt[corrupt.lastIndex - 10] = (corrupt[corrupt.lastIndex - 10].toInt() xor 0x40).toByte()

        val error = runCatching { OggOpusReader.demux(corrupt) }.exceptionOrNull()
        assertTrue(error is AudioDecoder.DecodeException)
        assertTrue(error?.message?.contains("checksum") == true)
    }

    @Test
    fun `unsupported channel mapping is rejected before decoding`() {
        val writer = OggOpusWriter(channels = 3)
        writer.begin()
        writer.append(byteArrayOf(0), frameCount = 320)

        val error = runCatching { OggOpusReader.demux(writer.finish()) }.exceptionOrNull()
        assertTrue(error is AudioDecoder.DecodeException)
        assertTrue(error?.message?.contains("mono or stereo") == true)
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

    private fun setChecksum(page: ByteArray) {
        val checksum = OggOpusWriter.crc32(page)
        page[22] = (checksum and 0xFF).toByte()
        page[23] = ((checksum shr 8) and 0xFF).toByte()
        page[24] = ((checksum shr 16) and 0xFF).toByte()
        page[25] = ((checksum shr 24) and 0xFF).toByte()
    }
}

/**
 * The resampler, which runs on one decoder buffer at a time and carries its position across.
 *
 * That carry is the whole difficulty. Each block is resampled without knowing where the next one
 * starts, so the fractional position left over has to survive into the next call — and if it is
 * ever negative, the next call indexes before the start of its own array.
 */
class ResamplePhaseTest {

    /** A block of a plausible shape: not silence, so a dropped block would show. */
    private fun block(size: Int): ShortArray =
        ShortArray(size) { (8_000 * kotlin.math.sin(it / 12.0)).toInt().toShort() }

    /**
     * Every block length against every rate that divides evenly.
     *
     * The crash needed the length and the step to line up: at 48 kHz to 16 kHz the step is exactly
     * 3, the loop stops at `size - 1` when the size is 1 more than a multiple of 3, and the carry
     * comes out at exactly -1.0. The next block then read `samples[-1]`. Opus decodes at 48 kHz,
     * so this was reachable by playing an ordinary file whose blocks happened to be that length.
     */
    @Test
    fun `the phase carried between blocks never points before the next block`() {
        for (rate in listOf(48_000, 32_000, 16_000, 44_100)) {
            for (size in 1..200) {
                var position = 0.0
                val output = java.io.ByteArrayOutputStream()
                // Three blocks, because the failure is always on the block after the bad one.
                repeat(3) {
                    position = AudioDecoder.resampleForOpus(block(size), rate, position, output)
                    assertTrue(
                        "rate $rate, block $size: carried phase $position is before the block",
                        position >= 0.0,
                    )
                }
            }
        }
    }

    /** The rate really is converted, rather than the samples being copied through. */
    @Test
    fun `three blocks at 48 kHz come out at 16 kHz`() {
        var position = 0.0
        val output = java.io.ByteArrayOutputStream()
        repeat(3) { position = AudioDecoder.resampleForOpus(block(960), 48_000, position, output) }

        // 3 * 960 samples at 48 kHz is 60 ms, which is 960 samples at 16 kHz, so 1920 bytes.
        val samples = output.size() / 2
        assertTrue("expected about 960 samples, got $samples", samples in 950..970)
    }
}

/**
 * How long a packet is, which is the number every packet has to be queued with.
 *
 * A timestamp of zero is not a harmless placeholder: Android's Opus decoder reads a timestamp that
 * does not advance as a seek and discards its seek pre-roll again for every packet. Every Opus file
 * decoded to two thirds of its length, with no error anywhere.
 */
class OpusPacketDurationTest {

    private fun fixture(): ByteArray {
        var directory = File(System.getProperty("user.dir") ?: ".").absoluteFile
        repeat(8) {
            val candidate = File(directory, "eval/audio/formats/speech.opus")
            if (candidate.exists()) return candidate.readBytes()
            directory = directory.parentFile ?: return@repeat
        }
        throw AssertionError("fixture not found from ${System.getProperty("user.dir")}")
    }

    /**
     * The assertion that matters, and the one the old code could not have passed: the packets have
     * to add up to the length of the recording. The fixture is 1.5 seconds.
     */
    @Test
    fun `the packets add up to the length of the recording`() {
        val stream = OggOpusReader.demux(fixture())
        val samples = stream.packets.sumOf { OggOpusReader.packetSamples(it) } - stream.preSkip
        val seconds = samples / 48_000.0
        assertTrue("expected about 1.5 s of packets, got ${"%.3f".format(seconds)} s",
            seconds > 1.4 && seconds < 1.6)
    }

    /**
     * RFC 6716 §3.1, spot-checked at each mode boundary. These are the configurations a file from
     * another encoder arrives in, and the ones an assumption of 20 ms gets wrong.
     */
    @Test
    fun `the frame size comes from the configuration bits`() {
        // config << 3, with a frame count of 1.
        assertEquals("SILK NB 10 ms", 480, OggOpusReader.packetSamples(byteArrayOf((0 shl 3).toByte())))
        assertEquals("SILK NB 20 ms", 960, OggOpusReader.packetSamples(byteArrayOf((1 shl 3).toByte())))
        assertEquals("SILK NB 40 ms", 1_920, OggOpusReader.packetSamples(byteArrayOf((2 shl 3).toByte())))
        assertEquals("SILK NB 60 ms", 2_880, OggOpusReader.packetSamples(byteArrayOf((3 shl 3).toByte())))
        assertEquals("SILK WB 60 ms", 2_880, OggOpusReader.packetSamples(byteArrayOf((11 shl 3).toByte())))
        assertEquals("hybrid 10 ms", 480, OggOpusReader.packetSamples(byteArrayOf((12 shl 3).toByte())))
        assertEquals("hybrid 20 ms", 960, OggOpusReader.packetSamples(byteArrayOf((13 shl 3).toByte())))
        assertEquals("CELT 2.5 ms", 120, OggOpusReader.packetSamples(byteArrayOf((16 shl 3).toByte())))
        assertEquals("CELT FB 20 ms", 960, OggOpusReader.packetSamples(byteArrayOf((31 shl 3).toByte())))
    }

    @Test
    fun `the frame count multiplies it`() {
        val twentyMs = 1 shl 3
        assertEquals(960, OggOpusReader.packetSamples(byteArrayOf(twentyMs.toByte())))
        assertEquals(1_920, OggOpusReader.packetSamples(byteArrayOf((twentyMs or 1).toByte())))
        assertEquals(1_920, OggOpusReader.packetSamples(byteArrayOf((twentyMs or 2).toByte())))
        // An arbitrary count, in the low six bits of the second byte.
        assertEquals(3 * 960, OggOpusReader.packetSamples(byteArrayOf((twentyMs or 3).toByte(), 3)))
    }

    /** Nothing a corrupt file can say should run the clock forward by minutes. */
    @Test
    fun `a malformed packet cannot claim an unbounded duration`() {
        assertEquals(0, OggOpusReader.packetSamples(ByteArray(0)))
        val arbitrary = ((1 shl 3) or 3).toByte()
        assertTrue(OggOpusReader.packetSamples(byteArrayOf(arbitrary)) <= 960 * 48)
        assertTrue(OggOpusReader.packetSamples(byteArrayOf(arbitrary, 0)) <= 960 * 48)
        assertTrue(OggOpusReader.packetSamples(byteArrayOf(arbitrary, 63)) <= 2_880 * 48)
    }
}
