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

    func testSharesSignificantWordTrueOnCommonWord() {
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
}
