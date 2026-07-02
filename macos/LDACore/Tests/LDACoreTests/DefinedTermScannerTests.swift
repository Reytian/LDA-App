//
//  DefinedTermScannerTests.swift
//  LDACoreTests
//
//  Verifies the document-driven defined-term filter: generic defined terms are
//  collected and covered, real-name aliases stay redactable, and boilerplate
//  parents make their acronyms droppable.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class DefinedTermScannerTests: XCTestCase {

    // MARK: - Parenthetical definitions

    func testGenericParentheticalDefinedTermIsDroppable() {
        let text = "This agreement is between Meridian Works, LLC (the \u{201C}Company\u{201D}) and Jordan Lee."
        let terms = DefinedTermScanner.droppableTerms(in: text)
        XCTAssertTrue(terms.contains("company"))
        XCTAssertTrue(DefinedTermScanner.covers("Company", terms: terms))
        XCTAssertTrue(DefinedTermScanner.covers("the Company", terms: terms))
    }

    func testRealNameAliasIsNotDroppable() {
        // The alias repeats words of the real name right before the definition;
        // dropping it would leak the name at every aliased occurrence.
        let text = "This agreement is between Meridian Works, LLC (\u{201C}Meridian Works\u{201D}) and Jordan Lee."
        let terms = DefinedTermScanner.droppableTerms(in: text)
        XCTAssertFalse(DefinedTermScanner.covers("Meridian Works", terms: terms))
    }

    func testAcronymAliasOfRealCompanyIsNotDroppable() {
        let text = "Services provided by International Business Machines (\u{201C}IBM\u{201D}) under this contract."
        let terms = DefinedTermScanner.droppableTerms(in: text)
        XCTAssertFalse(DefinedTermScanner.covers("IBM", terms: terms))
    }

    func testAcronymOfStatuteIsDroppable() {
        let text = "governed by the Federal Arbitration Act (\u{201C}FAA\u{201D}) and applicable law."
        let terms = DefinedTermScanner.droppableTerms(in: text)
        XCTAssertTrue(DefinedTermScanner.covers("FAA", terms: terms))
    }

    func testCollectivelyLeadInIsRecognized() {
        let text = "the Company's clients, vendors, and partners (collectively, \u{201C}Associated Third Parties\u{201D}) hold information."
        let terms = DefinedTermScanner.droppableTerms(in: text)
        XCTAssertTrue(DefinedTermScanner.covers("Associated Third Parties", terms: terms))
    }

    // MARK: - Meaning-clause definitions

    func testMeansClauseDefinedTermIsDroppable() {
        let text = "\u{201C}Electronic Media Systems\u{201D} means all computer systems and networks of the Company."
        let terms = DefinedTermScanner.droppableTerms(in: text)
        XCTAssertTrue(DefinedTermScanner.covers("Electronic Media Systems", terms: terms))
    }

    func testStraightQuotesAreAccepted() {
        let text = "\"Termination Certification\" means the certificate attached as Exhibit B."
        let terms = DefinedTermScanner.droppableTerms(in: text)
        XCTAssertTrue(DefinedTermScanner.covers("Termination Certification", terms: terms))
    }

    // MARK: - Recombination and sub-phrase coverage

    func testRecombinationOfDefinedTermsIsCovered() {
        let text = """
        \u{201C}Company Electronic Media Equipment\u{201D} means all equipment. \
        \u{201C}Company Electronic Media Systems\u{201D} means all systems.
        """
        let terms = DefinedTermScanner.droppableTerms(in: text)
        // The model recombines and clips defined terms; the word-union test
        // must cover these variants.
        XCTAssertTrue(DefinedTermScanner.covers("Electronic Media Systems", terms: terms))
        XCTAssertTrue(DefinedTermScanner.covers(
            "Electronic Media Equipment or Company Electronic Media Systems", terms: terms
        ))
    }

    func testRealNameIsNotCoveredByUnrelatedTerms() {
        let text = "\u{201C}Confidential Information\u{201D} means non-public information of the Company."
        let terms = DefinedTermScanner.droppableTerms(in: text)
        XCTAssertFalse(DefinedTermScanner.covers("Meridian Works, LLC", terms: terms))
        XCTAssertFalse(DefinedTermScanner.covers("Jordan Lee", terms: terms))
    }

    func testEmptyTermsCoverNothing() {
        XCTAssertFalse(DefinedTermScanner.covers("Company", terms: []))
    }

    func testPageNumberArtifactInsideTermStillMatches() {
        // PDF extraction can splice a page number into a defined term
        // ("Associated Third 2  Parties"). Letters-only tokenization must
        // still cover the clean value.
        let text = "clients and vendors (collectively, \u{201C}Associated Third 2  Parties\u{201D}) as defined."
        let terms = DefinedTermScanner.droppableTerms(in: text)
        XCTAssertTrue(DefinedTermScanner.covers("Associated Third Parties", terms: terms))
    }
}
