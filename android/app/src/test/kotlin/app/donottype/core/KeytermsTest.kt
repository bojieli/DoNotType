package app.donottype.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The Kotlin port of `Keyterms` has to agree with the Swift one.
 *
 * These are the same cases as `Tests/DoNotTypeCoreTests/KeytermsTests.swift`, deliberately. A
 * biasing list that differs by platform means the Android app is grounded differently from the one
 * the evaluation measured, and nothing else in the project would notice.
 */
class KeytermsTest {

    @Test
    fun `nothing containing a digit is ever emitted`() {
        val context = ScreenContext(
            visibleText = """
                Upgrade to Gemini 3.5 Flash before Tuesday. Port 8080 is taken, use 9090.
                Version v2.1.0 shipped. Contact Kaelith about the Brindlewood migration.
            """.trimIndent(),
        )
        val terms = Keyterms.derive(context)

        for (term in terms) {
            assertFalse("$term carries a digit", term.any(Char::isDigit))
        }
        // The names still come through — the rule costs nothing it should not cost.
        assertTrue(terms.contains("Kaelith"))
        assertTrue(terms.contains("Brindlewood"))
    }

    @Test
    fun `acronyms camelCase and joined identifiers qualify`() {
        val terms = Keyterms.candidates(
            "The HTTP handler in OpenRouter calls quillmark-sync and snake_case_helper.",
        )
        assertTrue(terms.contains("HTTP"))
        assertTrue(terms.contains("OpenRouter"))
        assertTrue(terms.contains("quillmark-sync"))
        assertTrue(terms.contains("snake_case_helper"))
    }

    /** A capital opening a sentence is grammar, not a proper noun. */
    @Test
    fun `sentence initial capitals are not treated as proper nouns`() {
        val terms = Keyterms.candidates("We shipped Brindlewood today. However it broke.")
        assertTrue(terms.contains("Brindlewood"))
        assertFalse(terms.contains("We"))
        assertFalse(terms.contains("However"))
    }

    @Test
    fun `ordinary prose yields nothing`() {
        assertEquals(
            emptyList<String>(),
            Keyterms.candidates("we should probably just ship it and see what happens"),
        )
    }

    @Test
    fun `surrounding punctuation is trimmed but identifiers keep their own`() {
        val terms = Keyterms.candidates("""See (Kaelith), "Brindlewood" and README.md here.""")
        assertTrue(terms.contains("Kaelith"))
        assertTrue(terms.contains("Brindlewood"))
        assertTrue(terms.contains("README.md"))
    }

    @Test
    fun `terms nearest the caret come first`() {
        val context = ScreenContext(
            visibleText = "FarAway MentionedOnlyInBody",
            textBeforeCaret = "NearCaret",
            selectedText = "SelectedFirst",
        )
        val terms = Keyterms.derive(context)

        assertEquals("SelectedFirst", terms.first())
        assertTrue(terms.indexOf("NearCaret") < terms.indexOf("FarAway"))
    }

    @Test
    fun `term count is capped and duplicates collapse case insensitively`() {
        val words = (0 until 300).joinToString(" ") { "AlphaName${('a' + it % 26)}Term" }
        assertTrue(Keyterms.derive(ScreenContext(visibleText = words), maxTerms = 5).size <= 5)

        val repeated = ScreenContext(visibleText = "start Brindlewood BRINDLEWOOD brindlewood again")
        assertEquals(
            1,
            Keyterms.derive(repeated).count { it.lowercase() == "brindlewood" },
        )
    }

    @Test
    fun `terms longer than the limit are dropped`() {
        val long = "Kaelith" + "x".repeat(60)
        val terms = Keyterms.derive(
            ScreenContext(visibleText = "start $long and Brindlewood"),
            maxCharsPerTerm = 50,
        )
        assertFalse(terms.contains(long))
        assertTrue(terms.contains("Brindlewood"))
    }

    /** The defect that made this feature useless for a bilingual user. */
    @Test
    fun `latin terms are extracted from code-switched chinese`() {
        val context = ScreenContext(
            visibleText = "我要把这几个串起来搞成一个retrieval pipeline，然后用Kubernetes部署。" +
                "参考Google的做法。看一下quillmark-sync这个repo。",
            textBeforeCaret = "刚才说的RAG方案",
        )
        val terms = Keyterms.derive(context)

        assertTrue(terms.toString(), terms.contains("RAG"))
        assertTrue(terms.toString(), terms.contains("Kubernetes"))
        assertTrue(terms.toString(), terms.contains("quillmark-sync"))
        assertFalse(terms.toString(), terms.any { term -> term.any { it.isCJKScript() } })
    }

    /** Pure Chinese yields nothing, which is honest rather than a bug: no segmentation here. */
    @Test
    fun `pure chinese yields nothing rather than a blob`() {
        assertEquals(
            emptyList<String>(),
            Keyterms.derive(ScreenContext(visibleText = "我要把这几个串起来然后部署到线上环境。")),
        )
    }

