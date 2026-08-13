import XCTest

@testable import DoNotTypeCore

final class KeytermsTests: XCTestCase {
    // MARK: - The rule that is not negotiable

    /// The whole reason this project exists. A keyterm list has no "reference only" clause to
    /// attach, so a number in it is a request for the substitution bug.
    func testNothingContainingADigitIsEverEmitted() {
        let context = ScreenContext(
            visibleText: """
                Upgrade to Gemini 3.5 Flash before Tuesday. Port 8080 is taken, use 9090.
                Version v2.1.0 shipped. Contact Kaelith about the Brindlewood migration.
                """)
        let terms = Keyterms.derive(from: context)

        for term in terms {
            XCTAssertFalse(
                term.contains(where: \.isNumber),
                "\(term) carries a digit and must never be sent as a keyterm")
        }
        // The names still come through — the rule costs nothing it should not cost.
        XCTAssertTrue(terms.contains("Kaelith"))
        XCTAssertTrue(terms.contains("Brindlewood"))
    }

    // MARK: - What qualifies

    func testAcronymsCamelCaseAndJoinedIdentifiersQualify() {
        let terms = Keyterms.candidates(
            in: "The HTTP handler in OpenRouter calls quillmark-sync and snake_case_helper.")

        XCTAssertTrue(terms.contains("HTTP"))
        XCTAssertTrue(terms.contains("OpenRouter"))
        XCTAssertTrue(terms.contains("quillmark-sync"))
        XCTAssertTrue(terms.contains("snake_case_helper"))
    }

    /// A capital at the start of a sentence is grammar, not a proper noun. Biasing toward every
    /// sentence opener would spend the whole hundred-slot budget on "The" and "We".
    ///
    /// The accepted cost is the reverse case, asserted here so it stays a known trade rather than
    /// a surprise: a genuine proper noun that happens to open a sentence is missed. Recovering it
    /// would mean deciding "Brindlewood" is a name and "However" is not, which is the analysis
    /// this type exists to avoid doing.
    func testSentenceInitialCapitalsAreNotTreatedAsProperNouns() {
        let terms = Keyterms.candidates(in: "We shipped Brindlewood today. However it broke.")
        XCTAssertTrue(terms.contains("Brindlewood"), "mid-sentence capital is a proper noun")
        XCTAssertFalse(terms.contains("We"), "opens the text")
        XCTAssertFalse(terms.contains("However"), "opens a sentence — grammar, not a name")
    }

    func testOrdinaryProseYieldsNothing() {
        XCTAssertEqual(
            Keyterms.candidates(in: "we should probably just ship it and see what happens"), [])
    }

    func testCommonInterfaceWordsAreIgnored() {
        let terms = Keyterms.candidates(in: "the File menu and the Edit menu in a Window titled Untitled")
        XCTAssertFalse(terms.contains("File"))
        XCTAssertFalse(terms.contains("Edit"))
        XCTAssertFalse(terms.contains("Untitled"))
    }

