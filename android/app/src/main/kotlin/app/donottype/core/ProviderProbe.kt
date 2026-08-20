package app.donottype.core

import android.os.SystemClock
import java.io.ByteArrayOutputStream
import java.util.Locale
import kotlin.math.roundToInt

/**
 * One cheap round trip that answers "will this key work when it matters?".
 *
 * It exists because the alternative is finding out mid-dictation: the key is only read once the
 * user has already spoken, so a wrong or absent one surfaced as a failed recording rather than as
 * a setting that needed fixing. Asking while nothing is at stake turns that into a question
 * answered before the first word.
 *
 * Shared rather than copied because it now has two callers -- the settings screen and onboarding.
 * A second copy would be a second opinion about whether a key works, and the one place a user
 * checks that is the one place it must not disagree with itself.
 *
 * Mirrors `ProviderProbe.check` in the Swift core. The one deliberate difference is what comes
 * back: Swift returns an outcome its view formats, this returns the line to show, because both
 * Android callers show the same sentence and duplicating the formatting is how they would drift.
 */
object ProviderProbe {

    /**
     * @param accepted whether the provider answered and took the key. Drives the colour; the two
     *   ways of failing (refused, unreachable) both read as bad news and both say why in [message].
     */
    data class Result(val message: String, val accepted: Boolean)

    /**
     * A quarter second of silence sent the way a dictation is sent.
     *
     * Audio for every backend, including the model ones. They used to get a text round trip, which
     * a text-only relay or checkpoint answers perfectly well before dropping the first real
     * recording -- "OpenAI-compatible" is a claim about the request shape, not about whether there
     * is anywhere to put a recording. Probing with the shape a dictation uses moves that discovery
     * here, where it costs nothing.
     */
    suspend fun check(provider: ProviderKind, apiKey: String, model: String): Result {
        val client = ProviderFactory.create(provider, apiKey, model)
        val parts = listOf(InputPart.Audio(silentProbeWav(), "audio/wav"))

        val started = SystemClock.elapsedRealtimeNanos()
        val outcome = runCatching {
            client.transcribe("You are a transcription engine.", parts)
        }
        val latency = latencyLabel(SystemClock.elapsedRealtimeNanos() - started)

        return outcome.fold(
            onSuccess = { Result("✓ Reachable, key accepted · $latency", accepted = true) },
            onFailure = { error ->
                // Silence transcribes to nothing, which is the correct answer and proves the round
                // trip worked.
                if (error.message?.contains("no output", ignoreCase = true) == true) {
                    Result("✓ Reachable, key accepted · $latency", accepted = true)
                } else {
                    // Never shortened. What the provider said is the whole of what the user has to
                    // act on, and it is the line they will paste into a bug report.
                    Result("✗ ${error.message} · $latency", accepted = false)
                }
            },
        )
    }

    /** How long the round trip took, in the unit that reads at that scale. */
    fun latencyLabel(nanoseconds: Long): String {
        val milliseconds = nanoseconds.coerceAtLeast(0) / 1_000_000.0
        return if (milliseconds < 1_000) {
            "${milliseconds.roundToInt()} ms"
        } else {
            String.format(Locale.ROOT, "%.2f s", milliseconds / 1_000)
        }
    }

    /**
     * A quarter-second of 16 kHz mono silence, built rather than shipped as an asset so the APK
     * does not carry a resource used by one button.
     *
     * The duration is deliberate rather than merely cheap: it is the shortest audio this app will
     * ever send for real, so anything a provider does to this clip it would do to a dictation.
     */
    fun silentProbeWav(): ByteArray {
        val sampleRate = 16_000
        val dataBytes = sampleRate / 4 * 2
        val out = ByteArrayOutputStream()
        fun ascii(value: String) = out.write(value.toByteArray(Charsets.US_ASCII))
        fun u32(value: Int) = out.write(
            byteArrayOf(
                value.toByte(),
                (value shr 8).toByte(),
                (value shr 16).toByte(),
                (value shr 24).toByte(),
            ),
        )
        fun u16(value: Int) = out.write(byteArrayOf(value.toByte(), (value shr 8).toByte()))

        ascii("RIFF"); u32(36 + dataBytes); ascii("WAVEfmt ")
        u32(16); u16(1); u16(1); u32(sampleRate); u32(sampleRate * 2); u16(2); u16(16)
        ascii("data"); u32(dataBytes)
        out.write(ByteArray(dataBytes))
        return out.toByteArray()
    }
}
