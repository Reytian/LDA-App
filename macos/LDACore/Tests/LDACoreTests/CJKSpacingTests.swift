//
//  CJKSpacingTests.swift
//  LDACoreTests
//
//  Tests for CJKSpacing.tightenScriptBoundaries(_:), the parse-side repair for
//  models that inject spaces at CJK-to-ASCII script boundaries.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class CJKSpacingTests: XCTestCase {

    func testRemovesSpacesAroundDigitsInCJKAddress() {
        let drifted = "杭州市西湖区文三路化工路口 98 号云汇大厦 12 层"
        let expected = "杭州市西湖区文三路化工路口98号云汇大厦12层"

        XCTAssertEqual(CJKSpacing.tightenScriptBoundaries(drifted), expected)
    }

    func testRemovesSpacesAroundDigitsInCJKDate() {
        let drifted = "2027 年 3 月 18 日"
        let expected = "2027年3月18日"

        XCTAssertEqual(CJKSpacing.tightenScriptBoundaries(drifted), expected)
    }

    func testRemovesRunOfSpacesBetweenCJKAndDigit() {
        XCTAssertEqual(CJKSpacing.tightenScriptBoundaries("路口  98  号"), "路口98号")
    }

    func testRemovesSpacesAroundLatinLettersInCJKAddress() {
        // Measured drift mode: a building block letter spaced inside a CJK run.
        let drifted = "合肥市高新区望江西路 800 号创新产业园 C 座 6 层"
        let expected = "合肥市高新区望江西路800号创新产业园C座6层"

        XCTAssertEqual(CJKSpacing.tightenScriptBoundaries(drifted), expected)
    }

    func testRemovesSpacesAroundLatinWordEmbeddedInCJK() {
        XCTAssertEqual(CJKSpacing.tightenScriptBoundaries("阿里巴巴 Alibaba 集团"), "阿里巴巴Alibaba集团")
    }

    func testPreservesSpaceBetweenDigitAndLatin() {
        let value = "98 Main Street"

        XCTAssertEqual(CJKSpacing.tightenScriptBoundaries(value), value)
    }

    func testPreservesSpaceBetweenLatinWords() {
        let value = "Alice Wong"

        XCTAssertEqual(CJKSpacing.tightenScriptBoundaries(value), value)
    }

    func testPreservesSpaceBetweenTwoCJKCharacters() {
        let value = "北京 公司"

        XCTAssertEqual(CJKSpacing.tightenScriptBoundaries(value), value)
    }

    func testLeavesCleanValuesUntouched() {
        XCTAssertEqual(CJKSpacing.tightenScriptBoundaries("杭州市西湖区文三路98号"), "杭州市西湖区文三路98号")
        XCTAssertEqual(CJKSpacing.tightenScriptBoundaries(""), "")
    }

    func testReportsWhetherValueCarriesDigitBoundarySpacing() {
        XCTAssertTrue(CJKSpacing.hasScriptBoundarySpacing("路口 98 号"))
        XCTAssertFalse(CJKSpacing.hasScriptBoundarySpacing("路口98号"))
        XCTAssertFalse(CJKSpacing.hasScriptBoundarySpacing("98 Main Street"))
    }
}
