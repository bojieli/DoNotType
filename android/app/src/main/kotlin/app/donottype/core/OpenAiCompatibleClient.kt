package app.donottype.core

import android.util.Base64
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

/**
 * Any `/v1/chat/completions` gateway — OpenRouter, and most others.
 *
 * Android was the one platform without this, which made "the same features everywhere" untrue in
 * the direction that matters least visibly: the picker simply had one fewer entry, so nobody would
 * report it as broken.
 *
 * Multimodal parts map onto the OpenAI content-array shape: `input_audio` for the recording,
 * `image_url` with a data URI for the screenshot. Accepting those blocks is not the same as
 * processing them, which is why the zero-audio-token guard runs here too.
 *
 * **Prefer [GeminiClient] for a Gemini model.** The same model ID measures worse through this
 * gateway than through the first-party API — 38–43/48 with 2–5 regressions against native's 44/48
 * with 1 — and regressions are the number this project exists to report.
 */
class OpenAiCompatibleClient(
    override val name: String,
    private val endpoint: String,
    private val apiKey: String,
    override val model: String,
    private val extraHeaders: Map<String, String> = emptyMap(),
) : TranscriptionProvider {

    override fun grounding(): GroundingSupport = GroundingSupport.Multimodal

    /**
     * `fidelity` and `keyterms` are ignored, and that is not an oversight: fidelity already reached
     * this backend inside [systemInstruction], and keyterms exist only for endpoints with no
     * instruction to put them in.
     */
    override suspend fun transcribe(
        systemInstruction: String,
        parts: List<InputPart>,
        fidelity: Fidelity,
        keyterms: List<String>,
        maxOutputTokens: Int,
    ): TranscriptionResult = withContext(Dispatchers.IO) {
        val content = JSONArray()
        for (part in parts) {
            when (part) {
                is InputPart.Text -> content.put(
                    JSONObject().put("type", "text").put("text", part.text),
                )
                is InputPart.Image -> content.put(
                    JSONObject().put("type", "image_url").put(
                        "image_url",
                        JSONObject().put(
                            "url",
                            "data:${part.mimeType};base64," +
                                Base64.encodeToString(part.data, Base64.NO_WRAP),
                        ),
                    ),
                )
                is InputPart.Audio -> content.put(
                    JSONObject().put("type", "input_audio").put(
                        "input_audio",
                        JSONObject()
                            .put("data", Base64.encodeToString(part.data, Base64.NO_WRAP))
                            .put("format", audioFormat(part.mimeType)),
                    ),
                )
            }
        }

        val body = JSONObject()
            .put("model", model)
            .put(
                "messages",
                JSONArray()
                    .put(JSONObject().put("role", "system").put("content", systemInstruction))
                    .put(JSONObject().put("role", "user").put("content", content)),
            )
            .put("max_tokens", maxOutputTokens)

        val connection = (URL(endpoint).openConnection() as HttpURLConnection).apply {
            requestMethod = "POST"
            doOutput = true
            connectTimeout = 15_000
            readTimeout = 120_000
            setRequestProperty("Content-Type", "application/json")
            setRequestProperty("Authorization", "Bearer $apiKey")
            extraHeaders.forEach { (key, value) -> setRequestProperty(key, value) }
        }

        val payload = body.toString().toByteArray()
        ProviderHttp.request(name, model, endpoint, payload.size)
        val startedAt = System.currentTimeMillis()

        try {
            connection.outputStream.use { it.write(payload) }
            val status = connection.responseCode
            val text = (if (status in 200..299) connection.inputStream else connection.errorStream)
                ?.bufferedReader()?.use { it.readText() }.orEmpty()
            ProviderHttp.response(name, model, status, text.length, System.currentTimeMillis() - startedAt)

            if (status !in 200..299) {
                throw ProviderException("HTTP $status: $text", status = status, body = text)
            }

            val root = JSONObject(text)
            // Some gateways return HTTP 200 with an error object in the body.
            root.optJSONObject("error")?.let {
                throw ProviderException("HTTP $status: $it", status = status, body = it.toString())
            }

            val usage = parseUsage(root.optJSONObject("usage"))
            // A gateway that accepts audio and bills zero audio tokens never gave it to the model,
            // and the transcript it returns is invented rather than empty.
            if (parts.any { it is InputPart.Audio } && usage.audioTokens == 0) {
                throw ProviderException(
                    "$name accepted the audio but billed 0 audio tokens for $model — the recording " +
                        "never reached the model, so any transcript it returned is fabricated.",
                )
            }

            val output = root.optJSONArray("choices")?.optJSONObject(0)
                ?.optJSONObject("message")?.optString("content").orEmpty()
            if (output.isBlank()) throw ProviderException("Model returned no output")

            TranscriptionResult(Transcript.parse(output), usage, output)
        } catch (error: Exception) {
            ProviderHttp.failed(name, model, error, System.currentTimeMillis() - startedAt)
            throw error
        } finally {
            connection.disconnect()
        }
    }

    companion object {
        /** The `format` field wants a bare codec name, not a MIME type. */
        fun audioFormat(mimeType: String): String = when (mimeType.lowercase()) {
            "audio/wav", "audio/x-wav", "audio/wave" -> "wav"
            "audio/flac", "audio/x-flac" -> "flac"
            "audio/mpeg", "audio/mp3" -> "mp3"
            "audio/ogg", "audio/opus" -> "ogg"
            "audio/aac" -> "aac"
            else -> mimeType.removePrefix("audio/")
        }

        fun parseUsage(usage: JSONObject?): TokenUsage {
            if (usage == null) return TokenUsage()
            val details = usage.optJSONObject("prompt_tokens_details")
            return TokenUsage(
                promptTokens = usage.optInt("prompt_tokens").takeIf { it > 0 },
                completionTokens = usage.optInt("completion_tokens").takeIf { it > 0 },
                audioTokens = details?.let {
                    if (it.has("audio_tokens")) it.optInt("audio_tokens") else null
                },
            )
        }
    }
}
