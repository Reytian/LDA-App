//
//  EntityBulkUpdatePublishTests.swift
//  LDACoreTests
//
//  Review 2026-11-11, T5 (the published-array half). Accepting or rejecting
//  a whole group or type, and recording the export's tokens on the review
//  list, changed the published entities array one element at a time: every
//  element was a separate change notification and a separate re-render of
//  the review pane, which on a long document is thousands of passes for one
//  click. Each operation is now one change.
//
//  The autorelease-pool half of T5 (the model download, model import and PDF
//  OCR loops) is about peak memory and has no assertion here.
//
//  Every value is invented.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Combine
import XCTest
@testable import LDACore
@testable import LDAUI

@MainActor
final class EntityBulkUpdatePublishTests: XCTestCase {

    private func model(withEmails count: Int) -> ReviewModel {
        let model = ReviewModel(modelPath: nil)
        model.useLLM = false
        model.entities = (0..<count).map { index in
            ReviewEntity(
                span: Span(start: index * 20, end: index * 20 + 15, type: .email, text: "p\(index)@example.com",
                           source: .deterministic, confidence: 1, priority: 80),
                accepted: true
            )
        }
        return model
    }

    private func changes(of model: ReviewModel, during operation: () -> Void) -> Int {
        var count = 0
        let subscription = model.$entities.dropFirst().sink { _ in count += 1 }
        operation()
        subscription.cancel()
        return count
    }

    func testRejectingAWholeTypeIsOneChange() {
        let model = model(withEmails: 50)
        XCTAssertEqual(changes(of: model) { model.setAccepted(type: .email, false) }, 1)
        XCTAssertTrue(model.entities.allSatisfy { !$0.accepted })
    }

    func testRejectingAGroupIsOneChange() {
        let model = model(withEmails: 50)
        let ids = Set(model.entities.prefix(30).map(\.id))
        XCTAssertEqual(changes(of: model) { model.setAccepted(ids: ids, false) }, 1)
        XCTAssertEqual(model.entities.filter { !$0.accepted }.count, 30)
    }

    func testClearingTheExportsTokensIsOneChange() {
        // The matter switch cleared every chip token one entity at a time
        // (independent review of T5).
        let model = model(withEmails: 50)
        model.recordExportTokens(Dictionary(uniqueKeysWithValues: model.entities.map { ($0.span.text, "{EMAIL_1}") }))
        XCTAssertEqual(changes(of: model) { model.clearExportTokens() }, 1)
        XCTAssertTrue(model.entities.allSatisfy { $0.token == nil })
    }

    func testRecordingTheExportsTokensIsOneChange() {
        let model = model(withEmails: 50)
        let tokens = Dictionary(uniqueKeysWithValues: model.entities.enumerated().map { ("p\($0.offset)@example.com", "{EMAIL_\($0.offset + 1)}") })
        XCTAssertEqual(changes(of: model) { model.recordExportTokens(tokens) }, 1)
        XCTAssertEqual(model.entities.first?.token, "{EMAIL_1}")
    }
}
