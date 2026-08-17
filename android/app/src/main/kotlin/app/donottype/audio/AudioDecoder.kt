package app.donottype.audio

import android.content.Context
import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.net.Uri
import app.donottype.core.Log
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.roundToInt

/**
 * Turns a recording of any format into the 16 kHz mono WAV the rest of the pipeline assumes.
 *
 * Live dictation never needed this: [WavRecorder] captures at 16 kHz mono and hands over PCM
 * already in the right shape. Transcribing a *file* is different — what people have on a phone is a
 * voice memo, a call recording or something shared into the app, and every one of those breaks
 * something downstream:
 *
 * - `AudioChunker` reads a 16 kHz mono PCM body, so a compressed file is one unsplittable chunk
 *   however long it is. A forty-minute recording would go out as a single request.
 * - `WavRecorder.durationSeconds` reads a WAV header, so the history row records a zero-length
 *   dictation.
 * - `OpusEncoder` takes 16 kHz mono PCM in, so the upload would not be compressed either.
 *
 * `MediaExtractor` plus `MediaCodec` is the same pair [OpusEncoder] already uses in the other
 * direction, so this adds no dependency — everything Android can play, this can decode.
 */
object AudioDecoder {
    /** What the models are given regardless of what was recorded. They downsample to this anyway. */
    const val SAMPLE_RATE = 16_000

    /** What to tell someone whose file did not open, in one place so nothing describes a subset. */
    const val SUPPORTED_FORMATS = "WAV, MP3, M4A/AAC, Opus, AMR, FLAC and Ogg Vorbis"

    private val log = Log("audio")
    private const val CODEC_DEQUEUE_TIMEOUT_US = 10_000L
    private const val CODEC_STALL_NANOS = 15_000_000_000L

    class DecodeException(message: String) : IOException(message)

    /**
     * Reads a document the user picked and returns 16 kHz mono WAV bytes.
     *
     * @param uri a content:// URI from the storage access framework.
     */
    fun decodeToWav(context: Context, uri: Uri): ByteArray {
        val started = System.currentTimeMillis()

        // Ogg Opus goes through our own reader on every API level rather than through
        // MediaExtractor, which only learned that container in Android 10 — this app supports 26,
        // and .opus is the format the project itself encodes to. Sniffed from the bytes rather than
        // the name, because a file picked from a content provider may have neither an extension nor
        // an honest MIME type.
        val head = readHead(context, uri)

        // Said plainly. An empty file is what a share that failed halfway looks like, and what
        // comes back otherwise is MediaExtractor's "setDataSource failed", which reads as a bug in
        // the app rather than a description of the file.
        if (head == null || head.isEmpty()) {
            throw DecodeException(
                "That file is empty, or could not be opened. If it was just shared or downloaded, " +
                    "it may not have finished copying.",
            )
        }

        if (OggOpusReader.isOggOpus(head)) {
            val whole = context.contentResolver.openInputStream(uri)?.use { it.readBytes() }
                ?: throw DecodeException("That file could not be opened.")
            val pcm = OggOpusReader.decodeToPcm(whole)
            val wav = WavRecorder.wrapInWavContainer(pcm)
            log.info(
                mapOf(
                    "bytes" to wav.size.toString(),
                    "via" to "opus",
                    "ms" to (System.currentTimeMillis() - started).toString(),
                ),
            ) { "decoded recording" }
            return wav
        }

        val extractor = MediaExtractor()
        try {
            context.contentResolver.openFileDescriptor(uri, "r").use { descriptor ->
                if (descriptor == null) throw DecodeException("That file could not be opened.")
                extractor.setDataSource(descriptor.fileDescriptor)
            }
        } catch (error: Exception) {
            throw DecodeException(
                "Could not read that recording: ${error.message ?: "unsupported file"}. " +
                    "Supported: $SUPPORTED_FORMATS.",
            )
        }

        try {
            val track = (0 until extractor.trackCount).firstOrNull { index ->
                extractor.getTrackFormat(index).getString(MediaFormat.KEY_MIME)
                    ?.startsWith("audio/") == true
            } ?: throw DecodeException("That file has no audio track in it.")

            extractor.selectTrack(track)
            val format = extractor.getTrackFormat(track)
            val pcm = decodeTrack(extractor, format)
            if (pcm.isEmpty()) throw DecodeException("That recording decoded to no audio at all.")

            val wav = WavRecorder.wrapInWavContainer(pcm)
            log.info(
                mapOf(
                    "bytes" to wav.size.toString(),
                    "seconds" to (pcm.size / 2.0 / SAMPLE_RATE).roundToInt().toString(),
                    "ms" to (System.currentTimeMillis() - started).toString(),
                ),
            ) { "decoded recording" }
            return wav
        } finally {
            extractor.release()
        }
    }

