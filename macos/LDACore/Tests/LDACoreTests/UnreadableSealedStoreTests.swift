//
//  UnreadableSealedStoreTests.swift
//  LDACoreTests
//
//  Review 2026-11-11, T4. An unreadable sealed blob loaded as empty and the
//  next save overwrote it: a Keychain refused once at launch, or a key that
//  went missing, cost the user the whole custom vocabulary or every learned
//  term the moment anything was added.
//
//  A store whose sealed blob exists but will not open now keeps it as it is:
//  it runs on what it holds in memory for the session and writes nothing
//  over the blob. A store that reads its blob saves as before. What a single
//  "keep visible" does to later documents (owner decision 6) is unchanged.
//
//  Hermetic: the vault is a stand-in (no Keychain item is read or created)
//  and the defaults are a per-test suite. Every value is invented.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore
@testable import LDAUI

@MainActor
final class UnreadableSealedStoreTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = TestNamespace.suiteName("unreadable-sealed-store")
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// Counts what a vault was asked to seal.
    private final class SealCounter: @unchecked Sendable {
        var count = 0
    }

    /// A vault whose key cannot be had: opening fails, sealing is counted.
    private func refusingVault(_ counter: SealCounter) -> StoreVault {
        StoreVault(
            open: { _, _ in throw DocumentIOError.keychainError(-25300) },
            seal: { data, _ in counter.count += 1; return data }
        )
    }

    /// A vault that "seals" by reversing the bytes, so a round trip works.
    private func workingVault(_ counter: SealCounter) -> StoreVault {
        StoreVault(
            open: { data, _ in Data(data.reversed()) },
            seal: { data, _ in counter.count += 1; return Data(data.reversed()) }
        )
    }

    // MARK: - Custom vocabulary

    func testAnUnreadableVocabularyBlobIsNotOverwritten() {
        let key = TestNamespace.storeBaseKey("vocabulary-unreadable")
        let blob = Data("sealed under a key this run cannot read".utf8)
        defaults.set(blob, forKey: StoreBlobKeys.sealed(key))
        let counter = SealCounter()

        let store = CustomPatternStore(defaults: defaults, storageKey: key, vault: refusingVault(counter))
        XCTAssertTrue(store.patterns.isEmpty)
        store.add()
        store.patterns[0].text = "Willowcrest"

        XCTAssertEqual(defaults.data(forKey: StoreBlobKeys.sealed(key)), blob, "the blob is left as it was")
        XCTAssertEqual(counter.count, 0)
        XCTAssertEqual(store.patterns.map(\.text), ["Willowcrest"], "the session still has the term")
    }

    func testAReadableVocabularyBlobStillSaves() {
        let key = TestNamespace.storeBaseKey("vocabulary-readable")
        let counter = SealCounter()
        let first = CustomPatternStore(defaults: defaults, storageKey: key, vault: workingVault(counter))
        first.add()
        first.patterns[0].text = "Willowcrest"

        let second = CustomPatternStore(defaults: defaults, storageKey: key, vault: workingVault(counter))
        XCTAssertEqual(second.patterns.map(\.text), ["Willowcrest"])
        second.add()
        XCTAssertGreaterThan(counter.count, 0)
    }

    // MARK: - Learned terms

    func testAnUnreadableLearnedTermsBlobIsNotOverwritten() {
        let key = TestNamespace.storeBaseKey("learned-unreadable")
        let blob = Data("sealed under a key this run cannot read".utf8)
        defaults.set(blob, forKey: StoreBlobKeys.sealed(key))
        let counter = SealCounter()

        let store = LearningStore(defaults: defaults, storageKey: key, vault: refusingVault(counter))
        XCTAssertTrue(store.terms.isEmpty)
        store.record(accepted: [(value: "Jordan Ellis", type: .person)], rejected: [])

        XCTAssertEqual(defaults.data(forKey: StoreBlobKeys.sealed(key)), blob, "the blob is left as it was")
        XCTAssertEqual(counter.count, 0)
        XCTAssertEqual(store.terms.count, 1, "the session still learns")
    }

    func testAReadableLearnedTermsBlobStillSaves() {
        let key = TestNamespace.storeBaseKey("learned-readable")
        let counter = SealCounter()
        let first = LearningStore(defaults: defaults, storageKey: key, vault: workingVault(counter))
        first.record(accepted: [(value: "Jordan Ellis", type: .person)], rejected: [])

        let second = LearningStore(defaults: defaults, storageKey: key, vault: workingVault(counter))
        XCTAssertEqual(second.terms.count, 1)
    }
}
