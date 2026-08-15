package app.donottype.core

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.util.UUID

/**
 * The speech recognition backends, which are not language models.
 *
 * Kept in one file because they are variations on a single shape — audio in, text out, no system
 * instruction — and splitting them into three files of forty lines each would hide that. What
 * differs between them is transport and one capability flag, and those differences are easier to
 * see side by side.
 *
 * None of them can serve a text-only request, so rewriting fails here with a message that says to
 * switch provider rather than a bare HTTP 400.
 */
private fun audioPartOrThrow(parts: List<InputPart>, provider: String): InputPart.Audio =
    parts.filterIsInstance<InputPart.Audio>().firstOrNull()
        ?: throw ProviderException(
            "$provider is a speech recognition endpoint and only accepts audio. It cannot " +
                "rewrite or reformat text that has already been transcribed — switch to a model " +
                "provider for that.",
        )

/** Reads a response body whichever stream it arrived on. */
private fun HttpURLConnection.readBody(status: Int): String =
    (if (status in 200..299) inputStream else errorStream)
        ?.bufferedReader()?.use { it.readText() }.orEmpty()

/**
 * Builds `multipart/form-data`. Small, but the kind of code that fails silently — a missing CRLF
 * produces a generic 400 and the bug is invisible in a diff.
 */
private class MultipartBody(val boundary: String = "dnt-${UUID.randomUUID()}") {
    private val buffer = ByteArrayOutputStream()

    fun addField(name: String, value: String) {
        buffer.write("--$boundary\r\n".toByteArray())
        buffer.write("Content-Disposition: form-data; name=\"$name\"\r\n\r\n".toByteArray())
        buffer.write("$value\r\n".toByteArray())
    }

    fun addFile(name: String, filename: String, mimeType: String, bytes: ByteArray) {
        buffer.write("--$boundary\r\n".toByteArray())
        buffer.write(
            "Content-Disposition: form-data; name=\"$name\"; filename=\"$filename\"\r\n".toByteArray(),
        )
        buffer.write("Content-Type: $mimeType\r\n\r\n".toByteArray())
        buffer.write(bytes)
        buffer.write("\r\n".toByteArray())
    }

    fun finish(): ByteArray {
        buffer.write("--$boundary--\r\n".toByteArray())
        return buffer.toByteArray()
    }

    companion object {
        fun fileExtension(mimeType: String): String = when (mimeType.lowercase()) {
            "audio/wav", "audio/x-wav", "audio/wave" -> "wav"
            "audio/flac", "audio/x-flac" -> "flac"
            "audio/mpeg", "audio/mp3" -> "mp3"
            "audio/ogg", "audio/opus" -> "ogg"
            "audio/aac" -> "aac"
            else -> "bin"
        }
    }
}

/**
 * Deepgram's `/v1/listen`.
 *
 * `language` defaults to nova-3's `multi` rather than `detect_language`, which is measured rather
 * than read off the documentation: detection scored 12/42 against multi's 18/42 on the near-miss
 * suite, and fails by returning HTTP 200 with an *empty* transcript when it guesses wrong. Neither
 * setting transcribes Mandarin — `language = "zh"` does. See docs/EVALUATION.md.
 */
