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

    private func emptyDefaults() -> UserDefaults {
        UserDefaults(suiteName: "lda.test.\(UUID().uuidString)")!
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
        let store = CustomPatternStore(defaults: emptyDefaults(), storageKey: "k")
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
        let store = LearningStore(defaults: emptyDefaults(), storageKey: "k")
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
        let patternsA = CustomPatternStore(defaults: emptyDefaults(), storageKey: "k")
        patternsA.patterns = [CustomPattern(text: "Project Titan", type: .company)]
        let learningA = LearningStore(defaults: emptyDefaults(), storageKey: "k")
        learningA.record(accepted: [("Jane Roe", .person)], rejected: [("Schedule B", .company)])

        let profile = VocabularyProfile(
            exportedAtISO8601: "2026-06-06T00:00:00Z",
            patterns: patternsA.patterns,
            learned: learningA.allTerms
        )

        // Device B (fresh)
        let patternsB = CustomPatternStore(defaults: emptyDefaults(), storageKey: "k")
        let learningB = LearningStore(defaults: emptyDefaults(), storageKey: "k")
        patternsB.merge(profile.patterns)
        learningB.merge(profile.learned)

        XCTAssertEqual(patternsB.activePatterns.map { $0.text }, ["Project Titan"])
        XCTAssertEqual(learningB.redactPatterns.map { $0.text }, ["Jane Roe"])
        XCTAssertTrue(learningB.suppressKeys.contains(LearningStore.key(value: "Schedule B", type: .company)))
    }
}
