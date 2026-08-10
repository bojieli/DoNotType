package ai.pine19.donottype.core

import android.content.Context
import ai.pine19.donottype.PromptAssets
import ai.pine19.donottype.Settings
import ai.pine19.donottype.audio.WavRecorder
import java.io.File
import java.io.IOException
import java.net.SocketTimeoutException
import java.net.UnknownHostException

/**
 * One place where a recording becomes a transcript, whether it is the first attempt or the fourth.
 *
 * Shared by the keyboard and the settings screen so a retry is not a lesser path: it uses the same
 * prompt, the same model and the stored audio, and produces what the original request would have
 * produced had the network held.
 */
class DictationService(private val context: Context) {

    val history: HistoryStore by lazy {
        HistoryStore(File(context.filesDir, "history")).also {
            it.configure(Settings.retention, Settings.keepAudio)
        }
    }

    /**
     * Errors worth retrying, as opposed to ones that will fail identically forever.
     *
     * Retrying a bad API key just burns the user's time; a timeout or a 503 is exactly what retry
     * exists for.
     */
    fun isTransient(error: Throwable): Boolean = when (error) {
        is SocketTimeoutException, is UnknownHostException -> true
        is ProviderException -> {
            val message = error.message.orEmpty()
            when {
                message.contains("HTTP 401") || message.contains("HTTP 403") -> false
                message.contains("billed 0 audio tokens") -> false
                message.contains("HTTP 4") -> message.contains("HTTP 408") ||
                    message.contains("HTTP 429")
                else -> true
            }
        }
        is IOException -> true
        else -> false
    }

    /** Transcribes, storing the outcome either way so a failure stays retryable. */
    suspend fun transcribe(
        wav: ByteArray,
        screenContext: ScreenContext?,
        appName: String?,
    ): Result<DictationRecord> {
        val key = Settings.apiKey
        if (key.isNullOrBlank()) {
            return Result.failure(ProviderException("No API key. Open DoNotType to add one."))
        }

        history.configure(Settings.retention, Settings.keepAudio)
        // From here, not from the request: reading the screen and any retry are time the user
        // spends waiting, and a figure that skipped them would flatter the app.
        val releasedAt = System.currentTimeMillis()
        val record = DictationRecord(
            model = Settings.model,
            fidelity = Settings.fidelity,
            appName = appName,
            durationSeconds = WavRecorder.durationSeconds(wav),
        )

        return try {
            val parts = buildList {
                if (screenContext != null && !screenContext.isEmpty) {
                    addAll(ContextEncoder().encode(screenContext))
                }
                add(InputPart.Audio(wav, "audio/wav"))
            }
            val requestStart = System.currentTimeMillis()
            val result = GeminiClient(apiKey = key, model = Settings.model)
                .transcribe(PromptAssets.systemInstruction(context, Settings.fidelity), parts)
            record.requestMillis = System.currentTimeMillis() - requestStart
            record.audioTokens = result.usage.audioTokens

            val text = result.transcript.transcript.trim()
            record.status = DictationRecord.Status.COMPLETED
            record.text = text
            record.latencyMillis = System.currentTimeMillis() - releasedAt
            history.insert(record, if (Settings.keepAudio) wav else null)
            Result.success(record)
        } catch (error: Exception) {
            // Audio is kept so this can be retried from the settings screen, or when the keyboard
            // next opens with a working connection.
            record.status = DictationRecord.Status.FAILED
            record.errorMessage = error.message ?: error::class.simpleName
            history.insert(record, wav)
            Result.failure(error)
        }
    }

    /** Reissues a stored dictation. */
    suspend fun retry(record: DictationRecord): Result<DictationRecord> {
        val key = Settings.apiKey
        if (key.isNullOrBlank()) {
            return Result.failure(ProviderException("No API key."))
        }
        val wav = history.audioFor(record)
            ?: return Result.failure(ProviderException("The recording is no longer on disk."))

        record.retryCount += 1
        return try {
            val result = GeminiClient(apiKey = key, model = Settings.model)
                .transcribe(
                    PromptAssets.systemInstruction(context, record.fidelity),
                    listOf(InputPart.Audio(wav, "audio/wav")),
                )
            record.status = DictationRecord.Status.COMPLETED
            record.text = result.transcript.transcript.trim()
            record.errorMessage = null
            history.update(record)
            Result.success(record)
        } catch (error: Exception) {
            record.status = DictationRecord.Status.FAILED
            record.errorMessage = error.message ?: error::class.simpleName
            history.update(record)
            Result.failure(error)
        }
    }

    /**
     * Drains everything that failed while offline.
     *
     * Sequential on purpose: a user coming back online may have a dozen pending dictations, and
     * firing them at once is the fastest way to turn a recoverable backlog into a rate-limited one.
     */
    suspend fun retryAll(): Pair<Int, Int> {
        var succeeded = 0
        var failed = 0
        for (record in history.retryable()) {
            if (retry(record).isSuccess) succeeded++ else failed++
        }
        return succeeded to failed
    }
}
