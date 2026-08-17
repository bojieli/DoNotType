package app.donottype.audio

import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaFormat
import app.donottype.core.Log
import app.donottype.core.OggOpusWriter
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Reads an Ogg Opus file, without relying on `MediaExtractor` to do it.
 *
 * `MediaCodec` has decoded `audio/opus` since API 21, but `MediaExtractor` only learned to open the
 * **Ogg** container for Opus in Android 10. This app's `minSdk` is 26, so on a device between those
 * two an `.opus` file — the format this project itself encodes to for upload — would fail to open at
 * all. Demuxing here rather than asking the platform makes the answer the same on every supported
 * device, which is worth more than the hundred lines it costs.
 *
 * The mirror of [OggOpusWriter], and the same two details are load-bearing. **Pre-skip**: the
 * encoder's priming samples must be discarded or every transcript starts with a click. **The 48 kHz
 * clock**: Opus always decodes at 48 kHz whatever went in, so the output is resampled down rather
 * than assumed to arrive at 16 kHz.
 *
 * Packets that span pages are joined before decoding. A 255-byte lacing value means "continues in
 * the next segment", and a reader that ignores that loses audio from the middle of a recording
 * rather than failing outright — the worse of the two failures.
 */
object OggOpusReader {
    private val log = Log("opus")

    /** Opus decodes at 48 kHz whatever was encoded. Not a choice; a property of the codec. */
    private const val DECODE_RATE = 48_000

    /** True when these bytes are an Ogg stream carrying Opus rather than Vorbis. */
    fun isOggOpus(bytes: ByteArray): Boolean {
        if (bytes.size < 36) return false
        if (bytes[0] != 'O'.code.toByte() || bytes[1] != 'g'.code.toByte() ||
            bytes[2] != 'g'.code.toByte() || bytes[3] != 'S'.code.toByte()
        ) {
            return false
        }
        // The identification header is the first packet of the first page, so it is a short way in.
        val limit = minOf(bytes.size - 8, 512)
        for (index in 0 until limit) {
            if (bytes.copyOfRange(index, index + 8).decodeToString() == "OpusHead") return true
        }
        return false
    }

    /** One Opus stream, demuxed out of its pages. */
    data class Stream(val packets: List<ByteArray>, val preSkip: Int, val channels: Int)

