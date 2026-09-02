//
//  ManualTypeGuessTests.swift
//  LDACoreTests
//
//  The kind preselected in the Protect chooser is guessed from the selected
//  text: the deterministic engine first (the same rules the scan uses, with a
//  90 percent coverage floor so a span buried in a longer selection does not
//  name the whole selection), then cheap word-shape fallbacks (EMAIL, URL,
//  COMPANY, ADDRESS), and PERSON last because it is the most common manual
//  addition and the safest wrong guess. The guess only preselects; it never
//  applies on its own.
//
//  House rules: English only. Fixture strings may be Chinese. No em-dash or
//  en-dash-as-separator.
//

import XCTest
@testable import LDAUI
import LDACore

final class ManualTypeGuessTests: XCTestCase {

    /// A checksum-valid Chinese resident identity card number.
    private static let validChineseID = "110101199003071233"

    func testDeterministicEngineNamesStructuredSelections() {
        let table: [(String, EntityType)] = [
            (Self.validChineseID, .nationalID),
            ("jane.doe@example.com", .email),
            ("13812345678", .phone),
            ("2024年1月1日", .date),
            ("2026-03-01", .date),
            ("$1,250,000.50", .amount),
            ("https://example.com/contracts/1", .url),
            ("（2024）京0105民初12345号", .caseNumber)
        ]
        for (selection, expected) in table {
            XCTAssertEqual(
                ManualTypeGuess.guess(for: selection), expected,
                "\(selection) should be guessed as \(expected.rawValue)"
            )
        }
    }

    func testAStructuredSpanMustCoverNinetyPercentOfTheSelectionToNameIt() {
        // 18 of 21 UTF-16 units is 85.7 percent: the ID does not name the
        // selection, and the prose around it has no other shape, so PERSON.
        XCTAssertEqual(ManualTypeGuess.guess(for: "ID \(Self.validChineseID)"), .person)
        // Leading and trailing whitespace is trimmed before measuring, so a
        // sloppy drag still lands on the structured kind.
        XCTAssertEqual(ManualTypeGuess.guess(for: "  \(Self.validChineseID)\n"), .nationalID)
        // A tiny bit of trailing punctuation inside the floor still names it.
        XCTAssertEqual(ManualTypeGuess.guess(for: "jane.doe@example.com."), .email)
    }

    func testShapeFallbacksWhenTheEngineIsSilent() {
        let table: [(String, EntityType)] = [
            ("zhang@corp", .email),
            ("www.example-firm.cn", .url),
            ("example.org", .url),
            ("北京字节跳动科技有限公司", .company),
            ("上海某某律师事务所", .company),
            ("Acme Holdings Ltd", .company),
            ("Nordwind GmbH", .company),
            ("Pacific Trading Co.", .company),
            ("北京市朝阳区建国路88号", .address),
            ("12 Baker Street, Floor 3", .address),
            ("Room 1204, Tower B", .address)
        ]
        for (selection, expected) in table {
            XCTAssertEqual(
                ManualTypeGuess.guess(for: selection), expected,
                "\(selection) should be guessed as \(expected.rawValue)"
            )
        }
    }

    func testPersonIsTheFinalFallback() {
        for selection in ["张三", "John Smith", "李四先生", "Marie Curie", "", "   "] {
            XCTAssertEqual(ManualTypeGuess.guess(for: selection), .person, "\(selection)")
        }
    }

    func testASingleAddressMarkerIsNotEnoughForAddress() {
        // One marker character is common in ordinary names and phrases; two are
        // required so a street name in a company title does not flip the guess.
        XCTAssertEqual(ManualTypeGuess.guess(for: "建国路"), .person)
        XCTAssertEqual(ManualTypeGuess.guess(for: "Wall Street"), .person)
        XCTAssertEqual(ManualTypeGuess.guess(for: "建国路88号"), .address)
    }

    func testCompanyMarkersWinOverAddressMarkersInsideACompanyName() {
        // A company name that mentions a district is still a company.
        XCTAssertEqual(ManualTypeGuess.guess(for: "朝阳区建国路物业管理有限公司"), .company)
    }
}
