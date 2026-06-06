//
//  LearningStoreTests.swift
//  Verifies the on-device learning loop: accepted fuzzy values become auto-redact
//  patterns, rejected values become suppressions, ties stay neutral, and the
//  state persists.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import XCTest
@testable import LDACore
@testable import LDAUI

@MainActor
final class LearningStoreTests: XCTestCase {

    private func freshStore() -> LearningStore {
        let suite = "lda.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return LearningStore(defaults: defaults, storageKey: "k")
    }

    func testAcceptedFuzzyValueBecomesRedactPattern() {
        let store = freshStore()
        store.record(accepted: [("Northwind Trading", .company)], rejected: [])

        let patterns = store.redactPatterns
        XCTAssertEqual(patterns.map { $0.text }, ["Northwind Trading"])
        XCTAssertEqual(patterns.first?.type, .company)
        XCTAssertTrue(store.suppressKeys.isEmpty)
    }

    func testRejectedValueBecomesSuppressKey() {
        let store = freshStore()
        store.record(accepted: [], rejected: [("Schedule A", .company)])

        XCTAssertTrue(store.redactPatterns.isEmpty)
        XCTAssertTrue(store.suppressKeys.contains(LearningStore.key(value: "Schedule A", type: .company)))
    }

    func testNetDecisionFollowsTheMajority() {
        let store = freshStore()
        // Rejected twice, accepted once: net suppress.
        store.record(accepted: [], rejected: [("Maybe Co", .company)])
        store.record(accepted: [("Maybe Co", .company)], rejected: [])
        store.record(accepted: [], rejected: [("Maybe Co", .company)])

        XCTAssertTrue(store.suppressKeys.contains(LearningStore.key(value: "Maybe Co", type: .company)))
        XCTAssertTrue(store.redactPatterns.isEmpty)
    }

    func testStructuredAcceptsAreNotLearnedForRedaction() {
        let store = freshStore()
        // Accepting an email should not create a redact pattern (regex already
        // catches it); only PERSON/COMPANY/ADDRESS are learned for redaction.
        store.record(accepted: [("john@acme.com", .email)], rejected: [])
        XCTAssertTrue(store.redactPatterns.isEmpty)
    }

    func testPersistsAcrossInstances() {
        let suite = "lda.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let first = LearningStore(defaults: defaults, storageKey: "k")
        first.record(accepted: [("Acme Holdings", .company)], rejected: [])

        let second = LearningStore(defaults: defaults, storageKey: "k")
        XCTAssertEqual(second.redactPatterns.map { $0.text }, ["Acme Holdings"])
    }

    func testForgetRemovesATerm() {
        let store = freshStore()
        store.record(accepted: [("Acme", .company)], rejected: [])
        let id = LearningStore.key(value: "Acme", type: .company)
        XCTAssertFalse(store.redactPatterns.isEmpty)
        store.forget(id)
        XCTAssertTrue(store.redactPatterns.isEmpty)
    }
}
