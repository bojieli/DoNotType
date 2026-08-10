package app.donottype.core

import java.io.ByteArrayOutputStream

/**
 * Packages raw Opus packets into an Ogg stream.
 *
 * A port of `OggOpusWriter.swift`, deliberately close to it. `MediaCodec` produces Opus packets and
 * `MediaMuxer` can write Ogg, but going through the muxer means a temporary file and a second
 * read; writing the framing here means one implementation of the container across four platforms,
 * and it is the part most likely to be subtly wrong in a way that still looks like a valid file.
 *
 * Two mistakes from the Swift version are worth not repeating, because both produced files that
 * looked fine. Ending the stream with an empty page to carry the end-of-stream flag is a
 * zero-length Opus packet, which decoders read past and then reject. And one packet per page costs
 * 28 bytes of header per 20 ms frame -- 1.4 kB/s, nearly as much again as a 16 kbps stream.
 */
class OggOpusWriter(
    private val sampleRate: Int = 16_000,
    private val channels: Int = 1,
    /** Encoder delay to discard on playback, in 48 kHz samples. */
    private val preSkip: Int = 312,
    private val serial: Int = 0x646E7401,
) {
    companion object {
        /** Opus reports timestamps at 48 kHz whatever the capture rate. A granule position in the
         *  wrong clock makes the file play at the wrong speed, or be rejected outright. */
        const val OPUS_CLOCK_RATE = 48_000

        /** 50 × 20 ms per page. Larger pages save nothing measurable and delay nothing, since the
         *  whole file is written before any of it is sent. */
        private const val PACKETS_PER_PAGE = 50

        /**
         * Ogg's CRC-32: polynomial 0x04C11DB7, no reflection, zero seed -- *not* zip's CRC-32,
         * which produces a wrong-but-plausible value that decoders reject.
         */
        fun crc32(data: ByteArray): Int {
            var crc = 0
            for (byte in data) {
                crc = crc xor ((byte.toInt() and 0xFF) shl 24)
                repeat(8) {
                    crc = if (crc and 0x80000000.toInt() != 0) {
                        (crc shl 1) xor 0x04C11DB7
                    } else {
                        crc shl 1
                    }
                }
            }
            return crc
        }
    }

    private val output = ByteArrayOutputStream()
    private val pending = mutableListOf<ByteArray>()
    private var sequence = 0
    private var granule = 0L
    private var pendingGranule = 0L

    /** Writes the two mandatory headers. Must be called before any audio. */
    fun begin() {
        output.write(page(listOf(opusHead()), headerType = 0x02, granule = 0))
        output.write(page(listOf(opusTags()), headerType = 0x00, granule = 0))
    }

    /**
     * Appends one encoded Opus packet.
     *
     * @param frameCount decoded samples the packet represents at the source rate; converted to the
     *   48 kHz Opus clock internally, because that is what a granule position must be expressed in.
     */
    fun append(packet: ByteArray, frameCount: Int) {
        granule += frameCount.toLong() * OPUS_CLOCK_RATE / maxOf(sampleRate, 1)
        pending += packet
        pendingGranule = granule
        if (pending.size >= PACKETS_PER_PAGE) flushPending(endOfStream = false)
    }

    /** Finishes the stream and returns the complete file. */
    fun finish(): ByteArray {
        flushPending(endOfStream = true)
        return output.toByteArray()
    }

    private fun flushPending(endOfStream: Boolean) {
        if (pending.isEmpty()) return
        output.write(page(pending.toList(), if (endOfStream) 0x04 else 0x00, pendingGranule))
        pending.clear()
    }

    private fun opusHead(): ByteArray {
        val out = ByteArrayOutputStream()
        out.write("OpusHead".toByteArray())
        out.write(1) // version
        out.write(channels)
        out.write(int16(preSkip))
        out.write(int32(sampleRate)) // informational only
        out.write(int16(0)) // output gain
        out.write(0) // channel mapping family
        return out.toByteArray()
    }

    private fun opusTags(): ByteArray {
        val vendor = "DoNotType".toByteArray()
        val out = ByteArrayOutputStream()
        out.write("OpusTags".toByteArray())
        out.write(int32(vendor.size))
        out.write(vendor)
        out.write(int32(0)) // no user comments
        return out.toByteArray()
    }

    /**
     * Builds one Ogg page.
     *
     * Packets larger than 255×255 bytes would have to span pages. A 20 ms Opus frame at any sane
     * bitrate is a few hundred bytes, so the case cannot arise and is not handled -- silently
     * truncating would be worse than not supporting it.
     */
    private fun page(payloads: List<ByteArray>, headerType: Int, granule: Long): ByteArray {
        val segments = ByteArrayOutputStream()
        val body = ByteArrayOutputStream()

        for (payload in payloads) {
            var remaining = payload.size
            while (remaining >= 255) {
                segments.write(255)
                remaining -= 255
            }
            segments.write(remaining)
            body.write(payload)
        }

        val segmentTable = segments.toByteArray()
        val page = ByteArrayOutputStream()
        page.write("OggS".toByteArray())
        page.write(0) // stream structure version
        page.write(headerType)
        page.write(int64(granule))
        page.write(int32(serial))
        page.write(int32(sequence))
        page.write(int32(0)) // CRC placeholder
        page.write(segmentTable.size)
        page.write(segmentTable)
        page.write(body.toByteArray())

        sequence++

        // The checksum covers the whole page with its own field zeroed, then replaces it -- which
        // is why it cannot be filled in above.
        val bytes = page.toByteArray()
        val checksum = crc32(bytes)
        bytes[22] = (checksum and 0xFF).toByte()
        bytes[23] = ((checksum shr 8) and 0xFF).toByte()
        bytes[24] = ((checksum shr 16) and 0xFF).toByte()
        bytes[25] = ((checksum shr 24) and 0xFF).toByte()
        return bytes
    }

    private fun int16(value: Int) = byteArrayOf(
        (value and 0xFF).toByte(),
        ((value shr 8) and 0xFF).toByte(),
    )

    private fun int32(value: Int) = byteArrayOf(
        (value and 0xFF).toByte(),
        ((value shr 8) and 0xFF).toByte(),
        ((value shr 16) and 0xFF).toByte(),
        ((value shr 24) and 0xFF).toByte(),
    )

    private fun int64(value: Long) = ByteArray(8) { ((value shr (it * 8)) and 0xFF).toByte() }
}
