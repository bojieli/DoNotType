import XCTest

@testable import DoNotTypeCore

final class PersonalDictionaryTests: XCTestCase {
    func testEntriesAreTrimmedCollapsedAndDeduplicatedCaseInsensitively() throws {
        var terms = try PersonalDictionary.adding("  quillmark-sync  ", to: [])
        terms = try PersonalDictionary.adding("Kaelith   Rowan", to: terms)

        XCTAssertEqual(terms, ["quillmark-sync", "Kaelith Rowan"])
        XCTAssertThrowsError(try PersonalDictionary.adding("QUILLMARK-SYNC", to: terms)) {
            XCTAssertEqual(
                $0 as? PersonalDictionary.ValidationError, .duplicate("QUILLMARK-SYNC"))
        }
    }

    func testInvalidEntriesAreRejectedBeforeTheyReachARequest() {
        XCTAssertThrowsError(try PersonalDictionary.normalize("  "))
        XCTAssertThrowsError(try PersonalDictionary.normalize("first\nsecond"))
        XCTAssertThrowsError(
            try PersonalDictionary.normalize(String(repeating: "x", count: 51)))
    }

    func testEditingPreservesOrderAndCannotCreateADuplicate() throws {
        let terms = ["Kaelith", "Brindlewood", "SwiftUI"]
        XCTAssertEqual(
            try PersonalDictionary.replacing("Brindlewood", with: "OpenRouter", in: terms),
            ["Kaelith", "OpenRouter", "SwiftUI"])
        XCTAssertThrowsError(
            try PersonalDictionary.replacing("Brindlewood", with: "swiftui", in: terms))
    }

    func testOneColumnCSVImportSupportsQuotesBOMAndPlainLines() throws {
        let data = Data("\u{FEFF}Kaelith\r\n\"O\"\"Brien\"\r\n\"Smith, Jones\"\r\nkaelith\r\n".utf8)
        XCTAssertEqual(
            try PersonalDictionary.entries(fromCSV: data),
            ["Kaelith", "O\"Brien", "Smith, Jones"])
    }

    func testCSVImportRejectsMultipleColumnsAndIsAtomicAtCapacity() throws {
        XCTAssertThrowsError(
            try PersonalDictionary.entries(fromCSV: Data("Kaelith,Brindlewood\n".utf8))) {
            XCTAssertEqual(
                $0 as? PersonalDictionary.ValidationError, .multipleCSVColumns(line: 1))
        }

        let full = (0..<PersonalDictionary.maxTerms).map { "Term-\($0)" }
        XCTAssertThrowsError(try PersonalDictionary.importing(["OneMore"], into: full))
        XCTAssertEqual(PersonalDictionary.sanitized(full).count, PersonalDictionary.maxTerms)
    }

    func testModelReferenceIsDelimitedAndJSONEncoded() throws {
        let reference = try XCTUnwrap(
            PersonalDictionary.referenceBlock(
                terms: ["Kaelith", "A \"quoted\" name", "GPT-5"]))

        XCTAssertTrue(reference.contains("SPELLING REFERENCE ONLY, DO NOT TRANSCRIBE"))
        XCTAssertTrue(reference.contains(#"["Kaelith","A \"quoted\" name","GPT-5"]"#))
        XCTAssertTrue(reference.contains("Digits, versions and quantities come from audio"))
        XCTAssertNil(PersonalDictionary.referenceBlock(terms: []))
    }

    func testBareKeytermChannelNeverReceivesNumbers() {
        let terms = PersonalDictionary.keyterms(
            from: ["Kaelith", "GPT-5", "quillmark-sync"], maxTerms: 100,
            maxCharactersPerTerm: 50)

        XCTAssertEqual(terms, ["Kaelith", "quillmark-sync"])
    }

    func testUserEntriesWinTheProviderBudgetBeforeDerivedTerms() {
        let terms = PersonalDictionary.mergingKeyterms(
            dictionary: ["Kaelith", "SwiftUI"],
            derived: ["ScreenDecoy", "KAELITH", "AnotherDecoy"], maxTerms: 3,
            maxCharactersPerTerm: 50)

        XCTAssertEqual(terms, ["Kaelith", "SwiftUI", "ScreenDecoy"])
    }

    func testOnlySpellingCorrectionsAreLearnedFromEditedText() {
        XCTAssertEqual(
            PersonalDictionary.learnedCandidates(
                from: "Ask Keyleth about swift UI tomorrow.",
                corrected: "Ask Kaelith about SwiftUI on Friday."),
            ["Kaelith", "SwiftUI"])
    }

    func testLearningIgnoresNumbersInsertionsDeletionsAndOrdinaryRewording() {
        XCTAssertEqual(
            PersonalDictionary.learnedCandidates(
                from: "Use Gemini 3.5 and send the draft",
                corrected: "Please use Gemini 3 and email the final draft"),
            [])
    }

    func testCapitalisationCorrectionCanBeLearned() {
        XCTAssertEqual(
            PersonalDictionary.learnedCandidates(
                from: "The swiftui view", corrected: "The SwiftUI view"),
            ["SwiftUI"])
    }
}
