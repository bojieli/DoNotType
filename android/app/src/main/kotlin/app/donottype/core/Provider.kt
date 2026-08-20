package app.donottype.core

/**
 * What a backend can do with what is on screen.
 *
 * This exists because the two kinds of backend are not interchangeable and the difference is
 * invisible at the call site. A model provider reads the contract in prompt/, the labelled screen text and the
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
 * Deliberately narrow: audio and context in, transcript out, so nothing here
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

    /**
     * Where a dictation will be sent, so the connection can be opened while the user is still
     * speaking rather than after they stop. Null disables warm-up for this backend.
     *
     * The origin rather than the endpoint: any answer from the host proves the connection, and a
     * GET to the API path would be a real call with a real bill.
     */
    val endpointOrigin: String?
        get() = null

    suspend fun transcribe(
        systemInstruction: String,
        parts: List<InputPart>,
        fidelity: Fidelity = Fidelity.DEFAULT,
        keyterms: List<String> = emptyList(),
        maxOutputTokens: Int = 2048,
        wantsStyledOutput: Boolean = false,
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
    GEMINI("gemini", "Gemini", "gemini-3.5-flash", false),

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
        "google/gemini-3.5-flash",
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

    /**
     * The row label in a settings picker — never in a history row, a log line or an error, which
     * say what ran rather than what we advise.
     */
    val pickerLabel: String
        get() = if (isRecommended) "$displayName — recommended" else displayName

    /**
     * Whether this backend can turn text into text — the rewrite pass.
     *
     * Deliberately its own question rather than the negation of [isSpeechRecognition], because on
     * macOS and iOS they already have different answers: xAI is a recogniser that also sells chat
     * on the same key. Android has no text-provider plumbing yet, so here the two still agree —
     * when that port lands, this is the single place that changes.
     */
    val supportsTextGeneration: Boolean get() = !isSpeechRecognition

    /**
     * The backend's name with nothing appended, for a sentence that is already about what it
     * cannot do.
     *
     * [displayName] carries "(transcription only)" for the picker, which reads as a stutter inside
     * a sentence that goes on to say exactly that.
     */
    val plainName: String
        get() = when (this) {
            GEMINI -> "Gemini"
            OPENROUTER -> "OpenRouter"
            DEEPGRAM -> "Deepgram"
            MISTRAL -> "Mistral"
            XAI -> "xAI"
        }

    /**
     * One line under the picker: what this backend is recommended *for*, and the measurement
     * behind the claim. Empty for the rest — a picker that recommends everything recommends
     * nothing.
     *
     * Word for word the same as the Swift and C# copies, which is checked by the tests in each
     * language rather than by anything that can see all three at once.
     */
    val recommendationNote: String
        get() = when (this) {
            GEMINI ->
                "Recommended for technical dictation. On seven recent jargon-heavy recordings, " +
                    "Gemini 3.5 retained names and commands more consistently than 3.6; no human " +
                    "goldens exist for those clips yet. It reads the screen for spelling context. " +
                    "The older near-miss goldens still favour 3.6."
            XAI ->
                "Recommended for speed. About 1 s for a short clip, 2.8 s for two minutes of " +
                    "speech, and no tail. It cannot see the screen, so an unfamiliar name or a " +
                    "version number is transcribed by ear alone: 15 of 48 on the same suite, 25 " +
                    "with keyterm biasing turned on."
            else -> ""
        }

    val isRecommended: Boolean
        get() = this in RECOMMENDED

    companion object {
        /**
         * The two backends recommended to someone who has not read docs/EVALUATION.md, in the
         * order every picker lists them.
         *
         * Narrowed from five to two deliberately: the rest each answer a question these two
         * cannot, and none of them is a better answer to the question a new user is actually
         * asking. A recommendation is possible at all because these two are the two ends of one
         * axis — Gemini reads the screen and xAI cannot — so the choice is one question rather
         * than five.
         */
        val RECOMMENDED = listOf(GEMINI, XAI)

        /**
         * Every backend with the recommended ones first: the order every picker in this app uses.
         * Order is the recommendation that survives a Spinner showing three rows at a time.
         */
        val PICKER_ORDER = RECOMMENDED + entries.filter { it !in RECOMMENDED }

        /**
         * What a fresh install uses.
         *
         * A model rather than a recogniser, because a recogniser cannot see the screen and screen
         * grounding is the entire point of this project. The current 3.5 recommendation comes
         * from a seven-clip technical-dictation sweep: it retained the current jargon more
         * consistently than 3.6 and returned faster, though those clips have no human goldens.
         * The older adversarial near-miss goldens still favour 3.6.
         *
         * It is bought with latency. On the 100-clip ordinary-dictation corpus a recogniser is
         * far faster — xAI 0.98 s median — while a model is several seconds. The exact figure for
         * the first-party API is unmeasured (the 5.44 s on record is the same model class through
         * a gateway), so no number for it is quoted here. A user who wants the speed back picks
         * xAI in this picker; it keeps its own key and model.
         */
        val DEFAULT = GEMINI

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
