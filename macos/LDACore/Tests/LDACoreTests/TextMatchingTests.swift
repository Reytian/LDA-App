// Tests/LDACoreTests/TextMatchingTests.swift
import XCTest
@testable import LDACore

final class TextMatchingTests: XCTestCase {
    func testNormalizeCollapsesCaseAndWhitespace() {
        XCTAssertEqual(TextMatching.normalize("  Daniel   OKAFOR \n"), "daniel okafor")
    }

    func testSignificantWordsKeepsOnlyFourPlusAlnum() {
        XCTAssertEqual(
            TextMatching.significantWords("By: Sarah Whitman, CEO"),
            ["sarah", "whitman"]
        )
    }

    func testSharesSignificantWordTrueOnSharedCompleteWord() {
        // Match is on the shared complete word "services"; the function compares
        // whitespace-delimited whole words and does not handle mid-word OCR fragments.
        XCTAssertTrue(
            TextMatching.sharesSignificantWord("CONSULTING SERVICES AGREEMENT",
                                               "lting services agr")
        )
    }

    func testSharesSignificantWordFalseWhenDisjoint() {
        XCTAssertFalse(
            TextMatching.sharesSignificantWord("Sarah Whitman", "")
        )
    }

    func testNormalizeEmptyString() {
        XCTAssertEqual(TextMatching.normalize(""), "")
    }

    func testSignificantWordsEmptyString() {
        XCTAssertTrue(TextMatching.significantWords("").isEmpty)
    }

    func testSignificantWordsFoldsDiacritics() {
        // Input has accents; output must be the de-accented base letters.
        XCTAssertEqual(TextMatching.significantWords("Soci\u{00E9}t\u{00E9} G\u{00E9}n\u{00E9}rale"),
                       ["societe", "generale"])
    }
}