    func testSurroundingPunctuationIsTrimmedButIdentifiersKeepTheirOwn() {
        let terms = Keyterms.candidates(in: #"See (Kaelith), "Brindlewood" and README.md here."#)
        XCTAssertTrue(terms.contains("Kaelith"))
        XCTAssertTrue(terms.contains("Brindlewood"))
        XCTAssertTrue(terms.contains("README.md"), "interior dot is part of the filename")
    }

    // MARK: - Budget

    /// Caret-adjacent text predicts what someone is about to say far better than the rest of a
    /// long window, so it must survive truncation.
    func testTermsNearestTheCaretComeFirst() {
        let context = ScreenContext(
            visibleText: "FarAway MentionedOnlyInBody",
            textBeforeCaret: "NearCaret",
            selectedText: "SelectedFirst")
        let terms = Keyterms.derive(from: context)

        XCTAssertEqual(terms.first, "SelectedFirst")
        XCTAssertEqual(terms.firstIndex(of: "NearCaret").map { $0 < terms.firstIndex(of: "FarAway")! },
            true)
    }

    func testTermCountIsCappedAtTheProviderLimit() {
        let words = (0..<300).map { "Term\($0)Name" }.joined(separator: " ")
        // Digits are stripped by the guard above, so build names that survive it.
        let alphabetic = (0..<300)
            .map { "Alpha\(String(repeating: "x", count: $0 % 7 + 1))Name\($0 % 26 + 65)" }
        _ = words

        let context = ScreenContext(visibleText: alphabetic.joined(separator: " "))
        XCTAssertLessThanOrEqual(Keyterms.derive(from: context, maxTerms: 100).count, 100)
        XCTAssertLessThanOrEqual(Keyterms.derive(from: context, maxTerms: 5).count, 5)
    }

    func testTermsLongerThanTheLimitAreDropped() {
        let long = "Kaelith" + String(repeating: "x", count: 60)
        let context = ScreenContext(visibleText: "start \(long) and Brindlewood")
        let terms = Keyterms.derive(from: context, maxCharsPerTerm: 50)

        XCTAssertFalse(terms.contains(long))
        XCTAssertTrue(terms.contains("Brindlewood"))
    }

    func testDuplicatesAreCollapsedCaseInsensitively() {
        let context = ScreenContext(
            visibleText: "start Brindlewood then BRINDLEWOOD then brindlewood again")
        XCTAssertEqual(Keyterms.derive(from: context).filter { $0.lowercased() == "brindlewood" }.count, 1)
    }

    // MARK: - Scripts

    /// The defect that made this feature useless for a bilingual user.
    ///
    /// Chinese is written without spaces, so a whitespace split glued every Latin term to the Han
    /// characters beside it. On real code-switched text the extractor emitted exactly one term —
    /// a mixed-script blob — and lost `Kubernetes`, `quillmark-sync` and `RAG` entirely.
    func testLatinTermsAreExtractedFromCodeSwitchedChinese() {
        let context = ScreenContext(
            visibleText: "我要把这几个串起来搞成一个retrieval pipeline，然后用Kubernetes部署。"
                + "参考Google的做法。看一下quillmark-sync这个repo。",
            textBeforeCaret: "刚才说的RAG方案")
        let terms = Keyterms.derive(from: context)

        XCTAssertTrue(terms.contains("RAG"), "\(terms)")
        XCTAssertTrue(terms.contains("Kubernetes"), "\(terms)")
        XCTAssertTrue(terms.contains("quillmark-sync"), "\(terms)")
        // And no mixed-script blobs: a term containing Han characters is one this type cannot
        // judge, because judging it would need word segmentation.
        XCTAssertFalse(terms.contains { $0.contains(where: \.isCJKScript) }, "\(terms)")
    }

    /// Pure Chinese yields nothing, and that is the honest answer rather than a bug.
    ///
    /// Identifying a Chinese term needs segmentation; emitting an unsegmented clause as a keyterm
    /// would bias the recogniser toward a string nobody said. Pinned so the limitation stays a
    /// decision rather than a surprise.
    func testPureChineseYieldsNothingRatherThanABlob() {
        XCTAssertEqual(
            Keyterms.derive(from: ScreenContext(visibleText: "我要把这几个串起来然后部署到线上环境。")),
            [])
    }

    // MARK: - Punctuation

    /// Quotes and brackets end a term rather than riding along inside one. Before this, real
    /// screen text produced `koffi.load('libContextHelper.dylib` and `--author="Li` — terms
    /// carrying an unmatched bracket, biasing toward a string that appears nowhere.
    func testUnbalancedBracketsAndQuotesSplitRatherThanRideAlong() {
        let terms = Keyterms.candidates(
            in: #"lib.func('getFocusedAppInfo') and git commit --author="Li Bojie""#)

        XCTAssertTrue(terms.contains("lib.func"), "\(terms)")
        XCTAssertTrue(terms.contains("getFocusedAppInfo"), "\(terms)")
        XCTAssertTrue(terms.contains("--author"), "\(terms)")
        XCTAssertFalse(terms.contains { $0.contains("'") || $0.contains("\"") || $0.contains("(") })
    }

    /// A full stop is interior to `README.md` and terminal after `tokens.`, and only a look-ahead
    /// separates them. Treating every dot as word-internal lost sentence boundaries altogether,
    /// which let ordinary sentence openers in as though they were proper nouns.
    func testAFullStopEndsASentenceUnlessAWordContinuesIt() {
        let terms = Keyterms.candidates(
            in: "Costs $3.00 per million tokens. Compare Gemini and read README.md for details.")

        XCTAssertTrue(terms.contains("README.md"), "\(terms)")
        XCTAssertFalse(terms.contains("Compare"), "opens a sentence — grammar, not a name")
        XCTAssertTrue(terms.contains("Gemini"), "mid-sentence capital is still a proper noun")
    }

    /// Contractions were reaching the list as "capital mid-sentence, therefore a proper noun".
    /// Names that genuinely carry an apostrophe must survive.
    func testContractionsAreRejectedButApostropheNamesSurvive() {
        XCTAssertFalse(Keyterms.candidates(in: "Ask Kaelith, I'll review it").contains("I'll"))
        XCTAssertTrue(Keyterms.candidates(in: "Ask O'Brien about it").contains("O'Brien"))
    }

    func testCommandLineFlagsQualifyWhetherOrNotTheyAreHyphenated() {
        let terms = Keyterms.candidates(in: "run git commit --amend --no-edit --author now")
        XCTAssertTrue(terms.contains("--amend"), "\(terms)")
        XCTAssertTrue(terms.contains("--no-edit"), "\(terms)")
        XCTAssertTrue(terms.contains("--author"), "\(terms)")
    }

    func testEmptyContextYieldsNoTerms() {
        XCTAssertEqual(Keyterms.derive(from: ScreenContext()), [])
        XCTAssertEqual(Keyterms.derive(from: ScreenContext(visibleText: "a b"), maxTerms: 0), [])
    }
}
