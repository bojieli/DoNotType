package app.donottype.core

import android.util.Base64
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL

data class Transcript(val transcript: String, val language: String = "") {
    companion object {
        fun schema(): JSONObject = JSONObject()
            .put("type", "object")
            .put(
                "properties",
                JSONObject()
                    .put("transcript", JSONObject().put("type", "string"))
                    .put("language", JSONObject().put("type", "string")),
            )
            .put("required", JSONArray(listOf("transcript", "language")))

        /**
         * Parses a response that should be JSON but may not quite be.
         *
         * Models wrap structured output in markdown fences often enough that tolerating it is
         * cheaper than failing a dictation over punctuation. A model that ignored the schema
         * entirely still produced usable text, so bare prose becomes the transcript.
         */
        fun parse(raw: String): Transcript {
            val candidate = stripFence(raw).trim()
            return try {
                val json = JSONObject(candidate)
                Transcript(json.optString("transcript"), json.optString("language"))
            } catch (_: Exception) {
                Transcript(candidate)
            }
        }

        private fun stripFence(raw: String): String {
            val text = raw.trim()
            if (!text.startsWith("```")) return text
            return text.lines()
                .drop(1)
                .dropLastWhile { it.trim() == "```" }
                .joinToString("\n")
        }
    }
}

data class TokenUsage(
    val promptTokens: Int? = null,
    val completionTokens: Int? = null,
    val audioTokens: Int? = null,
)

data class TranscriptionResult(
    val transcript: Transcript,
    val usage: TokenUsage,
    val rawOutput: String,
)

class ProviderException(message: String) : IOException(message)

/**
 * Google's Interactions API.
 *
 * Uses `HttpURLConnection` rather than pulling in OkHttp: one POST with a JSON body does not
 * justify a dependency in an IME, where every kilobyte is loaded into every app that shows a
 * keyboard.
 */
class GeminiClient(
    private val apiKey: String,
    private val model: String = "gemini-3.6-flash",
    private val endpoint: String = "https://generativelanguage.googleapis.com/v1beta/interactions",
    private val thinkingLevel: String = "minimal",
) {
    suspend fun transcribe(
        systemInstruction: String,
        parts: List<InputPart>,
        maxOutputTokens: Int = 2048,
    ): TranscriptionResult = withContext(Dispatchers.IO) {
        val body = JSONObject()
            .put("model", model)
            // Server-side retention defaults on, and these requests carry screen contents.
            .put("store", false)
            .put("system_instruction", systemInstruction)
            .put("input", JSONArray(parts.map(::encodePart)))
            .put(
                "response_format",
                JSONObject()
                    .put("type", "text")
                    .put("mime_type", "application/json")
                    .put("schema", Transcript.schema()),
            )
            .put(
                "generation_config",
                JSONObject()
                    .put("thinking_level", thinkingLevel)
                    .put("max_output_tokens", maxOutputTokens),
            )

        val connection = (URL(endpoint).openConnection() as HttpURLConnection).apply {
            requestMethod = "POST"
            doOutput = true
            connectTimeout = 15_000
            readTimeout = 120_000
            setRequestProperty("Content-Type", "application/json")
            setRequestProperty("x-goog-api-key", apiKey)
        }

        try {
            connection.outputStream.use { it.write(body.toString().toByteArray()) }
            val status = connection.responseCode
            val text = (if (status in 200..299) connection.inputStream else connection.errorStream)
                ?.bufferedReader()?.use { it.readText() }.orEmpty()

            if (status !in 200..299) {
                throw ProviderException("HTTP $status: ${text.take(400)}")
            }

            val root = JSONObject(text)
            val usage = parseUsage(root.optJSONObject("usage"))
            assertAudioWasProcessed(parts, usage)

            val output = extractText(root)
                ?: throw ProviderException("Model returned no output")
            TranscriptionResult(Transcript.parse(output), usage, output)
        } finally {
            connection.disconnect()
        }
    }

    /**
     * A gateway that accepts audio and bills zero audio tokens never gave it to the model, and the
     * "transcript" it returns is invented rather than empty. Observed in the wild, so this check
     * lives in the client rather than in a per-provider allowlist.
     */
    private fun assertAudioWasProcessed(parts: List<InputPart>, usage: TokenUsage) {
        val sentAudio = parts.any { it is InputPart.Audio }
        if (sentAudio && usage.audioTokens == 0) {
            throw ProviderException(
                "The provider accepted the audio but billed 0 audio tokens for $model — the " +
                    "recording never reached the model, so any transcript it returned is fabricated.",
            )
        }
    }

    private fun encodePart(part: InputPart): JSONObject = when (part) {
        is InputPart.Text -> JSONObject().put("type", "text").put("text", part.text)
        is InputPart.Image -> JSONObject()
            .put("type", "image")
            .put("data", Base64.encodeToString(part.data, Base64.NO_WRAP))
            .put("mime_type", part.mimeType)
        is InputPart.Audio -> JSONObject()
            .put("type", "audio")
            .put("data", Base64.encodeToString(part.data, Base64.NO_WRAP))
            .put("mime_type", part.mimeType)
    }

    /** Walks `steps[] -> model_output -> content[] -> text`; `output_text` is SDK-added. */
    private fun extractText(root: JSONObject): String? {
        val steps = root.optJSONArray("steps") ?: return null
        val builder = StringBuilder()
        for (i in 0 until steps.length()) {
            val step = steps.optJSONObject(i) ?: continue
            if (step.optString("type") != "model_output") continue
            val content = step.optJSONArray("content") ?: continue
            for (j in 0 until content.length()) {
                val block = content.optJSONObject(j) ?: continue
                if (block.optString("type") == "text") builder.append(block.optString("text"))
            }
        }
        return builder.toString().ifEmpty { null }
    }

    private fun parseUsage(usage: JSONObject?): TokenUsage {
        if (usage == null) return TokenUsage()
        val byModality = usage.optJSONArray("input_tokens_by_modality")
        var audio: Int? = null
        if (byModality != null) {
            audio = 0
            for (i in 0 until byModality.length()) {
                val entry = byModality.optJSONObject(i) ?: continue
                if (entry.optString("modality").equals("audio", ignoreCase = true)) {
                    audio = entry.optInt("tokens")
                }
            }
        }
        return TokenUsage(
            promptTokens = usage.optInt("total_input_tokens").takeIf { it > 0 },
            completionTokens = usage.optInt("total_output_tokens").takeIf { it > 0 },
            audioTokens = audio,
        )
    }
}
