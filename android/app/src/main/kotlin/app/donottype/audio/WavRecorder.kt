package app.donottype.audio

import android.annotation.SuppressLint
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import app.donottype.core.AudioLevelMeter
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.concurrent.thread

/**
 * Microphone capture at 16 kHz mono, written straight to a WAV buffer.
 *
 * 16 kHz because the model downsamples to it regardless; anything richer is upload we pay for and
 * discard. WAV rather than a compressed container because the encode has to keep up with capture
 * on low-end hardware, and a 33-second dictation is about a megabyte — far inside the 20 MB inline
 * request ceiling.
 *
 * Unlike iOS, this runs inside the keyboard process: an `InputMethodService` may hold RECORD_AUDIO,
 * so there is no cross-process hop between hearing the speech and inserting the text.
 */
class WavRecorder {
    companion object {
        const val SAMPLE_RATE = 16_000
        /** Below this it was a stray tap rather than speech. */
        const val MIN_DURATION_MS = 500L

        /** 50 ms of 16-bit mono: 800 samples, 1600 bytes. */
        private const val READ_BYTES = SAMPLE_RATE / 10

        /** About seven seconds of bars. */
        private const val MAXIMUM_PENDING_BARS = 120

        /**
         * Length of a recording this class produced, from its own 44-byte header.
         *
         * Only valid for WAVs written here -- everything this app records is 16 kHz mono 16-bit,
         * and so is everything `AudioDecoder` produces, so there is nothing to parse. A general WAV
         * reader would have to scan for the `data` chunk; nothing on this platform hands us one.
         */
        fun durationSeconds(wav: ByteArray): Double {
            val bytesPerSecond = SAMPLE_RATE * 2
            val samples = (wav.size - 44).coerceAtLeast(0)
            return samples.toDouble() / bytesPerSecond
        }

        /**
         * 44-byte canonical RIFF header, PCM 16-bit mono.
         *
         * On the companion rather than the instance because `AudioDecoder` produces the same
         * format from a file and has to wrap it the same way — two spellings of this header would
         * be two chances for one of them to drift from what the chunker expects.
         */
        fun wrapInWavContainer(pcmData: ByteArray): ByteArray {
            val byteRate = SAMPLE_RATE * 2
            val header = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN)
            header.put("RIFF".toByteArray())
            header.putInt(36 + pcmData.size)
            header.put("WAVE".toByteArray())
            header.put("fmt ".toByteArray())
            header.putInt(16)             // PCM chunk size
            header.putShort(1)            // format: PCM
            header.putShort(1)            // channels: mono
            header.putInt(SAMPLE_RATE)
            header.putInt(byteRate)
            header.putShort(2)            // block align
            header.putShort(16)           // bits per sample
            header.put("data".toByteArray())
            header.putInt(pcmData.size)
            return header.array() + pcmData
        }
    }

    private var record: AudioRecord? = null
    private var worker: Thread? = null
    private val pcm = ByteArrayOutputStream()

    @Volatile private var capturing = false

    /** Exact PCM appended to the recovery WAV, copied because the capture buffer is reused. */
    @Volatile var onPcm: ((ByteArray) -> Unit)? = null

    private var meter = AudioLevelMeter(SAMPLE_RATE)
    private val pendingBars = ArrayList<AudioLevelMeter.Bar>()

    /**
     * Hands the indicator the bars captured since it last asked, oldest first.
     *
     * Drained rather than sampled. The meter used to read a running peak that the reader cleared,
     * which made every draw a single number covering however long it had been since the last one —
     * so the bars moved at the polling rate rather than at the rate the voice did. Levels are
     * measured where the audio is, in 20 ms frames on the capture thread, and whoever draws them
     * collects whatever has arrived.
     */
    fun drainLevels(): List<AudioLevelMeter.Bar> = synchronized(pendingBars) {
        if (pendingBars.isEmpty()) return emptyList()
        val bars = ArrayList(pendingBars)
        pendingBars.clear()
        bars
    }

    private var startedAt = 0L

    val isRecording: Boolean get() = capturing

    @SuppressLint("MissingPermission")
    fun start() {
        if (capturing) return
        pcm.reset()
        meter = AudioLevelMeter(SAMPLE_RATE)
        synchronized(pendingBars) { pendingBars.clear() }

        val minBuffer = AudioRecord.getMinBufferSize(
            SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT,
        )
        val bufferSize = maxOf(minBuffer, SAMPLE_RATE / 2)

        val recorder = AudioRecord(
            // VOICE_RECOGNITION applies the platform's speech-tuned AGC and noise suppression,
            // which is what this audio is for.
            MediaRecorder.AudioSource.VOICE_RECOGNITION,
            SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
            bufferSize,
        )
        check(recorder.state == AudioRecord.STATE_INITIALIZED) { "AudioRecord failed to initialise" }

        record = recorder
        capturing = true
        startedAt = System.currentTimeMillis()
        recorder.startRecording()

        worker = thread(name = "dnt-capture") {
            // Read in 50 ms pieces rather than in whole buffers. AudioRecord's own buffer stays as
            // large as it was — that is the margin against an overrun and nothing to do with us —
            // but a read that returns a quarter of a second of audio is a quarter of a second in
            // which the meter learns nothing, and then learns four bars at once.
            val buffer = ByteArray(READ_BYTES)
            while (capturing) {
                val read = recorder.read(buffer, 0, buffer.size)
                if (read > 0) {
                    pcm.write(buffer, 0, read)
                    onPcm?.invoke(buffer.copyOf(read))
                    val bars = meter.append(buffer, read)
                    if (bars.isNotEmpty()) {
                        synchronized(pendingBars) {
                            pendingBars += bars
                            // A UI that has stopped collecting is a UI that is not drawing them
                            // either; keeping more than a few seconds of undrawn bars would only
                            // be a leak with a nice name.
                            if (pendingBars.size > MAXIMUM_PENDING_BARS) {
                                pendingBars.subList(
                                    0, pendingBars.size - MAXIMUM_PENDING_BARS,
                                ).clear()
                            }
                        }
                    }
                }
            }
        }
    }

    /** Stops capture and returns a complete WAV file, or null if it was too short to be speech. */
    fun stop(): ByteArray? {
        if (!capturing) return null
        val elapsed = System.currentTimeMillis() - startedAt
        teardown()
        if (elapsed < MIN_DURATION_MS) return null
        val samples = pcm.toByteArray()
        return if (samples.isEmpty()) null else wrapInWavContainer(samples)
    }

    fun cancel() {
        teardown()
        pcm.reset()
    }

    private fun teardown() {
        capturing = false
        val activeRecord = record
        val activeWorker = worker
        record = null
        worker = null

        // AudioRecord.read() is blocking. Stop the device first so the capture thread can observe
        // `capturing = false`; waiting first left a narrow path where stop() returned while that
        // thread was still writing into the WAV buffer being read or reset by the caller.
        activeRecord?.let { recorder ->
            if (recorder.recordingState == AudioRecord.RECORDSTATE_RECORDING) {
                runCatching { recorder.stop() }
            }
        }
        activeWorker?.join(500)
        activeRecord?.release()
        // Defensive second join for a device whose read only unblocks when the recorder is
        // released. No PCM may be touched after this method hands it to stop() or cancel().
        if (activeWorker?.isAlive == true) {
            activeWorker.join(500)
        }
    }

}
