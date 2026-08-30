import XCTest

@testable import DoNotTypeCore

/// What the Model field accepts, and what it says about the rest.
///
/// These are sentences a user actually reads, so they are asserted as text. The rules match
/// `windows/DoNotType.Core/ModelIdentifier.cs` and
/// `android/app/src/main/kotlin/app/donottype/core/ModelIdentifier.kt` deliberately, and the tests
/// are duplicated in each language rather than shared: a fixture would be read by whichever
/// platform remembered to read it.
final class ModelIdentifierTests: XCTestCase {
    /// The shapes that actually reach these providers. A rule that rejected any of these would
    /// stop somebody configuring a model that works.
    func testRealModelIdentifiersAreAccepted() {
        for id in [
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
        ] {
            XCTAssertTrue(ModelIdentifier.isValid(id), id)
            XCTAssertNil(ModelIdentifier.validationMessage(for: id), id)
        }
    }

    /// Clearing the field is how a user asks for the backend's default, which every client already
    /// reads that way. Reporting it as an error would make the documented gesture look broken.
    func testAnEmptyFieldIsNotAnError() {
        XCTAssertNil(ModelIdentifier.validationMessage(for: ""))
        XCTAssertNil(ModelIdentifier.validationMessage(for: "   "))
    }

    /// Surrounding space is trimmed on the way to storage on every client, so flagging it would
    /// report a problem that the next line of code removes.
    func testSurroundingWhitespaceIsTrimmedRatherThanRejected() {
        XCTAssertNil(ModelIdentifier.validationMessage(for: "  gemini-3.6-flash \n"))
    }

    /// The case this whole check exists for: the field had focus, and a sentence went into it.
    func testADictatedSentenceIsRejectedForItsSpaces() {
        let message = ModelIdentifier.validationMessage(for: "please open the door")
        XCTAssertEqual(
            message,
            "A model ID has no spaces in it. Check for a stray space, or for a sentence that "
                + "landed in this field by accident.")
    }

    /// Named rather than described. "Invalid character" leaves the user hunting through a string
    /// they cannot see the end of; the character itself is the whole answer.
    func testANonASCIICharacterIsNamedInTheMessage() {
        let message = ModelIdentifier.validationMessage(for: "模型-flash")
        XCTAssertEqual(
            message,
            "\"模\" is not a character model IDs are made of. They use letters, digits, and "
                + ". _ - : / + @ — for example gemini-3.6-flash.")
    }

    /// Accented Latin is as wrong here as CJK and used to be the likelier accident, since it
    /// arrives from a keyboard layout rather than from an input method.
    func testAccentedLatinIsRejected() {
        XCTAssertFalse(ModelIdentifier.isValid("café-flash"))
    }

    /// Punctuation that no provider uses but a shell or a URL does. Left in, these reach the
    /// request as part of the model name and come back as a 404.
    func testPunctuationOutsideTheAllowedSetIsRejected() {
        for id in ["gemini!flash", "gemini,flash", "gemini(flash)", "gemini#flash", "gemini$flash"]
        {
            XCTAssertFalse(ModelIdentifier.isValid(id), id)
        }
    }

    /// A newline is whitespace, so it gets the sentence about spaces rather than an unprintable
    /// character quoted into the middle of a message.
    func testATabOrNewlineReadsAsASpace() {
        for id in ["gemini\tflash", "gemini\nflash"] {
            XCTAssertEqual(
                ModelIdentifier.validationMessage(for: id),
                "A model ID has no spaces in it. Check for a stray space, or for a sentence that "
                    + "landed in this field by accident.",
                id)
        }
    }

    /// A pasted paragraph is caught as a paragraph. Without a cap it would be reported by whatever
    /// character in it happened to be disallowed first, which explains nothing.
    func testAPastedParagraphIsRejectedForItsLength() {
        let long = String(repeating: "a", count: ModelIdentifier.maxLength + 1)
        XCTAssertEqual(
            ModelIdentifier.validationMessage(for: long),
            "A model ID is at most 200 characters. This looks like something other than a model "
                + "ID ended up in the field.")
    }

    func testTheLengthCapIsInclusive() {
        XCTAssertTrue(
            ModelIdentifier.isValid(String(repeating: "a", count: ModelIdentifier.maxLength)))
    }
}