    /**
     * Walks the Ogg pages and reassembles Opus packets, dropping the two mandatory headers.
     *
     * Pure byte handling with no Android types in it, so the parsing half is covered by an ordinary
     * JVM unit test rather than needing a device.
     */
    fun demux(bytes: ByteArray): Stream {
        val packets = mutableListOf<ByteArray>()
        val partial = ByteArrayOutputStream()
        var preSkip = 0
        var channels = 1
        var sawHead = false
        var headersSeen = 0
        var sawEnd = false
        var serial: Int? = null
        var expectedSequence: Int? = null
        var offset = 0

        while (offset < bytes.size) {
            if (sawEnd) {
                throw AudioDecoder.DecodeException(
                    "This Ogg recording has data after its end marker and may be corrupt.",
                )
            }
            if (bytes.size - offset < PAGE_HEADER_BYTES) {
                throw AudioDecoder.DecodeException(
                    "This Ogg recording ends inside a page header and is truncated.",
                )
            }
            if (bytes[offset] != 'O'.code.toByte() || bytes[offset + 1] != 'g'.code.toByte() ||
                bytes[offset + 2] != 'g'.code.toByte() || bytes[offset + 3] != 'S'.code.toByte()
            ) {
                throw AudioDecoder.DecodeException(
                    "This is not a well-formed Ogg stream — no page header where one was expected. " +
                        "It may be truncated.",
                )
            }
            if (bytes[offset + 4].toInt() != 0) {
                throw AudioDecoder.DecodeException("This Ogg recording uses an unknown page version.")
            }

            val segmentCount = bytes[offset + 26].toInt() and 0xFF
            val lacingStart = offset + PAGE_HEADER_BYTES
            val bodyStart = lacingStart + segmentCount
            if (bodyStart > bytes.size) {
                throw AudioDecoder.DecodeException(
                    "This Ogg recording ends inside a page table and is truncated.",
                )
            }

            var bodyBytes = 0
            for (segment in 0 until segmentCount) {
                bodyBytes += bytes[lacingStart + segment].toInt() and 0xFF
            }
            val pageEnd = bodyStart + bodyBytes
            if (pageEnd > bytes.size) {
                throw AudioDecoder.DecodeException(
                    "This Ogg recording ends inside a page and is truncated.",
                )
            }

            val pageSerial = littleEndianInt(bytes, offset + 14)
            val sequence = littleEndianInt(bytes, offset + 18)
            if (serial == null) serial = pageSerial
            if (pageSerial != serial) {
                throw AudioDecoder.DecodeException(
                    "This Ogg file contains multiple interleaved streams; convert it to WAV first.",
                )
            }
            if (expectedSequence != null && sequence != expectedSequence) {
                throw AudioDecoder.DecodeException(
                    "This Ogg recording is missing or reorders a page and is incomplete.",
                )
            }
            expectedSequence = sequence + 1
            verifyChecksum(bytes, offset, pageEnd)

            val headerType = bytes[offset + 5].toInt() and 0xFF
            val continuesPacket = headerType and 0x01 != 0
            if (continuesPacket != (partial.size() > 0)) {
                throw AudioDecoder.DecodeException(
                    "This Ogg recording starts or loses part of a packet and is incomplete.",
                )
            }

            var cursor = bodyStart
            for (segment in 0 until segmentCount) {
                val length = bytes[lacingStart + segment].toInt() and 0xFF
                partial.write(bytes, cursor, length)
                cursor += length
                // Anything short of 255 ends the packet; exactly 255 means it continues.
                if (length == 255) continue

                val packet = partial.toByteArray()
                partial.reset()
                if (packet.isEmpty()) {
                    throw AudioDecoder.DecodeException(
                        "This Ogg recording contains an empty Opus packet and is corrupt.",
                    )
                }

                if (!sawHead && packet.size >= 19 &&
                    packet.copyOfRange(0, 8).decodeToString() == "OpusHead"
                ) {
                    channels = packet[9].toInt() and 0xFF
                    val mappingFamily = packet[18].toInt() and 0xFF
                    if (channels !in 1..2 || mappingFamily != 0) {
                        throw AudioDecoder.DecodeException(
                            "This Opus recording uses unsupported multichannel mapping. " +
                                "Convert it to mono or stereo WAV first.",
                        )
                    }
                    preSkip = (packet[10].toInt() and 0xFF) or ((packet[11].toInt() and 0xFF) shl 8)
                    sawHead = true
                    headersSeen++
                    continue
                }
                if (headersSeen == 1 && packet.size >= 8 &&
                    packet.copyOfRange(0, 8).decodeToString() == "OpusTags"
                ) {
                    headersSeen++
                    continue
                }
                if (headersSeen == 1) {
                    throw AudioDecoder.DecodeException(
                        "This Opus recording has no valid comment header and is incomplete.",
                    )
                }
                packets += packet
            }
            sawEnd = headerType and 0x04 != 0
            offset = pageEnd
        }

        if (!sawHead) {
            throw AudioDecoder.DecodeException(
                "This is an Ogg file, but the stream inside it is not Opus. Convert Vorbis to WAV " +
                "first.",
            )
        }
        if (!sawEnd || partial.size() > 0) {
            throw AudioDecoder.DecodeException(
                "This Ogg recording has no complete end marker and is truncated.",
            )
        }
        if (headersSeen < 2) {
            throw AudioDecoder.DecodeException(
                "This Opus recording is missing a required header and is incomplete.",
            )
        }
        return Stream(packets, preSkip, channels)
    }

    private const val PAGE_HEADER_BYTES = 27

    private fun littleEndianInt(bytes: ByteArray, offset: Int): Int =
        (bytes[offset].toInt() and 0xFF) or
            ((bytes[offset + 1].toInt() and 0xFF) shl 8) or
            ((bytes[offset + 2].toInt() and 0xFF) shl 16) or
            ((bytes[offset + 3].toInt() and 0xFF) shl 24)

    private fun verifyChecksum(bytes: ByteArray, pageStart: Int, pageEnd: Int) {
        val stored = littleEndianInt(bytes, pageStart + 22)
        val page = bytes.copyOfRange(pageStart, pageEnd)
        page.fill(0, 22, 26)
        if (OggOpusWriter.crc32(page) != stored) {
            throw AudioDecoder.DecodeException(
                "This Ogg recording failed its checksum and is corrupt or incomplete.",
            )
        }
    }