class DeepgramClient(
    private val apiKey: String,
    override val model: String = "nova-3",
    private val language: String? = null,
    private val endpoint: String = "https://api.deepgram.com/v1/listen",
) : TranscriptionProvider {
    override val name = "deepgram"

    override fun grounding(): GroundingSupport =
        if (model.startsWith(KEYTERM_CAPABLE_PREFIX)) {
            GroundingSupport.Keyterms(MAX_KEYTERMS, MAX_KEYTERM_CHARS)
        } else {
            GroundingSupport.None
        }

    override suspend fun transcribe(
        systemInstruction: String,
        parts: List<InputPart>,
        fidelity: Fidelity,
        keyterms: List<String>,
        maxOutputTokens: Int,
    ): TranscriptionResult = withContext(Dispatchers.IO) {
        val audio = audioPartOrThrow(parts, name)

        val query = StringBuilder("?model=").append(URLEncoder.encode(model, "UTF-8"))
        // The fidelity ladder in the only vocabulary this endpoint has, which has two rungs where
        // PROMPT.md has three. `light` and `tidy` collapse: Deepgram's only unpunctuated mode also
        // returns everything lower case, which breaks `light`'s "keep proper nouns" clause more
        // visibly than adding punctuation breaks its other half.
        when (fidelity) {
            Fidelity.RAW -> query.append("&punctuate=false&smart_format=false&filler_words=true")
            Fidelity.LIGHT, Fidelity.TIDY -> query.append("&smart_format=true&filler_words=false")
        }
        query.append(languageQuery(language, model))
        if (grounding() is GroundingSupport.Keyterms) {
            for (term in keyterms.take(MAX_KEYTERMS)) {
                if (term.length <= MAX_KEYTERM_CHARS) {
                    query.append("&keyterm=").append(URLEncoder.encode(term, "UTF-8"))
                }
            }
        }

        val connection = (URL(endpoint + query).openConnection() as HttpURLConnection).apply {
            requestMethod = "POST"
            doOutput = true
            connectTimeout = 15_000
            readTimeout = 120_000
            setRequestProperty("Authorization", "Token $apiKey")
            setRequestProperty("Content-Type", audio.mimeType)
        }

        ProviderHttp.request(name, model, endpoint + query, audio.data.size)
        val startedAt = System.currentTimeMillis()

        try {
            connection.outputStream.use { it.write(audio.data) }
            val status = connection.responseCode
            val body = connection.readBody(status)
            ProviderHttp.response(name, model, status, body.length, System.currentTimeMillis() - startedAt)
            if (status !in 200..299) {
                throw ProviderException(
                    "HTTP $status: ${errorMessage(body)}", status = status, body = body,
                )
            }

            val transcript = parse(body)
            if (transcript.transcript.isBlank()) throw ProviderException("Model returned no output")
            // No usage: Deepgram bills by audio duration and reports no token counts. Reporting
            // zero audio tokens would trip the silent-drop guard on every successful call.
            TranscriptionResult(transcript, TokenUsage(), body)
        } catch (error: Exception) {
            ProviderHttp.failed(name, model, error, System.currentTimeMillis() - startedAt)
            throw error
        } finally {
            connection.disconnect()
        }
    }

    companion object {
        const val KEYTERM_CAPABLE_PREFIX = "nova-3"
        const val MAX_KEYTERMS = 100
        const val MAX_KEYTERM_CHARS = 50

        /** `multi` is nova-3 only; sending it to an older model is a 400. */
        fun languageQuery(explicit: String?, model: String): String = when {
            !explicit.isNullOrEmpty() -> "&language=" + URLEncoder.encode(explicit, "UTF-8")
            model.startsWith(KEYTERM_CAPABLE_PREFIX) -> "&language=multi"
            else -> "&detect_language=true"
        }

        fun parse(body: String): Transcript {
            val channel = JSONObject(body)
                .optJSONObject("results")
                ?.optJSONArray("channels")
                ?.optJSONObject(0)
                ?: throw ProviderException("no transcript in response: $body")
            val text = channel.optJSONArray("alternatives")?.optJSONObject(0)
                ?.optString("transcript")
                ?: throw ProviderException("no transcript in response: $body")
            return Transcript(text.trim(), channel.optString("detected_language", ""))
        }

        fun errorMessage(body: String): String = try {
            val root = JSONObject(body)
            val message = root.optString("err_msg").ifEmpty { root.optString("message") }
            val code = root.optString("err_code")
            when {
                message.isNotEmpty() && code.isNotEmpty() -> "$message ($code)"
                message.isNotEmpty() -> message
                else -> body
            }
        } catch (_: Exception) {
            body
        }
    }
}

