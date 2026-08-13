package app.donottype.core

/**
 * What a backend can do with what is on screen.
 *
 * This exists because the two kinds of backend are not interchangeable and the difference is
 * invisible at the call site. A model provider reads PROMPT.md, the labelled screen text and the
 * screenshot. A speech recognition endpoint reads none of them — it has no system instruction, no
 * eyes and no notion of a conversation. Handing one a screen context and carrying on would produce
 * a transcript that looks grounded, is recorded in history as grounded, and was produced by a
 * model that never saw the screen.
 *
 * That is the same class of failure as the zero-audio-token check, which this codebase already
 * refuses to let pass quietly, so it gets the same treatment: the capability is declared and
 * [Dictation] sends each backend only what it can use.
 */
sealed class GroundingSupport {
    /** Reads everything: system instruction, labelled screen text, screenshot. */
    object Multimodal : GroundingSupport()

    /** A recogniser that accepts a list of spellings to bias toward, and nothing else. */
    data class Keyterms(val maxTerms: Int, val maxCharsPerTerm: Int) : GroundingSupport()

    /** A recogniser with no biasing channel at all. Screen context is unusable, full stop. */
    object None : GroundingSupport()
}

/**
 * A backend that turns audio, and possibly context, into a transcript.
 *
 * Deliberately narrower than the macOS protocol: Android has no pre-upload path, so nothing here
 * needs to describe one.
 */
interface TranscriptionProvider {
    val name: String
    val model: String

    /**
     * Takes the model because the capability is often the model's rather than the backend's:
     * Deepgram offers keyterm biasing on nova-3 and rejects the parameter on everything older.
     */
    fun grounding(): GroundingSupport

    suspend fun transcribe(
        systemInstruction: String,
        parts: List<InputPart>,
        fidelity: Fidelity = Fidelity.DEFAULT,
        keyterms: List<String> = emptyList(),
        maxOutputTokens: Int = 2048,
    ): TranscriptionResult
}

/**
 * Known backends.
 *
 * `isSpeechRecognition` drives the parts of the UI that would otherwise offer settings with no
 * effect: grounding, the fidelity ladder's middle rung, and anything that needs a language model.
 */
enum class ProviderKind(
    val id: String,
    val displayName: String,
    val defaultModel: String,
    val isSpeechRecognition: Boolean,
) {
    GEMINI("gemini", "Gemini", "gemini-3.6-flash", false),

    /**
     * Any model through OpenRouter. Verified to forward audio, and the way to reach models Google
     * does not serve directly.
     *
     * **Prefer [GEMINI] for a Gemini model.** The same model ID measures worse through the
     * gateway: 38-43/48 with 2-5 regressions per suite run against native's 44/48 with 1.
     */
    OPENROUTER(
        "openrouter",
        "OpenRouter (gateway — prefer Gemini for Gemini models)",
        "google/gemini-3.6-flash",
        false,
    ),
    DEEPGRAM("deepgram", "Deepgram (transcription only)", "nova-3", true),

    /**
     * The recognition backend for a bilingual user: the only one here that transcribes Mandarin
     * and English without being told which is coming. See docs/EVALUATION.md.
     */
    MISTRAL("mistral", "Mistral Voxtral (transcription only)", "voxtral-mini-latest", true),

    /**
     * Multilingual, and the only recogniser here whose language setting also controls number
     * formatting: an explicit language buys "3.5" and costs code-switching.
     */
    XAI("xai", "xAI (transcription only)", "grok-stt", true),
    ;

    companion object {
        /**
         * What a fresh install uses.
         *
         * A recogniser rather than a model, measured on the 100-clip ordinary-dictation corpus:
         * xAI is the fastest backend tested (0.98 s median against the model's 5.44 s) and the
         * only recogniser that does not fall over on non-English speech — Deepgram failed 44 of
         * 68 Chinese clips outright. The model is one tap away in this picker for the case where
         * grounding pays: dictating identifiers with the reference on screen.
         */
        val DEFAULT = XAI

        fun from(id: String?): ProviderKind =
            entries.firstOrNull { it.id == id } ?: DEFAULT
    }
}

object ProviderFactory {
    fun create(kind: ProviderKind, apiKey: String, model: String): TranscriptionProvider =
        when (kind) {
            ProviderKind.GEMINI -> GeminiClient(apiKey = apiKey, model = model)
            ProviderKind.OPENROUTER -> OpenAiCompatibleClient(
                name = "openrouter",
                endpoint = "https://openrouter.ai/api/v1/chat/completions",
                apiKey = apiKey,
                model = model,
                extraHeaders = mapOf(
                    "HTTP-Referer" to "https://github.com/donottype/donottype",
                    "X-Title" to "DoNotType",
                ),
            )
            ProviderKind.DEEPGRAM -> DeepgramClient(apiKey = apiKey, model = model)
            ProviderKind.MISTRAL -> MistralClient(apiKey = apiKey, model = model)
            ProviderKind.XAI -> XAISpeechClient(apiKey = apiKey, model = model)
        }
}