    /** Decodes to 16 kHz mono PCM, ready for [WavRecorder.wrapInWavContainer]. */
    fun decodeToPcm(bytes: ByteArray): ByteArray {
        val stream = demux(bytes)
        if (stream.packets.isEmpty()) {
            throw AudioDecoder.DecodeException("That recording decoded to no audio at all.")
        }

        val format = MediaFormat.createAudioFormat(
            MediaFormat.MIMETYPE_AUDIO_OPUS, DECODE_RATE, stream.channels,
        ).apply {
            // MediaCodec wants the identification header and the two timing values as codec
            // specific data. Omitting csd-1 and csd-2 is accepted by some decoders and rejected by
            // others, which is the kind of difference that only shows up on somebody else's phone.
            setByteBuffer("csd-0", ByteBuffer.wrap(identificationHeader(stream)))
            setByteBuffer("csd-1", ByteBuffer.wrap(nanoseconds(stream.preSkip)))
            setByteBuffer("csd-2", ByteBuffer.wrap(nanoseconds(SEEK_PREROLL_SAMPLES)))
        }

        var candidate: MediaCodec? = null
        val codec = try {
            val created = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_AUDIO_OPUS)
            candidate = created
            created.configure(format, null, null, 0)
            created.start()
            created
        } catch (error: Exception) {
            runCatching { candidate?.release() }
            throw AudioDecoder.DecodeException("This phone cannot decode Opus: ${error.message}")
        }

        val output = ByteArrayOutputStream()
        val info = MediaCodec.BufferInfo()
        var next = 0
        var presentedSamples = 0L
        var sawInputEnd = false
        var sawOutputEnd = false
        var skipRemaining = stream.preSkip
        var position = 0.0
        var outputRate = DECODE_RATE
        var outputChannels = stream.channels
        var lastProgress = System.nanoTime()

        try {
            while (!sawOutputEnd) {
                if (!sawInputEnd) {
                    val index = codec.dequeueInputBuffer(10_000)
                    if (index >= 0) {
                        if (next >= stream.packets.size) {
                            codec.queueInputBuffer(
                                index, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM,
                            )
                            sawInputEnd = true
                        } else {
                            val packet = stream.packets[next++]
                            val buffer = codec.getInputBuffer(index)
                                ?: throw AudioDecoder.DecodeException(
                                    "The Opus decoder exposed no input buffer.",
                                )
                            buffer.clear()
                            if (packet.size > buffer.remaining()) {
                                throw AudioDecoder.DecodeException(
                                    "An Opus packet is too large for this phone's decoder.",
                                )
                            }
                            buffer.put(packet)
                            // The timestamp is not decoration. See [packetSamples].
                            codec.queueInputBuffer(
                                index, 0, packet.size,
                                presentedSamples * 1_000_000L / DECODE_RATE, 0,
                            )
                            presentedSamples += packetSamples(packet)
                        }
                        lastProgress = System.nanoTime()
                    }
                }

                when (val index = codec.dequeueOutputBuffer(info, 10_000)) {
                    MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        val outputFormat = codec.outputFormat
                        outputRate = runCatching {
                            outputFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                        }.getOrDefault(DECODE_RATE)
                        outputChannels = runCatching {
                            outputFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                        }.getOrDefault(stream.channels)
                        val encoding = if (outputFormat.containsKey(MediaFormat.KEY_PCM_ENCODING)) {
                            outputFormat.getInteger(MediaFormat.KEY_PCM_ENCODING)
                        } else {
                            AudioFormat.ENCODING_PCM_16BIT
                        }
                        if (outputRate != DECODE_RATE || outputChannels != stream.channels ||
                            encoding != AudioFormat.ENCODING_PCM_16BIT
                        ) {
                            throw AudioDecoder.DecodeException(
                                "This phone's Opus decoder returned an unsupported audio format.",
                            )
                        }
                        lastProgress = System.nanoTime()
                    }
                    MediaCodec.INFO_TRY_AGAIN_LATER -> Unit
                    else -> if (index >= 0) {
                        if (info.size > 0) {
                            val buffer = AudioDecoder.checkedCodecOutputBuffer(
                                codec, index, info, "Opus decoder",
                            )
                            var mono = AudioDecoder.downmixForOpus(buffer, outputChannels)

                            // Priming samples the encoder added; audible as a click and a timing
                            // shift if they survive into the transcript.
                            if (skipRemaining > 0) {
                                val dropped = minOf(skipRemaining, mono.size)
                                mono = mono.copyOfRange(dropped, mono.size)
                                skipRemaining -= dropped
                            }
                            position = AudioDecoder.resampleForOpus(
                                mono, outputRate, position, output,
                            )
                        }
                        codec.releaseOutputBuffer(index, false)
                        if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                            sawOutputEnd = true
                        }
                        lastProgress = System.nanoTime()
                    }
                }

