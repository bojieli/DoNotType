package app.donottype.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class PersonalDictionaryTest {
    @Test fun `entries normalize and deduplicate`() {
        var terms = PersonalDictionary.add("  quillmark-sync  ", emptyList())
        terms = PersonalDictionary.add("Kaelith   Rowan", terms)
        assertEquals(listOf("quillmark-sync", "Kaelith Rowan"), terms)
        assertThrows(PersonalDictionary.ValidationException::class.java) {
            PersonalDictionary.add("QUILLMARK-SYNC", terms)
        }
    }

    @Test fun `csv supports quotes bom and plain lines`() {
        val data = "\uFEFFKaelith\r\n\"O\"\"Brien\"\r\n\"Smith, Jones\"\r\nkaelith\r\n".toByteArray()
        assertEquals(
            listOf("Kaelith", "O\"Brien", "Smith, Jones"),
            PersonalDictionary.entriesFromCsv(data),
        )
    }

    @Test fun `reference is delimited and number terms never reach a recognizer`() {
        val block = PersonalDictionary.referenceBlock(listOf("Kaelith", "GPT-5"))!!
        assertTrue(block.contains("SPELLING REFERENCE ONLY, DO NOT TRANSCRIBE"))
        assertEquals(
            listOf("Kaelith", "quillmark-sync"),
            PersonalDictionary.keyterms(listOf("Kaelith", "GPT-5", "quillmark-sync"), 100, 50),
        )
        assertFalse(block.isBlank())
    }

    @Test fun `user terms consume the keyterm budget first`() {
        assertEquals(
            listOf("Kaelith", "SwiftUI", "ScreenDecoy"),
            PersonalDictionary.mergeKeyterms(
                listOf("Kaelith", "SwiftUI"),
                listOf("ScreenDecoy", "KAELITH", "Other"), 3, 50,
            ),
        )
    }

    @Test fun `learning keeps spelling fixes and rejects ordinary edits`() {
        assertEquals(
            listOf("Kaelith", "SwiftUI"),
            PersonalDictionary.learnedCandidates(
                "Ask Keyleth about swift UI tomorrow.",
                "Ask Kaelith about SwiftUI on Friday.",
            ),
        )
        assertEquals(
            emptyList<String>(),
            PersonalDictionary.learnedCandidates(
                "Use Gemini 3.5 and send the draft",
                "Please use Gemini 3 and email the final draft",
            ),
        )
        assertEquals(
            listOf("SwiftUI"),
            PersonalDictionary.learnedCandidates("The swiftui view", "The SwiftUI view"),
        )
    }
}
