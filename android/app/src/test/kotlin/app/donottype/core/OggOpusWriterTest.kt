package app.donottype.core

import java.io.File
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test

/**
 * Checks this port of the Ogg container against the Swift reference, byte for byte.
 *
 * The container is the part most likely to be subtly wrong in a way that still produces a file
 * decoders mostly accept — the Swift version shipped two such bugs before this pair of suites
 * existed, one of which only surfaced as a message at the very end of ffprobe's output. "It decodes
 * on my machine" is not the same as "it is the same stream".
 *
 * Regenerate the reference with `swift run dnt-eval ogg-golden eval/conformance/ogg-reference.bin`.
 */
class OggOpusWriterTest {
    private fun referenceFile(): File? {
        var dir: File? = File(System.getProperty("user.dir") ?: ".").absoluteFile
        repeat(8) {
            val candidate = File(dir, "eval/conformance/ogg-reference.bin")
            if (candidate.isFile) return candidate
            dir = dir?.parentFile
        }
        return null
    }

    /** The same input the Swift `ogg-golden` command uses. */
    private fun writeReferenceStream(): ByteArray {
        val writer = OggOpusWriter()
        writer.begin()
        for (index in 0 until 120) {
            val packet = ByteArray(40) { (it + index).toByte() }
            writer.append(packet, 320)
        }
        return writer.finish()
    }

    @Test
    fun `output is byte identical to the swift reference`() {
        val reference = referenceFile()
        assumeTrue("eval/conformance/ogg-reference.bin not reachable", reference != null)

        assertArrayEquals(
            "The ports disagree on the container. Regenerate with " +
                "`swift run dnt-eval ogg-golden eval/conformance/ogg-reference.bin` only if the " +
                "change was intended, then re-run both suites.",
            reference!!.readBytes(),
            writeReferenceStream(),
        )
    }

    /**
     * Ogg uses polynomial 0x04C11DB7 with no reflection and a zero seed. 0x89A1897F is the
     * published check value for CRC-32/MPEG-2, which is that variant: an implementation that
     * reflects its input or seeds with 0xFFFFFFFF produces a plausible-looking checksum and fails
     * here rather than in the field.
     */
    @Test
    fun `crc matches the published check value`() {
        assertEquals(0, OggOpusWriter.crc32(ByteArray(0)))
        assertEquals(0, OggOpusWriter.crc32(byteArrayOf(0)))
        assertEquals(0x89A1897F.toInt(), OggOpusWriter.crc32("123456789".toByteArray()))
        assertEquals(0x5FB0A94F, OggOpusWriter.crc32("OggS".toByteArray()))
    }

    private fun pageOffsets(data: ByteArray): List<Int> {
        val offsets = mutableListOf<Int>()
        for (index in 0..data.size - 4) {
            if (data[index] == 'O'.code.toByte() && data[index + 1] == 'g'.code.toByte() &&
                data[index + 2] == 'g'.code.toByte() && data[index + 3] == 'S'.code.toByte()
            ) {
                offsets += index
            }
        }
        return offsets
    }

    @Test
    fun `stream opens with both headers and ends with the eos flag`() {
        val data = writeReferenceStream()
        val offsets = pageOffsets(data)

        assertEquals("first page must set BOS", 0x02, data[offsets[0] + 5].toInt())
        assertEquals(0x04, data[offsets.last() + 5].toInt() and 0x04)
        assertTrue(
            "the EOS page must carry a real packet, not a zero-length one",
            data[offsets.last() + 27].toInt() != 0,
        )
    }

    /** One packet per page costs 28 bytes of header per 20 ms frame — 1.4 kB/s, nearly as much
     *  again as a 16 kbps stream. */
    @Test
    fun `packets share pages`() {
        assertTrue(pageOffsets(writeReferenceStream()).size < 10)
    }

    @Test
    fun `every page checksum verifies`() {
        val data = writeReferenceStream()
        val offsets = pageOffsets(data)

        for ((index, offset) in offsets.withIndex()) {
            val end = if (index + 1 < offsets.size) offsets[index + 1] else data.size
            val page = data.copyOfRange(offset, end)

            val stored = (page[22].toInt() and 0xFF) or
                ((page[23].toInt() and 0xFF) shl 8) or
                ((page[24].toInt() and 0xFF) shl 16) or
                ((page[25].toInt() and 0xFF) shl 24)
            for (byte in 22..25) page[byte] = 0

            assertEquals("page $index would be rejected as corrupt", stored, OggOpusWriter.crc32(page))
        }
    }

    /** 320 frames at 16 kHz is 20 ms, which is 960 samples on Opus's fixed 48 kHz clock. */
    @Test
    fun `granule uses the opus clock not the source clock`() {
        val writer = OggOpusWriter()
        writer.begin()
        writer.append(ByteArray(40), 320)
        val data = writer.finish()

        val last = pageOffsets(data).last()
        var granule = 0L
        for (i in 7 downTo 0) granule = (granule shl 8) or (data[last + 6 + i].toLong() and 0xFF)
        assertEquals(960L, granule)
    }
}
