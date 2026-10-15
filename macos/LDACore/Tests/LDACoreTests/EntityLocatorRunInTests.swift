//
//  EntityLocatorRunInTests.swift
//  LDACoreTests
//
//  EntityLocator.runInOccurrences: where a value is still written although
//  the word-boundary guard refuses to anchor it there. Review protects a
//  listed value at exactly these places, so they must include a mention a
//  footnote digit or a lost space runs into, wrapped or not, and must never
//  include a value's letters inside an ordinary word: protecting "li" inside
//  "compliance" would cut the document's words apart.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class EntityLocatorRunInTests: XCTestCase {

    private func surfaces(_ value: String, in text: String) -> [String] {
        let ns = text as NSString
        return EntityLocator.runInOccurrences(forValue: value, in: text).map { ns.substring(with: $0) }
    }

    // MARK: - Run-in mentions are found

    func testAFootnoteDigitAfterTheNameIsARunIn() {
        let text = "Signed by Jordan Lee2 for Northwind Traders."
        XCTAssertEqual(
            EntityLocator.runInOccurrences(forValue: "Jordan Lee", in: text),
            [NSRange(location: 10, length: 10)]
        )
    }

    func testADigitBeforeTheNameIsARunIn() {
        XCTAssertEqual(surfaces("Acme Corp", in: "Item 3Acme Corp signed."), ["Acme Corp"])
    }

    func testALostSpaceBeforeACapitalIsARunIn() {
        XCTAssertEqual(
            surfaces("Acme Holdings (BVI)", in: "This agreement is made betweenAcme Holdings (BVI) and others."),
            ["Acme Holdings (BVI)"]
        )
    }

    func testALostSpaceBeforeAFollowingCapitalIsARunIn() {
        XCTAssertEqual(surfaces("Jordan Lee", in: "Signed by Jordan LeeCEO of the buyer."), ["Jordan Lee"])
    }

    func testAWrappedMentionIsFoundAsTheDocumentWritesIt() {
        // The exact search sees the first mention, the whitespace variant the
        // second; both are refused at the digit, and both are run-ins.
        let text = "Signed by Jordan Lee1 for X.\nWitness: Jordan\nLee2."
        XCTAssertEqual(surfaces("Jordan Lee", in: text), ["Jordan Lee", "Jordan\nLee"])
    }

    func testACaseVariantIsFoundAsTheDocumentWritesIt() {
        XCTAssertEqual(
            surfaces("Jordan Lee", in: "JORDAN LEE2 signed; Jordan Lee3 witnessed."),
            ["JORDAN LEE", "Jordan Lee"]
        )
    }

    // MARK: - Ordinary words are never returned

    func testAValueInsideOrdinaryWordsIsNotARunIn() {
        let text = "This Agreement is made in compliance with the Limited Liability Act and signed by Mr. Li1."
        XCTAssertEqual(
            surfaces("Li", in: text), ["Li"],
            "only the footnoted surname, never the letters inside compliance, Limited or Liability"
        )
        let ns = text as NSString
        XCTAssertEqual(
            EntityLocator.runInOccurrences(forValue: "Li", in: text),
            [NSRange(location: ns.range(of: "Li1").location, length: 2)]
        )
    }

    func testSameCaseLettersOnEitherSideAreOneWord() {
        XCTAssertTrue(EntityLocator.runInOccurrences(forValue: "Lee", in: "The Leeds office and the fleet.").isEmpty)
        XCTAssertTrue(EntityLocator.runInOccurrences(forValue: "Chan", in: "Heard in the Chancery Division.").isEmpty)
        XCTAssertTrue(EntityLocator.runInOccurrences(forValue: "Hall", in: "The Seller shall deliver.").isEmpty)
        XCTAssertTrue(EntityLocator.runInOccurrences(forValue: "Lee", in: "THE LEEDS OFFICE.").isEmpty)
    }

    func testTwoDigitsAreOneNumber() {
        XCTAssertTrue(
            EntityLocator.runInOccurrences(forValue: "Unit 5", in: "Unit 57, 88 Queensway.").isEmpty,
            "Unit 5 is not written in Unit 57"
        )
    }

    func testADigitOfTheValueAgainstALetterIsOneToken() {
        // A unit suffix or an ordinal continues the number; it is not a
        // footnote marker run into the value.
        XCTAssertTrue(EntityLocator.runInOccurrences(forValue: "Apartment 5", in: "Apartment 5A, 88 Queensway.").isEmpty)
        XCTAssertTrue(EntityLocator.runInOccurrences(forValue: "Floor 5", in: "on the Floor 5th landing").isEmpty)
    }

    // MARK: - One search, two results

    func testAnchoringReturnsTheSpansAndTheRunInsOfOneValue() {
        let text = "Jordan Lee signed; Jordan Lee2 witnessed; Jordan Leeds copied."
        let anchoring = EntityLocator.anchoring(forValue: "Jordan Lee", type: .person, in: text)
        XCTAssertEqual(
            anchoring.spans,
            EntityLocator.spans(forValue: "Jordan Lee", type: .person, in: text),
            "the spans are exactly what spans(forValue:) returns"
        )
        XCTAssertEqual(anchoring.spans.map(\.start), [0])
        XCTAssertEqual(anchoring.runIns, [NSRange(location: 19, length: 10)], "the footnoted mention, never Leeds")
    }

    // MARK: - What the locator anchors is not a run-in

    func testAnAnchoredMentionIsNotReturnedAndAnchoringIsUnchanged() {
        let text = "Jordan Lee signed; Jordan Lee2 witnessed."
        XCTAssertEqual(
            EntityLocator.runInOccurrences(forValue: "Jordan Lee", in: text),
            [NSRange(location: 19, length: 10)],
            "only the refused mention is a run-in"
        )
        XCTAssertEqual(
            EntityLocator.spans(forValue: "Jordan Lee", type: .person, in: text).map(\.start),
            [0],
            "the locator still anchors only the bounded mention"
        )
    }

    func testABlankValueHasNoRunIns() {
        XCTAssertTrue(EntityLocator.runInOccurrences(forValue: "  ", in: "Jordan Lee2").isEmpty)
        XCTAssertTrue(EntityLocator.runInOccurrences(forValue: "Jordan Lee", in: "").isEmpty)
    }
}