/**
 * Mistral Voxtral, `POST /v1/audio/transcriptions`.
 *
 * The recognition backend that transcribes Mandarin and English without being told which is
 * coming, including inside one sentence. It has no biasing channel: `context=` and `prompt=` are
 * both accepted with HTTP 200 and both leave the transcript byte-identical, so [grounding] is
 * `None` rather than `Keyterms`. Measured, not assumed.
 */
class MistralClient(
    private val apiKey: String,
    override val model: String = "voxtral-mini-latest",
    private val language: String? = null,
    private val endpoint: String = "https://api.mistral.ai/v1/audio/transcriptions",
) : TranscriptionProvider {
    override val name = "mistral"

    override fun grounding(): GroundingSupport = GroundingSupport.None

    override suspend fun transcribe(
        systemInstruction: String,
        parts: List<InputPart>,
        fidelity: Fidelity,
        keyterms: List<String>,
        maxOutputTokens: Int,
    ): TranscriptionResult = withContext(Dispatchers.IO) {
        val audio = audioPartOrThrow(parts, name)

        val body = MultipartBody()
        body.addField("model", model)
        if (!language.isNullOrEmpty()) body.addField("language", language)
        // No fidelity field: the endpoint exposes no formatting or disfluency control, and it
        // accepts unknown fields silently, so sending an invented one would be worse than none.
        body.addFile(
            "file",
            "audio.${MultipartBody.fileExtension(audio.mimeType)}",
            audio.mimeType,
            audio.data,
        )
        val payload = body.finish()

        val connection = (URL(endpoint).openConnection() as HttpURLConnection).apply {
            requestMethod = "POST"
            doOutput = true
            connectTimeout = 15_000
            readTimeout = 120_000
            setRequestProperty("Authorization", "Bearer $apiKey")
            setRequestProperty("Content-Type", "multipart/form-data; boundary=${body.boundary}")
        }

        ProviderHttp.request(name, model, endpoint, payload.size)
        val startedAt = System.currentTimeMillis()

        try {
            connection.outputStream.use { it.write(payload) }
            val status = connection.responseCode
            val text = connection.readBody(status)
            ProviderHttp.response(name, model, status, text.length, System.currentTimeMillis() - startedAt)
            if (status !in 200..299) {
                throw ProviderException(
                    "HTTP $status: ${errorMessage(text)}", status = status, body = text,
                )
            }

            val root = JSONObject(text)
            val usage = parseUsage(root)
            // Unlike the others, Voxtral does report audio tokens, so the silent-drop guard is
            // live here rather than skipped for want of a number.
            if (usage.audioTokens == 0) {
                throw ProviderException(
                    "$name accepted the audio but billed 0 audio tokens for $model — the " +
                        "recording never reached the model, so any transcript is fabricated.",
                )
            }

            val transcript = Transcript(
                root.optString("text").trim(),
                root.optString("language", ""),
            )
            if (transcript.transcript.isBlank()) throw ProviderException("Model returned no output")
            TranscriptionResult(transcript, usage, text)
        } catch (error: Exception) {
            ProviderHttp.failed(name, model, error, System.currentTimeMillis() - startedAt)
            throw error
        } finally {
            connection.disconnect()
        }
    }

    companion object {
        fun parseUsage(root: JSONObject): TokenUsage {
            val usage = root.optJSONObject("usage") ?: return TokenUsage()
            val details = usage.optJSONObject("prompt_tokens_details")
            return TokenUsage(
                promptTokens = usage.optInt("prompt_tokens").takeIf { it > 0 },
                completionTokens = usage.optInt("completion_tokens").takeIf { it > 0 },
                audioTokens = details?.let {
                    if (it.has("audio_tokens")) it.optInt("audio_tokens") else null
                },
            )
        }

        fun errorMessage(body: String): String = try {
            val root = JSONObject(body)
            val message = root.optString("message")
                .ifEmpty { root.optJSONObject("error")?.optString("message").orEmpty() }
            message.ifEmpty { body }
        } catch (_: Exception) {
            body
        }
    }
}

