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

    /// Suites and store keys minted by this test instance, removed in tearDown
    /// so nothing survives the run and nothing shared is touched.
    private var usedSuiteNames: [String] = []
    private var usedStorageKeys: Set<String> = []

    override func tearDownWithError() throws {
        for name in usedSuiteNames {
            UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        }
        usedSuiteNames = []
        // The store seals its blob under "store." + storageKey. A fixed key
        // would be the same Keychain account in every concurrent test process.
        for key in usedStorageKeys {
            LocalDataVault.deleteKey(account: StoreBlobKeys.vaultAccount(key))
        }
        usedStorageKeys = []
        try super.tearDownWithError()
    }

    private func freshDefaults() -> UserDefaults {
        let (defaults, name) = TestNamespace.defaults("learning-store")
        usedSuiteNames.append(name)
        return defaults
    }

    private func freshStorageKey() -> String {
        let key = TestNamespace.storeBaseKey("learning-store")
        usedStorageKeys.insert(key)
        return key
    }

    private func freshStore() -> LearningStore {
        LearningStore(defaults: freshDefaults(), storageKey: freshStorageKey())
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
        let defaults = freshDefaults()
        let storageKey = freshStorageKey()
        let first = LearningStore(defaults: defaults, storageKey: storageKey)
        first.record(accepted: [("Acme Holdings", .company)], rejected: [])

        let second = LearningStore(defaults: defaults, storageKey: storageKey)
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
