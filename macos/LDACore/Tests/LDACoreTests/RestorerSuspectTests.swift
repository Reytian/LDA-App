//
//  RestorerSuspectTests.swift
//  LDACoreTests
//
//  Tests for the mangled-placeholder forensics in restore. An external AI may
//  rewrite a placeholder while editing the redacted text: swap the braces for
//  brackets, drop a brace, change case, insert a space, drift the separators
//  of a known TYPE name (insert an underscore, space, or hyphen, or delete
//  the separator), or escape the underscore for Markdown. Restore must never
//  guess a value for those, but it
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

    /// A mapping whose entry uses a multi-word type: the raw type string
    /// "BANK_ACCOUNT" sanitizes to the token TYPE "BANKACCOUNT", which makes it
    /// the natural victim of an AI reintroducing the underscore.
    private func makeBankMapping() -> Mapping {
        let bank = MappingEntry(
            token: "{BANKACCOUNT_1}",
            value: "6222 0202 1234 5678",
            type: .bankAccount,
            surfaceText: "6222 0202 1234 5678",
            aliases: []
        )
        return Mapping(
            entries: [bank.token: bank],
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

    // MARK: - Separator drift in the TYPE name

    func testUnderscoreInsertedTypeIsFlaggedNotRestored() {
        // The live-observed mutation: an AI rewrote "{BANKACCOUNT_1}" as
        // "{BANK_ACCOUNT_1}". That string fails the canonical grammar, so it is
        // neither restored nor an orphan; the forensics scan must flag it.
        let result = Restorer.restore(
            text: "Wire the funds to {BANK_ACCOUNT_1} today.",
            mapping: makeBankMapping()
        )
        XCTAssertEqual(result.text, "Wire the funds to {BANK_ACCOUNT_1} today.")
        XCTAssertEqual(result.restoredCount, 0)
        XCTAssertTrue(result.orphanTokens.isEmpty)
        XCTAssertEqual(result.suspectPlaceholders, ["{BANK_ACCOUNT_1}"])
    }

    func testUnderscoreDeletedSeparatorIsFlagged() {
        // The reverse drift: the separator underscore deleted, "{PERSON1}".
        let result = Restorer.restore(text: "Send to {PERSON1} now.", mapping: makeMapping())
        XCTAssertEqual(result.restoredCount, 0)
        XCTAssertEqual(result.suspectPlaceholders, ["{PERSON1}"])
    }

    func testDoubledSeparatorUnderscoreIsFlagged() {
        let result = Restorer.restore(text: "By {PERSON__1} today.", mapping: makeMapping())
        XCTAssertEqual(result.restoredCount, 0)
        XCTAssertEqual(result.suspectPlaceholders, ["{PERSON__1}"])
    }

    func testMultipleInsertedUnderscoresAreFlagged() {
        let result = Restorer.restore(
            text: "Use {B_ANK_ACC_OUNT_1} as before.",
            mapping: makeBankMapping()
        )
        XCTAssertEqual(result.restoredCount, 0)
        XCTAssertEqual(result.suspectPlaceholders, ["{B_ANK_ACC_OUNT_1}"])
    }

    func testLowercaseUnderscoreInsertedVariantIsFlagged() {
        // Case damage combined with underscore drift, matching the existing
        // case-forgiving brace-pair behavior.
        let result = Restorer.restore(
            text: "Wire to {bank_account_1} today.",
            mapping: makeBankMapping()
        )
        XCTAssertEqual(result.restoredCount, 0)
        XCTAssertEqual(result.suspectPlaceholders, ["{bank_account_1}"])
    }

    func testSpacePaddedUnderscoreInsertedVariantIsFlagged() {
        // Space padding combined with underscore drift, matching the existing
        // space-forgiving brace-pair behavior.
        let result = Restorer.restore(
            text: "Wire to { BANK_ACCOUNT_1 } today.",
            mapping: makeBankMapping()
        )
        XCTAssertEqual(result.restoredCount, 0)
        XCTAssertEqual(result.suspectPlaceholders, ["{ BANK_ACCOUNT_1 }"])
    }

    func testSpaceSeparatedTypeWordsAreFlagged() {
        // The AI may prettify the type with a space instead of an underscore.
        let result = Restorer.restore(
            text: "Wire to {BANK ACCOUNT_1} today.",
            mapping: makeBankMapping()
        )
        XCTAssertEqual(result.restoredCount, 0)
        XCTAssertEqual(result.suspectPlaceholders, ["{BANK ACCOUNT_1}"])
    }

    func testHyphenSeparatedTypeWordsAreFlagged() {
        let result = Restorer.restore(
            text: "Wire to {BANK-ACCOUNT_1} today.",
            mapping: makeBankMapping()
        )
        XCTAssertEqual(result.restoredCount, 0)
        XCTAssertEqual(result.suspectPlaceholders, ["{BANK-ACCOUNT_1}"])
    }

    func testBracketDelimitedUnderscoreDriftIsFlagged() {
        // Two mutations at once: brackets for braces AND an inserted
        // underscore. The per-type bracket pattern needs the literal type
        // spelling, so only the drift pass can catch this.
        let result = Restorer.restore(
            text: "Wire to [BANK_ACCOUNT_1] today.",
            mapping: makeBankMapping()
        )
        XCTAssertEqual(result.restoredCount, 0)
        XCTAssertEqual(result.suspectPlaceholders, ["[BANK_ACCOUNT_1]"])
    }

    func testGenericBraceTemplateWithKnownTypeNameIsFlagged() {
        // Documented tradeoff: an unrelated curly-brace template field that
        // collapses to a known type ("{Company1}") IS flagged. Over-flagging
        // is the safe failure mode; the user dismisses false positives, while
        // a silent drop would leak a broken placeholder into the document.
        let result = Restorer.restore(text: "Fill {Company1} here.", mapping: makeMapping())
        XCTAssertEqual(result.suspectPlaceholders, ["{Company1}"])
    }

    func testForensicsScanStaysFastOnLongWhitespaceRuns() {
        // Regression guard against quadratic regex backtracking: a stray
        // delimiter followed by a long whitespace run (blank-line gaps and
        // column padding are common in PDF-extracted legal text) must not
        // stall the scan. The three adversarial segments below each pair a
        // scan anchor with a 6000-char whitespace run and no digits.
        let gap = String(repeating: " ", count: 6000)
        let text = "{BANK" + gap + "x (BANKACCOUNT" + gap + "x {BANKACCOUNT" + gap + "x"
        let started = Date()
        let result = Restorer.restore(text: text, mapping: makeBankMapping())
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertTrue(result.suspectPlaceholders.isEmpty)
        XCTAssertLessThan(elapsed, 1.5)
    }

    func testUnderscoreVariantOfUnknownTypeIsNotFlagged() {
        // BANKSTATEMENT is not a type in the mapping, so the collapsed
        // candidate does not match a known type and must stay unflagged.
        let result = Restorer.restore(
            text: "See {BANK_STATEMENT_1} here.",
            mapping: makeBankMapping()
        )
        XCTAssertTrue(result.suspectPlaceholders.isEmpty)
        XCTAssertEqual(result.restoredCount, 0)
    }

    func testUnderscoreVariantAlongsideExactTokenRestoresTheExact() {
        let result = Restorer.restore(
            text: "{BANKACCOUNT_1} and {BANK_ACCOUNT_1}.",
            mapping: makeBankMapping()
        )
        XCTAssertEqual(result.text, "6222 0202 1234 5678 and {BANK_ACCOUNT_1}.")
        XCTAssertEqual(result.restoredCount, 1)
        XCTAssertEqual(result.suspectPlaceholders, ["{BANK_ACCOUNT_1}"])
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
