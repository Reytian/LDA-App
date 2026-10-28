//
//  NameHeadsTests.swift
//  LDACoreTests
//
//  A short Chinese word that only ends a longer company or brand name (巧克力
//  in 费列罗巧克力) is redacted where it was found and never spread. In a
//  guiding case one stray report of 巧克力 as a company redacted the word at
//  every one of its 35 occurrences.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class NameHeadsTests: XCTestCase {

    func testAShortTailOfALongerNameIsAHead() {
        let heads = NameHeads.heads(in: [("费列罗巧克力", .company), ("巧克力", .company), ("金莎", .trademark)])
        XCTAssertEqual(heads, ["巧克力"])
    }

    func testAShortTailOfABrandIsAHeadToo() {
        XCTAssertEqual(NameHeads.heads(in: [("金莎巧克力", .trademark), ("巧克力", .company)]), ["巧克力"])
    }

    func testALongerTailIsANameOfItsOwn() {
        XCTAssertTrue(NameHeads.heads(in: [("费列罗公司费列罗巧克力", .company), ("费列罗巧克力", .company)]).isEmpty)
    }

    func testLatinValuesAndPersonsAreNeverHeads() {
        XCTAssertTrue(NameHeads.heads(in: [("The Acme Corp", .company), ("Corp", .company)]).isEmpty)
        XCTAssertTrue(NameHeads.heads(in: [("张小明", .person), ("小明", .person)]).isEmpty)
    }

    func testTheRescanDoesNotSpreadAHead() {
        let text = "费列罗巧克力上市多年。每粒金球状巧克力均有纸托。巧克力行业的包装各不相同。"
        let ns = text as NSString
        func span(_ value: String, from start: Int) -> Span {
            let range = ns.range(of: value, range: NSRange(location: start, length: ns.length - start))
            return Span(start: range.location, end: range.location + range.length, type: .company,
                        text: value, source: .llm, confidence: 0.9, priority: 30)
        }
        let name = span("费列罗巧克力", from: 0)
        let stray = span("巧克力", from: name.end)

        let expanded = EntityRescan.expand([name, stray], in: text)

        XCTAssertEqual(expanded.filter { $0.text == "巧克力" }.map(\.start), [stray.start],
                       "the stray head stays where it was found; 巧克力行业 stays visible")
        XCTAssertEqual(expanded.filter { $0.text == "费列罗巧克力" }.count, 1)
    }
}
