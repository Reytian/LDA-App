//
//  ReviewModelWorkspaceTests.swift
//  LDACoreTests
//
//  Re-applying a workspace's review decisions without re-running detection,
//  and the one thing that can go wrong: offsets measured against text this
//  build no longer produces.
//
//  A redaction tool that applies stale UTF-16 offsets does not fail loudly, it
//  redacts the wrong characters and reports success. The digest turns that into
//  a detected condition, and the relocation path re-finds each value by its
//  exact surface text instead.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore
@testable import LDAUI

@MainActor
final class ReviewModelWorkspaceTests: XCTestCase {

    private func makeModel(text: String) -> ReviewModel {
        let model = ReviewModel(modelPath: nil)
        model.useLLM = false
        model.documentText = text
        return model
    }

    private func span(_ text: String, in document: String, occurrence: Int = 0) -> Span {
        let ns = document as NSString
        var start = 0
        var location = NSNotFound
        for _ in 0 ... occurrence {
            let range = ns.range(
                of: text,
                options: [],
                range: NSRange(location: start, length: ns.length - start)
            )
            location = range.location
            start = range.location + max(range.length, 1)
        }
        return Span(
            start: location,
            end: location + (text as NSString).length,
            type: .company,
            text: text,
            source: .llm,
            confidence: 0.9,
            priority: 50
        )
    }

    // MARK: - Capture

    func testASnapshotCarriesDecisionsAndAssignedReplacements() {
        let text = "Acme Trading Ltd. wrote to Beta GmbH."
        let model = makeModel(text: text)
        model.entities = [
            ReviewEntity(span: span("Acme Trading Ltd.", in: text), accepted: true, token: "{COMPANY_1}"),
            ReviewEntity(span: span("Beta GmbH", in: text), accepted: false, token: nil)
        ]

        let snapshot = model.workspaceSnapshot(documentID: UUID())

        XCTAssertEqual(snapshot.entities.count, 2)
        XCTAssertEqual(snapshot.entities[0].token, "{COMPANY_1}")
        XCTAssertEqual(snapshot.entities[1].accepted, false)
        XCTAssertEqual(snapshot.textDigest, WorkspaceReviewSnapshot.digest(of: text))
    }

    // MARK: - Re-application

    func testMatchingTextIsAppliedByOffsetAndEndsReviewed() {
        let text = "Acme Trading Ltd. wrote to Beta GmbH."
        let source = makeModel(text: text)
        source.entities = [
            ReviewEntity(span: span("Acme Trading Ltd.", in: text), accepted: true, token: "{COMPANY_1}")
        ]
        let snapshot = source.workspaceSnapshot(documentID: UUID())

        let target = makeModel(text: text)
        let result = target.applyWorkspaceSnapshot(snapshot)

        XCTAssertEqual(result, WorkspaceSnapshotApplication(
            appliedCount: 1,
            didRelocate: false,
            droppedCount: 0
        ))
        XCTAssertEqual(target.entities.first?.span, source.entities.first?.span)
        XCTAssertEqual(target.entities.first?.id, source.entities.first?.id)
        XCTAssertEqual(target.entities.first?.token, "{COMPANY_1}")
        // Reviewed state, not merely populated: the receiving Mac may have no
        // detection model, so export must be available without a pass.
        XCTAssertTrue(target.exportAvailability.isAvailable)
        XCTAssertNil(target.selectedGroupID)
    }

    func testDriftedTextIsRelocatedByExactSurfaceNotByOffset() {
        let original = "Acme Trading Ltd. wrote to Beta GmbH."
        let source = makeModel(text: original)
        source.entities = [
            ReviewEntity(span: span("Acme Trading Ltd.", in: original), accepted: true, token: nil),
            ReviewEntity(span: span("Beta GmbH", in: original), accepted: false, token: nil)
        ]
        let snapshot = source.workspaceSnapshot(documentID: UUID())

        // A newer importer that emits a leading heading shifts every offset.
        let drifted = "NOTICE\n\n" + original
        let target = makeModel(text: drifted)
        let result = target.applyWorkspaceSnapshot(snapshot)

        XCTAssertTrue(result.didRelocate)
        XCTAssertEqual(result.appliedCount, 2)
        XCTAssertEqual(result.droppedCount, 0)
        let ns = drifted as NSString
        for entity in target.entities {
            XCTAssertEqual(
                ns.substring(with: NSRange(
                    location: entity.span.start,
                    length: entity.span.end - entity.span.start
                )),
                entity.span.text,
                "a relocated span does not cover its own value"
            )
        }
        XCTAssertEqual(
            target.entities.first { $0.span.text == "Beta GmbH" }?.accepted,
            false,
            "a decision changed while relocating"
        )
    }

    func testRelocationKeepsOneRangePerRecordedOccurrence() {
        let original = "Acme Trading Ltd. billed Acme Trading Ltd. twice."
        let source = makeModel(text: original)
        source.entities = [
            ReviewEntity(span: span("Acme Trading Ltd.", in: original, occurrence: 0), accepted: true),
            ReviewEntity(span: span("Acme Trading Ltd.", in: original, occurrence: 1), accepted: true)
        ]
        let snapshot = source.workspaceSnapshot(documentID: UUID())

        let target = makeModel(text: "Header. " + original)
        let result = target.applyWorkspaceSnapshot(snapshot)

        XCTAssertEqual(result.appliedCount, 2)
        XCTAssertEqual(Set(target.entities.map(\.span.start)).count, 2,
                       "two occurrences collapsed onto one range")
    }

    func testAValueThatNoLongerAppearsIsDroppedAndCounted() {
        let original = "Acme Trading Ltd. wrote to Beta GmbH."
        let source = makeModel(text: original)
        source.entities = [
            ReviewEntity(span: span("Acme Trading Ltd.", in: original), accepted: true),
            ReviewEntity(span: span("Beta GmbH", in: original), accepted: true)
        ]
        let snapshot = source.workspaceSnapshot(documentID: UUID())

        let target = makeModel(text: "Acme Trading Ltd. wrote to nobody.")
        let result = target.applyWorkspaceSnapshot(snapshot)

        // Dropping is reported, never silent: an unfound value is a value that
        // will NOT be redacted, which the user has to be told about.
        XCTAssertEqual(result.appliedCount, 1)
        XCTAssertEqual(result.droppedCount, 1)
        XCTAssertTrue(result.didRelocate)
        XCTAssertEqual(target.status, .imported)
        XCTAssertFalse(
            target.exportAvailability.isAvailable,
            "a workspace that lost a protected value must require another scan"
        )
    }
}