    /**
     * Runs the track through a decoder, downmixing to mono and resampling to 16 kHz as blocks
     * arrive.
     *
     * Block by block rather than whole-file: an hour of 44.1 kHz stereo is hundreds of megabytes as
     * PCM, and the whole point of file transcription is that the files are long.
     */
    private fun decodeTrack(extractor: MediaExtractor, format: MediaFormat): ByteArray {
        val mime = format.getString(MediaFormat.KEY_MIME)
            ?: throw DecodeException("That file has no audio track in it.")
        val sourceRate = requiredPositiveFormatValue(format, MediaFormat.KEY_SAMPLE_RATE, "sample rate")
        val channels = requiredChannelCount(format)
        // Audio buffers below are deliberately interpreted as signed little-endian 16-bit PCM.
        // Ask for that explicitly rather than relying on a decoder-specific default.
        format.setInteger(MediaFormat.KEY_PCM_ENCODING, AudioFormat.ENCODING_PCM_16BIT)

        var candidate: MediaCodec? = null
        val codec = try {
            val created = MediaCodec.createDecoderByType(mime)
            candidate = created
            created.configure(format, null, null, 0)
            created.start()
            created
        } catch (error: Exception) {
            runCatching { candidate?.release() }
            throw DecodeException("This phone cannot decode $mime: ${error.message}")
        }

        val output = ByteArrayOutputStream()
        val info = MediaCodec.BufferInfo()
        var sawInputEnd = false
        var sawOutputEnd = false
        var outputRate = sourceRate
        var outputChannels = channels
        var lastProgress = System.nanoTime()
        // Carried across blocks so resampling does not restart its phase at every boundary, which
        // would put a click at each one.
        var position = 0.0

        try {
            while (!sawOutputEnd) {
                if (!sawInputEnd) {
                    val index = codec.dequeueInputBuffer(CODEC_DEQUEUE_TIMEOUT_US)
                    if (index >= 0) {
                        val buffer = codec.getInputBuffer(index)
                            ?: throw DecodeException("The $mime decoder exposed no input buffer.")
                        buffer.clear()
                        val size = extractor.readSampleData(buffer, 0)
                        if (size < 0) {
                            codec.queueInputBuffer(
                                index, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM,
                            )
                            sawInputEnd = true
                        } else {
                            codec.queueInputBuffer(
                                index, 0, size, extractor.sampleTime.coerceAtLeast(0L), 0,
                            )
                            extractor.advance()
                        }
                        lastProgress = System.nanoTime()
                    }
                }

                when (val index = codec.dequeueOutputBuffer(info, CODEC_DEQUEUE_TIMEOUT_US)) {
                    MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                        val outputFormat = codec.outputFormat
                        outputRate = requiredPositiveFormatValue(
                            outputFormat, MediaFormat.KEY_SAMPLE_RATE, "decoded sample rate",
                        )
                        outputChannels = requiredChannelCount(outputFormat)
                        val encoding = if (outputFormat.containsKey(MediaFormat.KEY_PCM_ENCODING)) {
                            outputFormat.getInteger(MediaFormat.KEY_PCM_ENCODING)
                        } else {
                            AudioFormat.ENCODING_PCM_16BIT
                        }
                        if (encoding != AudioFormat.ENCODING_PCM_16BIT) {
                            throw DecodeException(
                                "This phone decoded $mime to an unsupported PCM format.",
                            )
                        }
                        lastProgress = System.nanoTime()
                    }
                    MediaCodec.INFO_TRY_AGAIN_LATER -> Unit
                    else -> if (index >= 0) {
                        if (info.size > 0) {
                            val buffer = checkedCodecOutputBuffer(codec, index, info, "$mime decoder")
                            val mono = downmix(buffer, outputChannels)
                            position = resampleInto(mono, outputRate, position, output)
                        }
                        codec.releaseOutputBuffer(index, false)
                        if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                            sawOutputEnd = true
                        }
                        lastProgress = System.nanoTime()
                    }
                }

                if (!sawOutputEnd && System.nanoTime() - lastProgress > CODEC_STALL_NANOS) {
                    throw DecodeException(
                        "This phone's $mime decoder stopped responding. Try converting the " +
                            "recording to WAV.",
                    )
                }
            }
        } catch (error: DecodeException) {
            throw error
        } catch (error: Exception) {
            throw DecodeException(
                "Could not decode this $mime recording: ${error.message ?: error.javaClass.simpleName}.",
            )
        } finally {
            runCatching { codec.stop() }
            runCatching { codec.release() }
        }
        return output.toByteArray()
    }

    /** Enough of the file to recognise a container by, without reading a forty-minute one twice. */
    private fun readHead(context: Context, uri: Uri): ByteArray? = runCatching {
        context.contentResolver.openInputStream(uri)?.use { stream ->
            val head = ByteArray(1_024)
            val read = stream.read(head)
            if (read <= 0) null else head.copyOf(read)
        }
    }.getOrNull()

    /** Shared with [OggOpusReader], which decodes through MediaCodec directly. */
    internal fun downmixForOpus(buffer: ByteBuffer, channels: Int): ShortArray =
        downmix(buffer, channels)

    /** Shared with [OggOpusReader]; see [resampleInto] for why linear is enough here. */
    internal fun resampleForOpus(
        samples: ShortArray,
        sourceRate: Int,
        startPosition: Double,
        into: ByteArrayOutputStream,
    ): Double = resampleInto(samples, sourceRate, startPosition, into)

    internal fun codecHasStalled(lastProgressNanos: Long): Boolean =
        System.nanoTime() - lastProgressNanos > CODEC_STALL_NANOS

    internal fun checkedCodecOutputBuffer(
        codec: MediaCodec,
        index: Int,
        info: MediaCodec.BufferInfo,
        description: String,
    ): ByteBuffer {
        val buffer = codec.getOutputBuffer(index)
            ?: throw DecodeException("The $description exposed no output buffer.")
        if (info.offset < 0 || info.size < 0 || info.offset > buffer.capacity() - info.size) {
            throw DecodeException("The $description returned an invalid audio buffer.")
        }
        buffer.position(info.offset)
        buffer.limit(info.offset + info.size)
        return buffer
    }

    private fun requiredPositiveFormatValue(
        format: MediaFormat,
        key: String,
        description: String,
    ): Int {
        val value = runCatching { format.getInteger(key) }.getOrNull()
            ?: throw DecodeException("That recording has no $description.")
        if (value <= 0) throw DecodeException("That recording has an invalid $description.")
        return value
    }

    private fun requiredChannelCount(format: MediaFormat): Int {
        val channels = requiredPositiveFormatValue(
            format, MediaFormat.KEY_CHANNEL_COUNT, "channel count",
        )
        if (channels > 32) throw DecodeException("That recording has too many audio channels.")
        return channels
    }

    /** Averages the channels. A phone recording in stereo is two copies of the same voice. */
    private fun downmix(buffer: ByteBuffer, channels: Int): ShortArray {
        val frameBytes = channels * Short.SIZE_BYTES
        if (channels <= 0 || buffer.remaining() % frameBytes != 0) {
            throw DecodeException("The audio decoder returned an incomplete PCM frame.")
        }
        val shorts = buffer.order(ByteOrder.LITTLE_ENDIAN).asShortBuffer()
        val frames = shorts.remaining() / channels
        val mono = ShortArray(frames)
        for (frame in 0 until frames) {
            var total = 0
            for (channel in 0 until channels) total += shorts.get(frame * channels + channel).toInt()
            mono[frame] = (total / channels).toShort()
        }
        return mono
    }

    /**
     * Linear resampling to 16 kHz.
     *
     * Good enough on purpose: the destination is a speech model that downsamples to this rate
     * anyway, and a polyphase filter would add code to defend a difference nothing downstream can
     * hear.
     *
     * @return the fractional read position to resume from in the next block.
     */
    private fun resampleInto(
        samples: ShortArray,
        sourceRate: Int,
        startPosition: Double,
        into: ByteArrayOutputStream,
    ): Double {
        if (samples.isEmpty()) return startPosition
        val step = sourceRate.toDouble() / SAMPLE_RATE
        var position = startPosition

        while (position < samples.size - 1) {
            val index = position.toInt()
            val fraction = position - index
            val value = samples[index] * (1 - fraction) + samples[index + 1] * fraction
            val sample = value.roundToInt().coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt())
            into.write(sample and 0xFF)
            into.write((sample shr 8) and 0xFF)
            position += step
        }
        // What is left over becomes the starting phase for the next block, where index 0 is this
        // block's index `samples.size`.
        //
        // Clamped at zero, and that is not defensive tidying. The loop stops one sample early —
        // interpolating the last sample needs the next one, which is in a buffer that has not
        // arrived — so `position` can end exactly at `samples.size - 1` and the carry exactly at
        // -1.0. The next call then reads `samples[-1]` and throws. It needs the block length and
        // the step to line up, which they do at whole-number ratios: 48 kHz to 16 kHz is a step of
        // exactly 3, and any block whose length is 1 more than a multiple of 3 lands on it.
        //
        // The cost of clamping is that one output sample is placed up to 1/16000 of a second late.
        return (position - samples.size).coerceAtLeast(0.0)
    }
}
