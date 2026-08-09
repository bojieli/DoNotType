package ai.pine19.donottype.audio

import android.annotation.SuppressLint
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
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
    }

    private var record: AudioRecord? = null
    private var worker: Thread? = null
    private val pcm = ByteArrayOutputStream()

    @Volatile private var capturing = false
    @Volatile var peakAmplitude: Int = 0
        private set

    private var startedAt = 0L

    val isRecording: Boolean get() = capturing

    @SuppressLint("MissingPermission")
    fun start() {
        if (capturing) return
        pcm.reset()
        peakAmplitude = 0

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
            val buffer = ByteArray(bufferSize)
            while (capturing) {
                val read = recorder.read(buffer, 0, buffer.size)
                if (read > 0) {
                    pcm.write(buffer, 0, read)
                    peakAmplitude = maxOf(peakAmplitude, peak(buffer, read))
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
        worker?.join(500)
        worker = null
        record?.run {
            if (recordingState == AudioRecord.RECORDSTATE_RECORDING) stop()
            release()
        }
        record = null
    }

    private fun peak(buffer: ByteArray, length: Int): Int {
        var peak = 0
        var i = 0
        while (i + 1 < length) {
            val sample = ((buffer[i + 1].toInt() shl 8) or (buffer[i].toInt() and 0xFF)).toShort()
            peak = maxOf(peak, kotlin.math.abs(sample.toInt()))
            i += 2
        }
        return peak
    }

    /** 44-byte canonical RIFF header, PCM 16-bit mono. */
    private fun wrapInWavContainer(pcmData: ByteArray): ByteArray {
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
