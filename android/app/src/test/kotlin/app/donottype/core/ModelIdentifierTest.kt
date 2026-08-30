package app.donottype.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * What the Model field accepts, and what it says about the rest.
 *
 * These are sentences a user actually reads, so they are asserted as text. The rules match
 * `Sources/DoNotTypeCore/ModelIdentifier.swift` and `windows/DoNotType.Core/ModelIdentifier.cs`
 * deliberately, and the tests are duplicated in each language rather than shared: a fixture would
 * be read by whichever platform remembered to read it.
 */
class ModelIdentifierTest {

    private val spacesMessage =
        "A model ID has no spaces in it. Check for a stray space, or for a sentence that landed " +
            "in this field by accident."

    /**
     * The shapes that actually reach these providers. A rule that rejected any of these would stop
     * somebody configuring a model that works.
     */
    @Test
    fun `real model identifiers are accepted`() {
        listOf(
            "gemini-3.6-flash",
            "google/gemini-3.6-flash",
            "nova-3",
            "grok-4-fast-non-reasoning",
            "voxtral-mini-latest",
            "gpt-4o-2024-08-06",
            "accounts/fireworks/models/llama-v3p1-8b",
            "qwen2.5:7b-instruct-q4_K_M",
            "ft:gpt-4o:acme:tone:1",
            "local-model",
        ).forEach {
            assertTrue(it, ModelIdentifier.isValid(it))
            assertNull(it, ModelIdentifier.validationMessage(it))
        }
    }

    /**
     * Clearing the field is how a user asks for the backend's default, which every client already
     * reads that way. Reporting it as an error would make the documented gesture look broken.
     */
    @Test
    fun `an empty field is not an error`() {
        assertNull(ModelIdentifier.validationMessage(""))
        assertNull(ModelIdentifier.validationMessage("   "))
        assertNull(ModelIdentifier.validationMessage(null))
    }

    /**
     * Surrounding space is trimmed on the way to storage on every client, so flagging it would
     * report a problem that the next line of code removes.
     */
    @Test
    fun `surrounding whitespace is trimmed rather than rejected`() {
        assertNull(ModelIdentifier.validationMessage("  gemini-3.6-flash \n"))
    }

    /** The case this whole check exists for: the field had focus, and a sentence went into it. */
    @Test
    fun `a dictated sentence is rejected for its spaces`() {
        assertEquals(spacesMessage, ModelIdentifier.validationMessage("please open the door"))
    }

    /**
     * Named rather than described. "Invalid character" leaves the user hunting through a string
     * they cannot see the end of; the character itself is the whole answer.
     */
    @Test
    fun `a non-ASCII character is named in the message`() {
        assertEquals(
            "\"模\" is not a character model IDs are made of. They use letters, digits, and " +
                ". _ - : / + @ — for example gemini-3.6-flash.",
            ModelIdentifier.validationMessage("模型-flash"),
        )
    }

    /**
     * Accented Latin is as wrong here as CJK and used to be the likelier accident, since it
     * arrives from a keyboard layout rather than from an input method.
     */
    @Test
    fun `accented latin is rejected`() {
        assertFalse(ModelIdentifier.isValid("café-flash"))
    }

    /**
     * Punctuation that no provider uses but a shell or a URL does. Left in, these reach the request
     * as part of the model name and come back as a 404.
     */
    @Test
    fun `punctuation outside the allowed set is rejected`() {
        listOf("gemini!flash", "gemini,flash", "gemini(flash)", "gemini#flash", "gemini\$flash")
            .forEach { assertFalse(it, ModelIdentifier.isValid(it)) }
    }

    /**
     * A newline is whitespace, so it gets the sentence about spaces rather than an unprintable
     * character quoted into the middle of a message.
     */
    @Test
    fun `a tab or newline reads as a space`() {
        listOf("gemini\tflash", "gemini\nflash").forEach {
            assertEquals(it, spacesMessage, ModelIdentifier.validationMessage(it))
        }
    }

    /**
     * A pasted paragraph is caught as a paragraph. Without a cap it would be reported by whatever
     * character in it happened to be disallowed first, which explains nothing.
     */
    @Test
    fun `a pasted paragraph is rejected for its length`() {
        assertEquals(
            "A model ID is at most 200 characters. This looks like something other than a model " +
                "ID ended up in the field.",
            ModelIdentifier.validationMessage("a".repeat(ModelIdentifier.MAX_LENGTH + 1)),
        )
    }

    @Test
    fun `the length cap is inclusive`() {
        assertTrue(ModelIdentifier.isValid("a".repeat(ModelIdentifier.MAX_LENGTH)))
    }
}
