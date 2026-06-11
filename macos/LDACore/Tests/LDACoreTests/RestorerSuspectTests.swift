//
//  RestorerSuspectTests.swift
//  LDACoreTests
//
//  Tests for the mangled-placeholder forensics in restore. An external AI may
//  rewrite a placeholder while editing the redacted text: swap the braces for
//  brackets, drop a brace, change case, insert a space, or escape the
//  underscore for Markdown. Restore must never guess a value for those, but it
//  must FLAG them (suspectPlaceholders) so the user can resolve each one. The
//  single deterministic exception is the Markdown-escaped underscore
//  ("{PERSON\_1}"): that is a well-defined encoding of the exact token, so it
//  decodes and restores normally.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class RestorerSuspectTests: XCTestCase {

    /// A mapping with one PERSON and one COMPANY entry, the usual session shape.
    private func makeMapping() -> Mapping {
        let person = MappingEntry(
            token: "{PERSON_1}",
            value: "John Smith",
            type: .person,
            surfaceText: "John Smith",
            aliases: []
        )
        let company = MappingEntry(
            token: "{COMPANY_1}",
            value: "Acme Corp",
            type: .company,
            surfaceText: "Acme Corp",
            aliases: []
        )
        return Mapping(
            entries: [person.token: person, company.token: company],
            createdAtISO8601: "2026-06-11T00:00:00Z",
            sourceFile: "doc.txt"
        )
    }

    // MARK: - Bracket and brace mangling

    func testBracketVariantIsFlaggedNotRestored() {
        let result = Restorer.restore(text: "Dear [PERSON_1], welcome.", mapping: makeMapping())
        XCTAssertEqual(result.text, "Dear [PERSON_1], welcome.")
        XCTAssertEqual(result.restoredCount, 0)
        XCTAssertEqual(result.suspectPlaceholders, ["[PERSON_1]"])
    }

    func testParenthesisAndAngleVariantsAreFlagged() {
        let result = Restorer.restore(
            text: "(PERSON_1) and <COMPANY_1> appear.",
            mapping: makeMapping()
        )
        XCTAssertEqual(result.suspectPlaceholders, ["(PERSON_1)", "<COMPANY_1>"])
        XCTAssertEqual(result.restoredCount, 0)
    }

    func testLostClosingBraceIsFlagged() {
        let result = Restorer.restore(text: "Signed by {PERSON_1 today.", mapping: makeMapping())
        XCTAssertEqual(result.restoredCount, 0)
        XCTAssertEqual(result.suspectPlaceholders, ["{PERSON_1"])
    }

    func testLostOpeningBraceIsFlagged() {
        let result = Restorer.restore(text: "Signed by PERSON_1} today.", mapping: makeMapping())
        XCTAssertEqual(result.restoredCount, 0)
        XCTAssertEqual(result.suspectPlaceholders, ["PERSON_1}"])
    }

    // MARK: - Bare, case, and space mangling

    func testBareTokenExactCaseIsFlagged() {
        let result = Restorer.restore(text: "Hand to PERSON_1 directly.", mapping: makeMapping())
        XCTAssertEqual(result.restoredCount, 0)
        XCTAssertEqual(result.suspectPlaceholders, ["PERSON_1"])
    }

    func testCaseVariantInsideBracesIsFlagged() {
        let result = Restorer.restore(
            text: "By {Person_1} and {company_1}.",
            mapping: makeMapping()
        )
        XCTAssertEqual(result.restoredCount, 0)
        XCTAssertEqual(result.suspectPlaceholders, ["{Person_1}", "{company_1}"])
    }

    func testSpaceVariantsInsideBracesAreFlagged() {
        let result = Restorer.restore(
            text: "By {PERSON 1} and { COMPANY_1 }.",
            mapping: makeMapping()
        )
        XCTAssertEqual(result.restoredCount, 0)
        XCTAssertEqual(result.suspectPlaceholders, ["{PERSON 1}", "{ COMPANY_1 }"])
    }

    // MARK: - Markdown escape decodes deterministically

    func testMarkdownEscapedUnderscoreRestoresNormally() {
        // "{PERSON\_1}" is the exact token with the underscore Markdown-escaped.
        let result = Restorer.restore(
            text: "Dear {PERSON\\_1}, your file is ready.",
            mapping: makeMapping()
        )
        XCTAssertEqual(result.text, "Dear John Smith, your file is ready.")
        XCTAssertEqual(result.restoredCount, 1)
        XCTAssertTrue(result.suspectPlaceholders.isEmpty)
        XCTAssertTrue(result.orphanTokens.isEmpty)
    }

    // MARK: - No false positives

    func testValidTokensAreNotFlagged() {
        let result = Restorer.restore(
            text: "{PERSON_1} of {COMPANY_1}.",
            mapping: makeMapping()
        )
        XCTAssertEqual(result.text, "John Smith of Acme Corp.")
        XCTAssertEqual(result.restoredCount, 2)
        XCTAssertTrue(result.suspectPlaceholders.isEmpty)
    }

    func testUnmappedTokenShapedStringStaysAnOrphanNotASuspect() {
        let result = Restorer.restore(text: "See {PRSON_9} here.", mapping: makeMapping())
        XCTAssertEqual(result.orphanTokens, ["{PRSON_9}"])
        XCTAssertTrue(result.suspectPlaceholders.isEmpty)
    }

    func testOrdinaryProseIsNotFlagged() {
        let result = Restorer.restore(
            text: "The person 1 met in Section 1 of the Companies Act was polite.",
            mapping: makeMapping()
        )
        XCTAssertTrue(result.suspectPlaceholders.isEmpty)
        XCTAssertEqual(result.restoredCount, 0)
    }

    func testUnknownTypeNearMissIsNotFlagged() {
        // FOO is not a type in the mapping, so a bracketed FOO_1 is just text.
        let result = Restorer.restore(text: "Use [FOO_1] as is.", mapping: makeMapping())
        XCTAssertTrue(result.suspectPlaceholders.isEmpty)
    }

    // MARK: - Reporting shape

    func testSuspectsAreDistinctAndInFirstSeenOrder() {
        let result = Restorer.restore(
            text: "[COMPANY_1] then [PERSON_1] then [COMPANY_1] again.",
            mapping: makeMapping()
        )
        XCTAssertEqual(result.suspectPlaceholders, ["[COMPANY_1]", "[PERSON_1]"])
    }

    func testSuspectsDoNotAffectRestoredCountOrText() {
        let result = Restorer.restore(
            text: "{PERSON_1} mailed [COMPANY_1].",
            mapping: makeMapping()
        )
        XCTAssertEqual(result.text, "John Smith mailed [COMPANY_1].")
        XCTAssertEqual(result.restoredCount, 1)
        XCTAssertEqual(result.suspectPlaceholders, ["[COMPANY_1]"])
    }
}