/**
 * xAI's `/v1/stt`.
 *
 * **Never verified against the live API.** Every xAI key available when this was written was
 * rejected with `Incorrect API key provided` on every endpoint and auth scheme, so this is written
 * to the published specification. Its error parsing is confirmed against the real 400 body;
 * nothing else about it has been exercised.
 */
class XAISpeechClient(
    private val apiKey: String,
    override val model: String = "grok-stt",
    private val language: String? = null,
    private val endpoint: String = "https://api.x.ai/v1/stt",
) : TranscriptionProvider {
    override val name = "xai"

    override fun grounding(): GroundingSupport =
        GroundingSupport.Keyterms(MAX_KEYTERMS, MAX_KEYTERM_CHARS)

    override suspend fun transcribe(
        systemInstruction: String,
        parts: List<InputPart>,
        fidelity: Fidelity,
        keyterms: List<String>,
        maxOutputTokens: Int,
    ): TranscriptionResult = withContext(Dispatchers.IO) {
        val audio = audioPartOrThrow(parts, name)

        val body = MultipartBody()
        // `format` is inverse text normalisation — spoken numbers written as numerals. On for
        // `light` as well as `tidy`, so numbers do not diverge from every other backend.
        body.addField("format", if (fidelity == Fidelity.RAW) "false" else "true")
        body.addField("filler_words", if (fidelity == Fidelity.RAW) "true" else "false")
        if (!language.isNullOrEmpty()) body.addField("language", language)
        for (term in keyterms.take(MAX_KEYTERMS)) {
            if (term.length <= MAX_KEYTERM_CHARS) body.addField("keyterm", term)
        }
        body.addFile(
            "file",
            "audio.${MultipartBody.fileExtension(audio.mimeType)}",
            audio.mimeType,
            audio.data,
        )
        val payload = body.finish()

        val connection = (URL(endpoint).openConnection() as HttpURLConnection).apply {
            requestMethod = "POST"
            doOutput = true
            connectTimeout = 15_000
            readTimeout = 120_000
            setRequestProperty("Authorization", "Bearer $apiKey")
            setRequestProperty("Content-Type", "multipart/form-data; boundary=${body.boundary}")
        }

        ProviderHttp.request(name, model, endpoint, payload.size)
        val startedAt = System.currentTimeMillis()

        try {
            connection.outputStream.use { it.write(payload) }
            val status = connection.responseCode
            val text = connection.readBody(status)
            ProviderHttp.response(name, model, status, text.length, System.currentTimeMillis() - startedAt)
            if (status !in 200..299) {
                throw ProviderException(
                    "HTTP $status: ${errorMessage(text)}", status = status, body = text,
                )
            }

            val root = JSONObject(text)
            val transcript = Transcript(
                root.optString("text").trim(),
                root.optString("language", ""),
            )
            if (transcript.transcript.isBlank()) throw ProviderException("Model returned no output")
            TranscriptionResult(transcript, TokenUsage(), text)
        } catch (error: Exception) {
            ProviderHttp.failed(name, model, error, System.currentTimeMillis() - startedAt)
            throw error
        } finally {
            connection.disconnect()
        }
    }

    companion object {
        const val MAX_KEYTERMS = 100
        const val MAX_KEYTERM_CHARS = 50

        fun errorMessage(body: String): String = try {
            val root = JSONObject(body)
            val message = root.optString("error")
            val code = root.optString("code")
            when {
                message.isNotEmpty() && code.isNotEmpty() -> "$message ($code)"
                message.isNotEmpty() -> message
                else -> body
            }
        } catch (_: Exception) {
            body
        }
    }
}