                if (!sawOutputEnd && AudioDecoder.codecHasStalled(lastProgress)) {
                    throw AudioDecoder.DecodeException(
                        "This phone's Opus decoder stopped responding. Convert the recording to " +
                            "WAV and try again.",
                    )
                }
            }
        } catch (error: AudioDecoder.DecodeException) {
            throw error
        } catch (error: Exception) {
            throw AudioDecoder.DecodeException(
                "Could not decode this Opus recording: " +
                    "${error.message ?: error.javaClass.simpleName}.",
            )
        } finally {
            runCatching { codec.stop() }
            runCatching { codec.release() }
        }

        val pcm = output.toByteArray()
        log.debug(
            mapOf(
                "packets" to stream.packets.size.toString(),
                "seconds" to (pcm.size / 2.0 / AudioDecoder.SAMPLE_RATE).toString(),
            ),
        ) { "decoded Ogg Opus" }
        return pcm
    }

    /** 80 ms, the value the Opus-in-WebM mapping specifies and every decoder expects. */
    private const val SEEK_PREROLL_SAMPLES = 3_840

    /**
     * The identification header MediaCodec wants as csd-0.
     *
     * Rebuilt rather than carried over from the file: a stream written by another encoder may
     * declare a different output gain or channel mapping, and what the decoder needs is a header
     * describing the stream it is about to be given.
     */
    private fun identificationHeader(stream: Stream): ByteArray {
        val header = ByteBuffer.allocate(19).order(ByteOrder.LITTLE_ENDIAN)
        header.put("OpusHead".toByteArray())
        header.put(1)                                  // version
        header.put(stream.channels.toByte())
        header.putShort(stream.preSkip.toShort())
        header.putInt(DECODE_RATE)                     // original sample rate, informational
        header.putShort(0)                             // output gain
        header.put(0)                                  // channel mapping family: mono or stereo
        return header.array()
    }

    /**
     * How many samples a packet decodes to, from the byte that says so.
     *
     * Needed because every packet has to be queued with a presentation timestamp, and a timestamp
     * of zero is not a harmless placeholder: Android's Opus decoder reads a timestamp that does not
     * advance as a seek, and discards its seek pre-roll again for every packet. Files decoded to
     * two thirds of their length — 1.02 seconds of a 1.5 second recording — with no error anywhere,
     * which is a third of somebody's meeting missing from a transcript that looks complete.
     *
     * Read from the packet rather than assumed to be 20 ms. That is what this project's own encoder
     * emits, so the assumption would have been right for every file it produced and wrong for
     * anything recorded elsewhere at 40 or 60 ms — the same shape of bug again, but only on files
     * from other people's tools, where it is hardest to see.
     *
     * The table is RFC 6716 §3.1: the top five bits of the first byte select the mode and frame
     * size, and the bottom two say how many frames the packet carries.
     */
    internal fun packetSamples(packet: ByteArray): Int {
        if (packet.isEmpty()) return 0
        val toc = packet[0].toInt() and 0xFF
        val config = toc shr 3

        val frameSamples = when {
            // SILK, 10/20/40/60 ms, at three bandwidths.
            config < 12 -> intArrayOf(480, 960, 1920, 2880)[config and 3]
            // Hybrid, 10 or 20 ms.
            config < 16 -> intArrayOf(480, 960)[config and 1]
            // CELT, 2.5/5/10/20 ms.
            else -> intArrayOf(120, 240, 480, 960)[config and 3]
        }

        val frames = when (toc and 3) {
            0 -> 1
            1, 2 -> 2
            // An arbitrary count, in the low six bits of the next byte.
            else -> if (packet.size >= 2) packet[1].toInt() and 0x3F else 1
        }
        // A malformed count would otherwise run the clock forward by minutes.
        return frameSamples * frames.coerceIn(1, 48)
    }

    /** csd-1 and csd-2 are 64-bit nanosecond counts, not sample counts. */
    private fun nanoseconds(samples: Int): ByteArray =
        ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN)
            .putLong(samples * 1_000_000_000L / DECODE_RATE)
            .array()
}
