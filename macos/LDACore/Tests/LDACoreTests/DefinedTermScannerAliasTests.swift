//
//  DefinedTermScannerAliasTests.swift
//  LDACoreTests
//
//  Tests for DefinedTermScanner.aliasBindings: the short-name definitions the
//  scanner reads out of the document so the recall rescan can redact every
//  occurrence of a defined alias and group it with its full name.
//
//  House rules: all comments and strings in English (fixtures may contain
//  Chinese). No em-dash and no en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class DefinedTermScannerAliasTests: XCTestCase {

    // MARK: - Helpers

    private func aliases(in text: String) -> [String] {
        DefinedTermScanner.aliasBindings(in: text).map { $0.alias }
    }

    // MARK: - CJK definition variants

    func testFullwidthParenStraightQuotes() {
        let text = "甲方：杭州快帆科技有限公司（以下简称\"快帆科技\"）同意转让。"
        XCTAssertEqual(aliases(in: text), ["快帆科技"])
    }

    func testFullwidthParenCurlyQuotes() {
        let text = "甲方：杭州快帆科技有限公司（以下简称\u{201C}快帆科技\u{201D}）同意转让。"
        XCTAssertEqual(aliases(in: text), ["快帆科技"])
    }

    func testHalfwidthParenNoQuotes() {
        let text = "甲方：杭州快帆科技有限公司(以下简称快帆科技)同意转让。"
        XCTAssertEqual(aliases(in: text), ["快帆科技"])
    }

    func testXiaChengVariant() {
        let text = "出让方：杭州快帆科技有限公司（下称\"快帆科技\"）。"
        XCTAssertEqual(aliases(in: text), ["快帆科技"])
    }

    func testJianChengWeiVariantWithColon() {
        let text = "杭州快帆科技有限公司（简称为：\"快帆科技\"）。"
        XCTAssertEqual(aliases(in: text), ["快帆科技"])
    }

    func testMultipleQuotedAliasesShareOneAnchor() {
        let text = "杭州快帆科技有限公司（以下简称\"快帆科技\"或\"甲方\"）。"
        let bindings = DefinedTermScanner.aliasBindings(in: text)
        XCTAssertEqual(bindings.map { $0.alias }, ["快帆科技", "甲方"])
        XCTAssertEqual(Set(bindings.map { $0.anchorOffset }).count, 1)
    }

    func testUnquotedInteriorIsNotSplitOnConnectorCharacters() {
        // An unquoted alias containing a connector-like character must not be
        // shredded into fragments (no split of a real name on a CJK char).
        let text = "上海和记贸易有限公司(以下简称和记贸易)。"
        XCTAssertEqual(aliases(in: text), ["和记贸易"])
    }

    func testAnchorOffsetPointsAtOpeningParenthesis() {
        let text = "杭州快帆科技有限公司（以下简称\"快帆科技\"）"
        let bindings = DefinedTermScanner.aliasBindings(in: text)
        XCTAssertEqual(bindings.count, 1)
        let anchor = bindings[0].anchorOffset
        let ns = text as NSString
        XCTAssertEqual(ns.substring(with: NSRange(location: anchor, length: 1)), "（")
    }

    // MARK: - CJK quoted parenthetical without a lead-in

    func testQuotedCJKParentheticalDerivedFromPrecedingNameIsAnAlias() {
        // No 以下简称 lead-in, but the quoted term is contained in the name
        // right before the parenthetical, so it is a real-name alias.
        let text = "杭州快帆科技有限公司（\"快帆科技\"）与张三签订本协议。"
        XCTAssertEqual(aliases(in: text), ["快帆科技"])
        // And it must NOT be a droppable defined term (that would leak it).
        XCTAssertFalse(DefinedTermScanner.droppableTerms(in: text).contains("快帆科技"))
    }

    // MARK: - English parenthetical aliases

    func testEnglishRealNameAliasIsEmitted() {
        let text = "Meridian Works, LLC (the \"Meridian Works\") is the seller."
        XCTAssertEqual(aliases(in: text), ["Meridian Works"])
    }

    func testEnglishAcronymAliasIsEmitted() {
        let text = "International Business Machines (\"IBM\") announced a merger."
        XCTAssertEqual(aliases(in: text), ["IBM"])
    }

    func testEnglishGenericDefinedTermIsNotAnAlias() {
        let text = "the audio equipment (the \"Electronic Media Systems\") stays."
        XCTAssertEqual(aliases(in: text), [])
    }

    func testMeaningClauseTermIsNotAnAlias() {
        let text = "\"Confidential Information\" means any non-public data."
        XCTAssertEqual(aliases(in: text), [])
    }

    func testBoilerplateParentAcronymIsNotAnAlias() {
        let text = "under the Federal Arbitration Act (\"FAA\") the parties agree."
        XCTAssertEqual(aliases(in: text), [])
    }

    // MARK: - Droppable terms stay unchanged

    func testDroppableTermsStillCollectsGenericParentheticals() {
        let text = "the audio equipment (the \"Electronic Media Systems\") stays."
        XCTAssertTrue(DefinedTermScanner.droppableTerms(in: text).contains("electronic media systems"))
    }

    func testDroppableTermsStillKeepsRealNameAliasesOut() {
        let text = "Meridian Works, LLC (\"Meridian Works\") is the seller."
        XCTAssertFalse(DefinedTermScanner.droppableTerms(in: text).contains("meridian works"))
    }
}

// MARK: - Non-contiguous CJK short names (release QA finding, High)

extension DefinedTermScannerAliasTests {

    /// PRC practice routinely forms a short name by keeping the brand and
    /// industry words and dropping the middle: 蓝鲸科技 abbreviates
    /// 深圳市蓝鲸智能科技有限公司 even though 智能 interrupts the run. A
    /// contiguous-substring test rejected exactly these, so every mention of
    /// such a short name leaked. Derivation must accept an ordered character
    /// subsequence.
    func testSkipWordShortNameIsDerived() {
        XCTAssertTrue(DefinedTermScanner.isDerivedAlias(
            "蓝鲸科技",
            of: "深圳市蓝鲸智能科技有限公司"
        ))
    }

    /// Order still matters: characters present but reordered are not an
    /// abbreviation of the name.
    func testReorderedCharactersAreNotDerived() {
        XCTAssertFalse(DefinedTermScanner.isDerivedAlias(
            "科技蓝鲸",
            of: "深圳市蓝鲸智能科技有限公司"
        ))
    }

    /// A character the canonical name never contains breaks derivation.
    func testForeignCharacterIsNotDerived() {
        XCTAssertFalse(DefinedTermScanner.isDerivedAlias(
            "蓝鲸快帆",
            of: "深圳市蓝鲸智能科技有限公司"
        ))
    }

    /// The contiguous case keeps working.
    func testContiguousShortNameStaysDerived() {
        XCTAssertTrue(DefinedTermScanner.isDerivedAlias(
            "快帆科技",
            of: "杭州快帆科技有限公司"
        ))
    }
}
