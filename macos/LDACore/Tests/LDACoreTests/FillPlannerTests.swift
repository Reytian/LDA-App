//
//  FillPlannerTests.swift
//  LDACoreTests
//
//  Tests for FillPlanner.plan(blanks:profile:completer:prompts:).
//
//  Coverage:
//    - Synonym table match proposing canonical value and field ID
//    - Normalization: strip "insert "/"date of " prefixes, colon, case folding
//    - Chinese label synonym hit
//    - Ambiguous multi-field key (two directorName fields): proposed with nil pick
//    - No completer leaves unmatched blanks unmatched
//    - Model fallback: single batch, adapted value from row
//    - Model null answer stays unmatched
//    - Model out-of-range field index stays unmatched
//    - Batch splits at modelBatchSize (12) blanks
//    - Throwing completer: batch stays unmatched, no crash, no rethrow
//    - Idempotence: .proposed/.confirmed/.rejected blanks pass through untouched
//    - Second batch local index mapping: blank #13 updated, blank #1 left alone
//    - "name of company" normalization hit (strips "name of ", hits "company" key)
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class FillPlannerTests: XCTestCase {

    // MARK: - Fake completer

    private final class FakeCompleter: TextCompleter {
        var queue: [String]
        var prompts: [String] = []
        init(_ queue: [String]) { self.queue = queue }
        func complete(prompt: String, maxTokens: Int?, stop: [String]) throws -> String {
            prompts.append(prompt)
            return queue.isEmpty ? "[]" : queue.removeFirst()
        }
    }

    private enum FakeError: Error { case boom }

    private final class ThrowingCompleter: TextCompleter {
        func complete(prompt: String, maxTokens: Int?, stop: [String]) throws -> String {
            throw FakeError.boom
        }
    }

    // MARK: - Helpers

    private func profile(_ fields: [ProfileField]) -> CompanyProfile {
        CompanyProfile(
            label: "x",
            fields: fields,
            sourceDocuments: [],
            createdAtISO8601: "2026-06-10T00:00:00Z",
            incomplete: false
        )
    }

    private func field(_ key: ProfileFieldKey, _ value: String) -> ProfileField {
        ProfileField(
            key: key,
            value: value,
            sourceDocument: "cert.pdf",
            sourceSnippet: value,
            snippetVerified: true,
            confidence: 0.9,
            userEdited: false
        )
    }

    private func blank(_ label: String, context: String = "") -> Blank {
        Blank(
            location: .textSpan(start: 0, end: 1),
            label: label,
            context: context,
            proposedFieldID: nil,
            proposedValue: nil,
            status: .unmatched
        )
    }

    // MARK: - Synonym table tests

    func testSynonymMatchProposesCanonicalValue() {
        let companyField = field(.companyName, "Acme Holdings Limited")
        let planned = FillPlanner.plan(
            blanks: [blank("Company Name")],
            profile: profile([companyField]),
            completer: nil
        )
        XCTAssertEqual(planned[0].status, .proposed)
        XCTAssertEqual(planned[0].proposedFieldID, companyField.id)
        XCTAssertEqual(planned[0].proposedValue, "Acme Holdings Limited")
    }

    func testNormalizationStripsInsertAndColonAndCase() {
        let dateField = field(.incorporationDate, "10 June 2026")
        for label in ["Insert Date of Incorporation", "date of incorporation:", "DATE OF INCORPORATION"] {
            let planned = FillPlanner.plan(
                blanks: [blank(label)],
                profile: profile([dateField]),
                completer: nil
            )
            XCTAssertEqual(planned[0].status, .proposed, "label '\(label)' should match")
        }
    }

    func testChineseLabelMatches() {
        let planned = FillPlanner.plan(
            blanks: [blank("公司名称")],
            profile: profile([field(.companyName, "Acme")]),
            completer: nil
        )
        XCTAssertEqual(planned[0].status, .proposed)
    }

    func testAmbiguousMultiFieldKeyProposesWithoutPick() {
        let directors = [
            field(.directorName, "Jane Roe"),
            field(.directorName, "John Doe")
        ]
        let planned = FillPlanner.plan(
            blanks: [blank("Director")],
            profile: profile(directors),
            completer: nil
        )
        XCTAssertEqual(planned[0].status, .proposed)
        XCTAssertNil(planned[0].proposedFieldID)
        XCTAssertNil(planned[0].proposedValue)
    }

    func testNoCompleterLeavesUnlabeledUnmatched() {
        let planned = FillPlanner.plan(
            blanks: [blank("")],
            profile: profile([field(.companyName, "Acme")]),
            completer: nil
        )
        XCTAssertEqual(planned[0].status, .unmatched)
    }

    // MARK: - "name of company" normalization interaction

    func testNameOfCompanyNormalizationHit() {
        // "name of company" -> strip "name of " -> "company" -> hits companyName key
        let companyField = field(.companyName, "Test Corp Ltd")
        let planned = FillPlanner.plan(
            blanks: [blank("name of company")],
            profile: profile([companyField]),
            completer: nil
        )
        XCTAssertEqual(planned[0].status, .proposed)
        XCTAssertEqual(planned[0].proposedFieldID, companyField.id)
        XCTAssertEqual(planned[0].proposedValue, "Test Corp Ltd")
    }

    // MARK: - Model fallback tests

    func testModelFallbackMatchesAndAdaptsValue() {
        let dateField = field(.incorporationDate, "10 June 2026")
        let fake = FakeCompleter(["[{\"blank\": 1, \"field\": 1, \"value\": \"10th\"}]"])
        let planned = FillPlanner.plan(
            blanks: [blank("", context: "this ___ day of June")],
            profile: profile([dateField]),
            completer: fake
        )
        XCTAssertEqual(planned[0].status, .proposed)
        XCTAssertEqual(planned[0].proposedFieldID, dateField.id)
        XCTAssertEqual(planned[0].proposedValue, "10th")
    }

    func testModelNullAnswerStaysUnmatched() {
        let fake = FakeCompleter(["[{\"blank\": 1, \"field\": null, \"value\": null}]"])
        let planned = FillPlanner.plan(
            blanks: [blank("", context: "counterparty name ___")],
            profile: profile([field(.companyName, "Acme")]),
            completer: fake
        )
        XCTAssertEqual(planned[0].status, .unmatched)
    }

    func testModelInvalidFieldIndexStaysUnmatched() {
        let fake = FakeCompleter(["[{\"blank\": 1, \"field\": 99, \"value\": null}]"])
        let planned = FillPlanner.plan(
            blanks: [blank("")],
            profile: profile([field(.companyName, "Acme")]),
            completer: fake
        )
        XCTAssertEqual(planned[0].status, .unmatched)
    }

    func testBatchSplitsAtTwelveBlanks() {
        let blanks = (0..<13).map { blank("", context: "ctx \($0)") }
        let fake = FakeCompleter(["[]", "[]"])
        _ = FillPlanner.plan(
            blanks: blanks,
            profile: profile([field(.companyName, "Acme")]),
            completer: fake
        )
        XCTAssertEqual(fake.prompts.count, 2)
    }

    // MARK: - Additional required tests

    func testThrowingCompleterLeavesAllBlanksUnmatchedNoRethrow() {
        // A completer that always throws must leave blanks unmatched.
        // plan() must not propagate the throw (matching is best-effort).
        let blanks = (0..<3).map { blank("", context: "ctx \($0)") }
        let thrower = ThrowingCompleter()
        // Must not throw out of plan().
        let planned = FillPlanner.plan(
            blanks: blanks,
            profile: profile([field(.companyName, "Acme")]),
            completer: thrower
        )
        XCTAssertEqual(planned.count, 3)
        for b in planned {
            XCTAssertEqual(b.status, .unmatched)
        }
    }

    func testAlreadyProposedConfirmedRejectedPassThroughUntouched() {
        // Blanks that arrive with a non-.unmatched status must be left alone.
        let f = field(.companyName, "Acme")
        let existingID = UUID()
        var proposed = blank("Company Name")
        proposed = Blank(
            id: proposed.id,
            location: proposed.location,
            label: proposed.label,
            context: proposed.context,
            proposedFieldID: existingID,
            proposedValue: "OldValue",
            status: .proposed
        )
        var confirmed = blank("Company Name")
        confirmed = Blank(
            id: confirmed.id,
            location: confirmed.location,
            label: confirmed.label,
            context: confirmed.context,
            proposedFieldID: existingID,
            proposedValue: "ConfirmedValue",
            status: .confirmed
        )
        var rejected = blank("Company Name")
        rejected = Blank(
            id: rejected.id,
            location: rejected.location,
            label: rejected.label,
            context: rejected.context,
            proposedFieldID: existingID,
            proposedValue: "RejectedValue",
            status: .rejected
        )

        let planned = FillPlanner.plan(
            blanks: [proposed, confirmed, rejected],
            profile: profile([f]),
            completer: nil
        )

        XCTAssertEqual(planned[0].status, .proposed)
        XCTAssertEqual(planned[0].proposedFieldID, existingID)
        XCTAssertEqual(planned[0].proposedValue, "OldValue")

        XCTAssertEqual(planned[1].status, .confirmed)
        XCTAssertEqual(planned[1].proposedFieldID, existingID)
        XCTAssertEqual(planned[1].proposedValue, "ConfirmedValue")

        XCTAssertEqual(planned[2].status, .rejected)
        XCTAssertEqual(planned[2].proposedFieldID, existingID)
        XCTAssertEqual(planned[2].proposedValue, "RejectedValue")
    }

    func testSecondBatchLocalIndexMapsToCorrectGlobalBlank() {
        // 13 blanks: first 12 go to batch 1 (all unmatched by nil response),
        // blank #13 (index 12) goes to batch 2. The second batch response
        // {"blank": 1, "field": 1} must update blank at global index 12, not blank at global index 0.
        let profileField = field(.companyName, "BatchCorp")
        let blanks = (0..<13).map { blank("", context: "ctx \($0)") }
        // Batch 1: 12 blanks -> []
        // Batch 2: 1 blank  -> [{"blank": 1, "field": 1, "value": null}]
        let fake = FakeCompleter(["[]", "[{\"blank\": 1, \"field\": 1, \"value\": null}]"])
        let planned = FillPlanner.plan(
            blanks: blanks,
            profile: profile([profileField]),
            completer: fake
        )
        // First 12 blanks should remain unmatched
        for i in 0..<12 {
            XCTAssertEqual(planned[i].status, .unmatched, "blank \(i) should be unmatched")
        }
        // Blank #13 (index 12) should be proposed
        XCTAssertEqual(planned[12].status, .proposed)
        XCTAssertEqual(planned[12].proposedFieldID, profileField.id)
        XCTAssertEqual(planned[12].proposedValue, profileField.value)
    }
}
