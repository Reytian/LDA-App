//
//  PortabilityTests.swift
//  Verifies that a vocabulary + learned profile round-trips through JSON and that
//  importing merges into the local stores (additive, no overwrite).
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import XCTest
@testable import LDACore
@testable import LDAUI

@MainActor
final class PortabilityTests: XCTestCase {

    /// UserDefaults suites and store keys minted by this test instance, so
    /// tearDown removes exactly what the test created and nothing shared.
    private var usedSuiteNames: [String] = []
    private var usedStorageKeys: Set<String> = []

    override func tearDownWithError() throws {
        for name in usedSuiteNames {
            UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        }
        usedSuiteNames = []
        // These stores seal their blob under "store." + storageKey. Dropping
        // the key keeps the developer keychain free of test litter.
        for key in usedStorageKeys {
            LocalDataVault.deleteKey(account: StoreBlobKeys.vaultAccount(key))
        }
        usedStorageKeys = []
        try super.tearDownWithError()
    }

    private func emptyDefaults() -> UserDefaults {
        let (defaults, name) = TestNamespace.defaults("portability")
        usedSuiteNames.append(name)
        return defaults
    }

    /// A process-unique storage key, tracked for cleanup. A fixed key would be
    /// the same vault account in every concurrent test process.
    private func freshStorageKey() -> String {
        let key = TestNamespace.storeBaseKey("portability")
        usedStorageKeys.insert(key)
        return key
    }

    func testProfileRoundTripsThroughJSON() throws {
        let profile = VocabularyProfile(
            exportedAtISO8601: "2026-06-06T00:00:00Z",
            patterns: [CustomPattern(text: #"M-\d{5}"#, type: .unknown, isRegex: true)],
            learned: [LearnedTerm(id: "COMPANY|acme", value: "Acme", type: .company, acceptCount: 3, rejectCount: 1)]
        )
        let data = try Portability.encode(profile)
        let decoded = try Portability.decode(data)
        XCTAssertEqual(decoded, profile)
    }

    func testImportMergesVocabularySkippingDuplicates() {
        let store = CustomPatternStore(defaults: emptyDefaults(), storageKey: freshStorageKey())
        store.patterns = [CustomPattern(text: "Acme", type: .company)]

        let added = store.merge([
            CustomPattern(text: "Acme", type: .company),        // duplicate, skipped
            CustomPattern(text: "Northwind", type: .company),   // new
            CustomPattern(text: #"M-\d{5}"#, type: .unknown, isRegex: true) // new
        ])

        XCTAssertEqual(added, 2)
        XCTAssertEqual(store.patterns.count, 3)
    }

    func testImportMergesLearnedBySummingCounts() {
        let store = LearningStore(defaults: emptyDefaults(), storageKey: freshStorageKey())
        store.record(accepted: [("Acme", .company)], rejected: [])  // accept 1

        store.merge([LearnedTerm(id: LearningStore.key(value: "Acme", type: .company),
                                 value: "Acme", type: .company, acceptCount: 4, rejectCount: 0)])

        // 1 + 4 accepts, still net redact.
        let term = store.sortedTerms.first { $0.value == "Acme" }
        XCTAssertEqual(term?.acceptCount, 5)
        XCTAssertEqual(store.redactPatterns.map { $0.text }, ["Acme"])
    }

    func testExportThenImportOnFreshDeviceReproducesState() {
        // Device A
        let patternsA = CustomPatternStore(defaults: emptyDefaults(), storageKey: freshStorageKey())
        patternsA.patterns = [CustomPattern(text: "Project Titan", type: .company)]
        let learningA = LearningStore(defaults: emptyDefaults(), storageKey: freshStorageKey())
        learningA.record(accepted: [("Jane Roe", .person)], rejected: [("Schedule B", .company)])

        let profile = VocabularyProfile(
            exportedAtISO8601: "2026-06-06T00:00:00Z",
            patterns: patternsA.patterns,
            learned: learningA.allTerms
        )

        // Device B (fresh)
        let patternsB = CustomPatternStore(defaults: emptyDefaults(), storageKey: freshStorageKey())
        let learningB = LearningStore(defaults: emptyDefaults(), storageKey: freshStorageKey())
        patternsB.merge(profile.patterns)
        learningB.merge(profile.learned)

        XCTAssertEqual(patternsB.activePatterns.map { $0.text }, ["Project Titan"])
        XCTAssertEqual(learningB.redactPatterns.map { $0.text }, ["Jane Roe"])
        XCTAssertTrue(learningB.suppressKeys.contains(LearningStore.key(value: "Schedule B", type: .company)))
    }
}
