package app.donottype.audio

import android.media.MediaCodec
import android.media.MediaFormat
import android.util.Log
import app.donottype.core.AudioChunker
import app.donottype.core.OggOpusWriter
import java.nio.ByteBuffer

/**
 * Encodes captured PCM to Opus for upload.
 *
 * The reason is upload size, measured on the desktop port against the same speech: 30 seconds is
 * 960 kB as 16 kHz PCM and about 60 kB as Opus at 16 kbps, and end-to-end latency fell roughly 25%.
 * On a phone the saving matters more than on a laptop, because the connection is usually worse.
 *
 * `MediaCodec` has an Opus encoder from API 29. It emits raw Opus packets, and `MediaMuxer` will
 * only put them in an Ogg container from API 29 as well -- but going through the muxer means a
 * temporary file and a second read, so the packets are handed to [OggOpusWriter] instead, which is
 * the same container writer the Apple ports use. One implementation of the framing, four platforms.
 */
object OpusEncoder {
    private const val TAG = "OpusEncoder"
    private const val SAMPLE_RATE = 16_000
    private const val BIT_RATE = 16_000
    private const val FRAME_MILLIS = 20
    private const val FRAME_SAMPLES = SAMPLE_RATE / 1000 * FRAME_MILLIS
    private const val FRAME_BYTES = FRAME_SAMPLES * 2
    private const val TIMEOUT_US = 10_000L

    /** Opus encoding needs API 29; below that the recording is uploaded as WAV. */
    val isAvailable: Boolean
        get() = android.os.Build.VERSION.SDK_INT >= 29

    /**
     * Converts a 16 kHz mono WAV to Ogg Opus, or returns null to fall back to the original.
     *
     * Null rather than throwing, and every failure path returns it: a compression optimisation
     * must never be able to cost someone their words. A larger upload is a slower dictation; a
     * failed one is a lost one.
     */
    fun encode(wav: ByteArray): ByteArray? {
        if (!isAvailable) return null
        val pcm = AudioChunker.pcmBody(wav) ?: return null

        var codec: MediaCodec? = null
        return try {
            val format = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_OPUS, SAMPLE_RATE, 1).apply {
                setInteger(MediaFormat.KEY_BIT_RATE, BIT_RATE)
                setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, FRAME_BYTES * 4)
            }
            val created = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_OPUS)
            codec = created
            created.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            created.start()

            val writer = OggOpusWriter(sampleRate = SAMPLE_RATE, channels = 1)
            writer.begin()

            var offset = 0
            var inputDone = false
            val info = MediaCodec.BufferInfo()
            var packetsWritten = 0
            var lastProgress = System.nanoTime()

            while (true) {
                if (!inputDone) {
                    val index = codec.dequeueInputBuffer(TIMEOUT_US)
                    if (index >= 0) {
                        val buffer = codec.getInputBuffer(index)
                            ?: throw IllegalStateException("Opus encoder exposed no input buffer")
                        buffer.clear()

                        val remaining = pcm.size - offset
                        if (remaining <= 0) {
                            val presentationUs =
                                (pcm.size.toLong() / 2) * 1_000_000L / SAMPLE_RATE
                            codec.queueInputBuffer(
                                index, 0, 0, presentationUs,
                                MediaCodec.BUFFER_FLAG_END_OF_STREAM,
                            )
                            inputDone = true
                        } else {
                            // The final partial frame is zero-padded rather than dropped. Opus only
                            // encodes whole frames, and truncating clips the last syllable --
                            // which is where people put the word they care about.
                            val take = minOf(FRAME_BYTES, remaining)
                            if (buffer.remaining() < FRAME_BYTES) {
                                throw IllegalStateException(
                                    "Opus encoder input buffer is smaller than one frame",
                                )
                            }
                            val presentationUs =
                                (offset.toLong() / 2) * 1_000_000L / SAMPLE_RATE
                            buffer.put(pcm, offset, take)
                            if (take < FRAME_BYTES) {
                                buffer.put(ByteArray(FRAME_BYTES - take))
                            }
                            offset += take

                            codec.queueInputBuffer(index, 0, FRAME_BYTES, presentationUs, 0)
                        }
                        lastProgress = System.nanoTime()
                    }
                }

                val outIndex = codec.dequeueOutputBuffer(info, TIMEOUT_US)
                if (outIndex >= 0) {
                    val isConfig = info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0
                    if (info.size > 0 && !isConfig) {
                        val buffer: ByteBuffer = AudioDecoder.checkedCodecOutputBuffer(
                            codec, outIndex, info, "Opus encoder",
                        )
                        val packet = ByteArray(info.size)
                        buffer.get(packet)
                        val isContainerHeader = packet.size >= 8 &&
                            (packet.copyOfRange(0, 8).decodeToString() == "OpusHead" ||
                                packet.copyOfRange(0, 8).decodeToString() == "OpusTags")
                        if (!isContainerHeader) {
                            writer.append(packet, FRAME_SAMPLES)
                            packetsWritten++
                        }
                    }
                    codec.releaseOutputBuffer(outIndex, false)
                    lastProgress = System.nanoTime()

                    if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) break
                } else if (outIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    lastProgress = System.nanoTime()
                } else if (AudioDecoder.codecHasStalled(lastProgress)) {
                    throw IllegalStateException("Opus encoder stopped responding")
                }
            }

            if (packetsWritten == 0) return null
            val ogg = writer.finish()
            if (ogg.size >= wav.size) null else ogg
        } catch (error: Exception) {
            Log.w(TAG, "Opus encoding failed, uploading WAV", error)
            null
        } finally {
            runCatching { codec?.stop() }
            runCatching { codec?.release() }
        }
    }
}