    @Test
    fun `unbalanced brackets and quotes split rather than ride along`() {
        val terms = Keyterms.candidates("""lib.func('getFocusedAppInfo') and git commit --author="Li Bojie"""")

        assertTrue(terms.toString(), terms.contains("lib.func"))
        assertTrue(terms.toString(), terms.contains("getFocusedAppInfo"))
        assertTrue(terms.toString(), terms.contains("--author"))
        assertFalse(terms.any { it.contains("'") || it.contains("\"") || it.contains("(") })
    }

    /** A dot is interior to README.md and terminal after `tokens.`; only look-ahead separates them. */
    @Test
    fun `a full stop ends a sentence unless a word continues it`() {
        val terms = Keyterms.candidates(
            "Costs \$3.00 per million tokens. Compare Gemini and read README.md for details.",
        )
        assertTrue(terms.toString(), terms.contains("README.md"))
        assertFalse(terms.toString(), terms.contains("Compare"))
        assertTrue(terms.toString(), terms.contains("Gemini"))
    }

    @Test
    fun `contractions are rejected but apostrophe names survive`() {
        assertFalse(Keyterms.candidates("Ask Kaelith, I'll review it").contains("I'll"))
        assertTrue(Keyterms.candidates("Ask O'Brien about it").contains("O'Brien"))
    }

    @Test
    fun `command line flags qualify whether or not they are hyphenated`() {
        val terms = Keyterms.candidates("run git commit --amend --no-edit --author now")
        assertTrue(terms.toString(), terms.contains("--amend"))
        assertTrue(terms.toString(), terms.contains("--no-edit"))
        assertTrue(terms.toString(), terms.contains("--author"))
    }

    @Test
    fun `empty context yields no terms`() {
        assertEquals(emptyList<String>(), Keyterms.derive(ScreenContext()))
        assertEquals(
            emptyList<String>(),
            Keyterms.derive(ScreenContext(visibleText = "a b"), maxTerms = 0),
        )
    }
}

/** Request shaping for the recognition clients, without touching the network. */
class SpeechRecognitionClientTest {

    /** `multi` measured 18/42 against detection's 12/42 on the near-miss suite. */
    @Test
    fun `nova-3 defaults to multilingual rather than detection`() {
        assertEquals("&language=multi", DeepgramClient.languageQuery(null, "nova-3"))
    }

    /** `multi` is nova-3 only and a 400 on anything older. */
    @Test
    fun `older models fall back to detection`() {
        assertEquals("&detect_language=true", DeepgramClient.languageQuery(null, "nova-2"))
    }

    @Test
    fun `an explicit language always wins`() {
        assertEquals("&language=zh", DeepgramClient.languageQuery("zh", "nova-3"))
        assertEquals("&language=zh", DeepgramClient.languageQuery("zh", "nova-2"))
    }

    @Test
    fun `keyterm support is reported per model`() {
        assertTrue(DeepgramClient("k", "nova-3").grounding() is GroundingSupport.Keyterms)
        assertTrue(DeepgramClient("k", "nova-2").grounding() is GroundingSupport.None)
    }

    /** Voxtral has no biasing channel: `context` and `prompt` are accepted and ignored. */
    @Test
    fun `mistral reports no grounding at all`() {
        assertTrue(MistralClient("k").grounding() is GroundingSupport.None)
    }

    @Test
    fun `deepgram parses transcript and detected language`() {
        val body = """
            {"results":{"channels":[{"detected_language":"en",
            "alternatives":[{"transcript":"Should switch to Gemini 3.5 flash."}]}]}}
        """.trimIndent().replace("\n", "")
        val transcript = DeepgramClient.parse(body)
        assertEquals("Should switch to Gemini 3.5 flash.", transcript.transcript)
        assertEquals("en", transcript.language)
    }

    @Test
    fun `deepgram error body is unwrapped to the actionable sentence`() {
        assertEquals(
            "Token is invalid (INVALID_AUTH)",
            DeepgramClient.errorMessage("""{"err_code":"INVALID_AUTH","err_msg":"Token is invalid"}"""),
        )
    }

    /** The one part of the xAI client confirmed against the live API. */
    @Test
    fun `xai error body is unwrapped`() {
        assertEquals(
            "Incorrect API key provided. (invalid-argument)",
            XAISpeechClient.errorMessage(
                """{"code":"invalid-argument","error":"Incorrect API key provided."}""",
            ),
        )
    }

    /** Android was the one platform without an OpenAI-compatible client. */
    @Test
    fun `openrouter is reachable and reports multimodal grounding`() {
        val client = ProviderFactory.create(
            ProviderKind.OPENROUTER, "k", ProviderKind.OPENROUTER.defaultModel,
        )
        assertEquals("openrouter", client.name)
        assertTrue(client.grounding() is GroundingSupport.Multimodal)
    }

    @Test
    fun `openai audio format is a bare codec name`() {
        assertEquals("wav", OpenAiCompatibleClient.audioFormat("audio/wav"))
        assertEquals("ogg", OpenAiCompatibleClient.audioFormat("audio/ogg"))
        assertEquals("mp3", OpenAiCompatibleClient.audioFormat("audio/mpeg"))
    }

    /** 3.6 accepts `minimal`; 3.7 rejects it. A hardcoded level broke every request. */
    @Test
    fun `each gemini family gets the cheapest thinking level it accepts`() {
        assertEquals("minimal", GeminiClient.cheapestThinkingLevelForTest("gemini-3.6-flash"))
        assertEquals("low", GeminiClient.cheapestThinkingLevelForTest("gemini-3.7-flash"))
        assertEquals("low", GeminiClient.cheapestThinkingLevelForTest("gemini-4-flash"))
        assertEquals("minimal", GeminiClient.cheapestThinkingLevelForTest("gemini-2.5-flash"))
    }

    @Test
    fun `providers know which are recognition only`() {
        assertTrue(ProviderKind.DEEPGRAM.isSpeechRecognition)
        assertTrue(ProviderKind.MISTRAL.isSpeechRecognition)
        assertTrue(ProviderKind.XAI.isSpeechRecognition)
        assertFalse(ProviderKind.GEMINI.isSpeechRecognition)
        assertEquals("nova-3", ProviderKind.DEEPGRAM.defaultModel)
    }
}
