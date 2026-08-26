//
//  TokenSubstitutionTests.swift
//  LDACoreTests
//
//  The shared token scan that Restorer and DocxRedactor both run through. Its
//  two invariants are safety properties, not conveniences: a substituted value
//  is never rescanned, and an unmapped token is left verbatim rather than
//  blanked or guessed at.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class TokenSubstitutionTests: XCTestCase {

    private var regex: NSRegularExpression!

    override func setUpWithError() throws {
        try super.setUpWithError()
        regex = try NSRegularExpression(pattern: TokenGrammar.placeholderPattern)
    }

    private func substitute(
        _ text: String,
        _ table: [String: String]
    ) -> TokenSubstitution.Outcome {
        TokenSubstitution.substitute(in: text, matching: regex) { table[$0] }
    }

    // MARK: - Basic substitution

    func testReplacesAKnownToken() {
        let outcome = substitute(
            "Signed by {PERSON_1} on {DATE_1}.",
            ["{PERSON_1}": "Jane Aoife Smith", "{DATE_1}": "15 January 2024"]
        )

        XCTAssertEqual(outcome.text, "Signed by Jane Aoife Smith on 15 January 2024.")
        XCTAssertEqual(outcome.substitutedCount, 2)
        XCTAssertTrue(outcome.unmappedTokens.isEmpty)
    }

    func testTextWithNoTokensIsReturnedUnchanged() {
        let outcome = substitute("An ordinary clause with no placeholders.", [:])
        XCTAssertEqual(outcome.text, "An ordinary clause with no placeholders.")
        XCTAssertEqual(outcome.substitutedCount, 0)
    }

    func testTextAroundTokensIsPreservedExactly() {
        let outcome = substitute("  a\t{PERSON_1}\nb  ", ["{PERSON_1}": "X"])
        XCTAssertEqual(outcome.text, "  a\tX\nb  ", "surrounding whitespace must survive verbatim")
    }

    // MARK: - Unmapped tokens

    func testAnUnmappedTokenIsLeftVerbatim() {
        // Blanking it would delete content; guessing at it would invent content.
        // Leaving it and reporting it is the only safe option.
        let outcome = substitute("Signed by {PERSON_9}.", [:])

        XCTAssertEqual(outcome.text, "Signed by {PERSON_9}.")
        XCTAssertEqual(outcome.substitutedCount, 0)
        XCTAssertEqual(outcome.unmappedTokens, ["{PERSON_9}"])
    }

    func testUnmappedTokensAreDeduplicatedInFirstSeenOrder() {
        let outcome = substitute("{B_2} {A_1} {B_2} {A_1} {C_3}", [:])
        XCTAssertEqual(outcome.unmappedTokens, ["{B_2}", "{A_1}", "{C_3}"])
    }

    func testKnownAndUnknownTokensMix() {
        let outcome = substitute(
            "{PERSON_1} and {PERSON_2}",
            ["{PERSON_1}": "Jane Aoife Smith"]
        )
        XCTAssertEqual(outcome.text, "Jane Aoife Smith and {PERSON_2}")
        XCTAssertEqual(outcome.substitutedCount, 1)
        XCTAssertEqual(outcome.unmappedTokens, ["{PERSON_2}"])
    }

    // MARK: - No rescanning

    func testASubstitutedValueIsNotRescanned() {
        // A restored value can itself look like a placeholder, for instance a
        // contract that really does contain "{AMOUNT_1}" as a defined term. It
        // must be emitted once, not substituted again.
        let outcome = substitute(
            "Pay {AMOUNT_1}.",
            ["{AMOUNT_1}": "{AMOUNT_2}", "{AMOUNT_2}": "should never appear"]
        )

        XCTAssertEqual(outcome.text, "Pay {AMOUNT_2}.")
        XCTAssertEqual(outcome.substitutedCount, 1)
        XCTAssertFalse(
            outcome.text.contains("should never appear"),
            "the emitted value must not be rescanned for further substitution"
        )
    }

    // MARK: - Shared behavior across surfaces

    func testTheRestorerAgreesWithTheSharedScan() {
        // Restorer and DocxRedactor both go through this scan, so the same
        // input has to produce the same substitution decisions on either
        // surface. Compare the shared scan against the real restore path.
        let entry = MappingEntry(
            token: "{PERSON_1}",
            value: "Jane Aoife Smith",
            type: .person,
            surfaceText: "Jane Aoife Smith",
            aliases: []
        )
        let mapping = Mapping(
            entries: ["{PERSON_1}": entry],
            createdAtISO8601: "2026-08-27T00:00:00Z",
            sourceFile: "brief.txt"
        )

        let restored = Restorer.restore(text: "For {PERSON_1} and {PERSON_7}.", mapping: mapping)
        let shared = substitute(
            "For {PERSON_1} and {PERSON_7}.",
            ["{PERSON_1}": "Jane Aoife Smith"]
        )

        XCTAssertEqual(restored.text, shared.text)
        XCTAssertEqual(restored.restoredCount, shared.substitutedCount)
        XCTAssertEqual(restored.orphanTokens, shared.unmappedTokens)
    }
}
