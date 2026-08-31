//
//  ScopedStoreTests.swift
//  LDACoreTests
//
//  Matter-scoped black/whitelists at the store layer. A rule learned while
//  working matter A (labor arbitration: suppress a term) must not apply under
//  matter B (IPO diligence: keep the same term), while global rules apply
//  everywhere. The scoped facades read the union of the global and matter
//  layers with the matter layer winning conflicts, and writes land in an
//  explicitly chosen layer (default global, the pre-scoping behavior).
//
//  Privacy invariants pinned here: matter storage keys embed only the stable
//  random matter id, never a label; the existing global key and blob stay
//  byte-identical; deleting a matter removes exactly that matter's blobs.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore
@testable import LDAUI

final class ScopedStoreTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var usedStorageKeys: Set<String> = []

    /// Test-only base keys so no test ever touches the production vault
    /// accounts of the developer machine.
    private let learnedBase = "scoped.test.learnedTerms"
    private let patternBase = "scoped.test.customPatterns"

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "ScopedStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        usedStorageKeys = []
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        // Drop only the vault keys these tests minted; every tracked storage
        // key is test-unique or matter-unique, never a shared account.
        for key in usedStorageKeys {
            LocalDataVault.deleteKey(account: "store.\(key)")
        }
        usedStorageKeys = []
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    @MainActor
    private func learning(_ scope: StoreScope) -> LearningStore {
        usedStorageKeys.insert(scope.storageKey(base: learnedBase))
        return LearningStore(scope: scope, defaults: defaults, baseKey: learnedBase)
    }

    @MainActor
    private func patterns(_ scope: StoreScope) -> CustomPatternStore {
        usedStorageKeys.insert(scope.storageKey(base: patternBase))
        return CustomPatternStore(scope: scope, defaults: defaults, baseKey: patternBase)
    }

    // MARK: - Scope key derivation

    func testGlobalScopeKeepsTheBaseKeyByteForByte() {
        XCTAssertEqual(StoreScope.global.storageKey(base: "com.example.key"), "com.example.key")

        let id = UUID()
        XCTAssertEqual(
            StoreScope.matter(id: id).storageKey(base: "com.example.key"),
            "com.example.key.matter.\(id.uuidString)"
        )
    }

    // MARK: - Layer isolation

    @MainActor
    func testMatterSuppressionIsInactiveUnderOtherScopes() {
        let global = learning(.global)
        let facadeA = ScopedLearningStore(global: global, matter: learning(.matter(id: UUID())))
        let facadeB = ScopedLearningStore(global: global, matter: learning(.matter(id: UUID())))
        let globalOnly = ScopedLearningStore(global: global)

        XCTAssertTrue(facadeA.record(
            accepted: [], rejected: [("Schedule A", .company)], to: .matter
        ))

        let key = LearningStore.key(value: "Schedule A", type: .company)
        XCTAssertTrue(facadeA.suppressKeys.contains(key))
        XCTAssertFalse(facadeB.suppressKeys.contains(key), "matter A's rule leaked into matter B")
        XCTAssertFalse(globalOnly.suppressKeys.contains(key), "matter A's rule leaked into the global view")
        XCTAssertTrue(global.suppressKeys.isEmpty, "a matter-targeted write landed in the global layer")
    }

    @MainActor
    func testGlobalSuppressionAppliesUnderEveryScope() {
        let global = learning(.global)
        let facadeA = ScopedLearningStore(global: global, matter: learning(.matter(id: UUID())))
        let facadeB = ScopedLearningStore(global: global, matter: learning(.matter(id: UUID())))
        let globalOnly = ScopedLearningStore(global: global)

        // No target argument: the default must write the global layer, which
        // preserves the pre-scoping behavior of every existing call site.
        facadeA.record(accepted: [], rejected: [("Exhibit 12", .company)])

        let key = LearningStore.key(value: "Exhibit 12", type: .company)
        XCTAssertTrue(global.suppressKeys.contains(key))
        XCTAssertTrue(facadeA.suppressKeys.contains(key))
        XCTAssertTrue(facadeB.suppressKeys.contains(key))
        XCTAssertTrue(globalOnly.suppressKeys.contains(key))
        XCTAssertEqual(globalOnly.suppressKeys, global.suppressKeys)
    }

    // MARK: - Conflicts: the matter layer wins

    @MainActor
    func testMatterAcceptanceOverridesGlobalSuppression() {
        let global = learning(.global)
        let matterA = learning(.matter(id: UUID()))
        let facadeA = ScopedLearningStore(global: global, matter: matterA)
        let facadeB = ScopedLearningStore(global: global, matter: learning(.matter(id: UUID())))

        global.record(accepted: [], rejected: [("Northwind", .company)])
        matterA.record(accepted: [("Northwind", .company)], rejected: [])

        let key = LearningStore.key(value: "Northwind", type: .company)
        XCTAssertFalse(facadeA.suppressKeys.contains(key), "matter acceptance must beat global suppression")
        XCTAssertEqual(facadeA.redactPatterns.map(\.text), ["Northwind"])

        // Elsewhere the global suppression still stands.
        XCTAssertTrue(facadeB.suppressKeys.contains(key))
        XCTAssertTrue(facadeB.redactPatterns.isEmpty)
    }

    @MainActor
    func testMatterSuppressionOverridesGlobalAcceptance() {
        let global = learning(.global)
        let matterA = learning(.matter(id: UUID()))
        let facadeA = ScopedLearningStore(global: global, matter: matterA)
        let facadeB = ScopedLearningStore(global: global, matter: learning(.matter(id: UUID())))

        global.record(accepted: [("Northwind", .company)], rejected: [])
        matterA.record(accepted: [], rejected: [("Northwind", .company)])

        let key = LearningStore.key(value: "Northwind", type: .company)
        XCTAssertTrue(facadeA.suppressKeys.contains(key), "matter suppression must beat global acceptance")
        XCTAssertTrue(facadeA.redactPatterns.isEmpty)

        XCTAssertFalse(facadeB.suppressKeys.contains(key))
        XCTAssertEqual(facadeB.redactPatterns.map(\.text), ["Northwind"])
    }

    @MainActor
    func testNeutralMatterTermDoesNotMaskGlobalRule() {
        let global = learning(.global)
        let matterA = learning(.matter(id: UUID()))
        let facadeA = ScopedLearningStore(global: global, matter: matterA)

        global.record(accepted: [], rejected: [("Annex B", .company)])
        // One accept plus one reject in the matter layer: a tie expresses no
        // rule, so the global suppression must remain in force.
        matterA.record(accepted: [("Annex B", .company)], rejected: [])
        matterA.record(accepted: [], rejected: [("Annex B", .company)])

        let key = LearningStore.key(value: "Annex B", type: .company)
        XCTAssertTrue(facadeA.suppressKeys.contains(key))
    }

    // MARK: - Custom pattern union

    @MainActor
    func testPatternUnionDeduplicatesAndMatterCopyWins() throws {
        let global = patterns(.global)
        let matterA = patterns(.matter(id: UUID()))
        let facadeA = ScopedCustomPatternStore(global: global, matter: matterA)
        let facadeB = ScopedCustomPatternStore(global: global, matter: patterns(.matter(id: UUID())))
        let globalOnly = ScopedCustomPatternStore(global: global)

        XCTAssertEqual(global.merge([CustomPattern(text: "Acme Corporation", type: .company)]), 1)
        let matterCopy = CustomPattern(text: "Acme Corporation", type: .company)
        let matterOnly = CustomPattern(text: "Project Falcon", type: .company)
        XCTAssertEqual(matterA.merge([matterCopy, matterOnly]), 2)

        let effective = facadeA.activePatterns
        XCTAssertEqual(effective.count, 2, "identical content in both layers must appear once")
        XCTAssertEqual(Set(effective.map(\.text)), ["Acme Corporation", "Project Falcon"])
        // merge assigns imported patterns fresh ids, so identify each layer's
        // stored copy by reading it back before asserting which one survived.
        let matterStoredID = try XCTUnwrap(matterA.patterns.first { $0.text == "Acme Corporation" }?.id)
        let globalStoredID = try XCTUnwrap(global.patterns.first { $0.text == "Acme Corporation" }?.id)
        XCTAssertTrue(
            effective.contains { $0.id == matterStoredID },
            "the surviving duplicate must be the matter layer's copy"
        )
        XCTAssertFalse(
            effective.contains { $0.id == globalStoredID },
            "the global duplicate must be dropped from the effective list"
        )

        XCTAssertEqual(facadeB.activePatterns.map(\.text), ["Acme Corporation"])
        XCTAssertEqual(globalOnly.activePatterns.map(\.text), ["Acme Corporation"])
    }

    @MainActor
    func testPatternMergeWritesToTheChosenLayer() {
        let global = patterns(.global)
        let matterA = patterns(.matter(id: UUID()))
        let facade = ScopedCustomPatternStore(global: global, matter: matterA)

        XCTAssertEqual(facade.merge([CustomPattern(text: "Matter Term", type: .company)], to: .matter), 1)
        XCTAssertEqual(facade.merge([CustomPattern(text: "Global Term", type: .company)]), 1)

        XCTAssertEqual(matterA.patterns.map(\.text), ["Matter Term"])
        XCTAssertEqual(global.patterns.map(\.text), ["Global Term"])
    }

    // MARK: - Writes refused without a matter layer

    @MainActor
    func testMatterTargetedWritesAreRefusedWhenNoMatterLayerIsAttached() {
        let global = learning(.global)
        let facade = ScopedLearningStore(global: global)

        let recorded = facade.record(
            accepted: [], rejected: [("Stray", .company)], to: .matter
        )
        XCTAssertFalse(recorded)
        XCTAssertTrue(global.suppressKeys.isEmpty, "a matter-only rule must never fall through to global")

        let patternFacade = ScopedCustomPatternStore(global: patterns(.global))
        let added = patternFacade.merge([CustomPattern(text: "Stray", type: .company)], to: .matter)
        XCTAssertEqual(added, 0)
        XCTAssertTrue(patternFacade.global.patterns.isEmpty)
    }

    // MARK: - Privacy of the persisted keys

    @MainActor
    func testDefaultsKeysContainOnlyBaseKeysAndMatterIds() {
        let matterLabel = "Zhang v. Acme Labor Arbitration"
        let idA = UUID()

        let global = learning(.global)
        let matterA = learning(.matter(id: idA))
        global.record(accepted: [("Acme Corporation", .company)], rejected: [])
        matterA.record(accepted: [], rejected: [("Zhang Wei", .person)])

        let globalPatterns = patterns(.global)
        let matterPatterns = patterns(.matter(id: idA))
        XCTAssertEqual(globalPatterns.merge([CustomPattern(text: "Acme Corporation", type: .company)]), 1)
        XCTAssertEqual(matterPatterns.merge([CustomPattern(text: "Zhang Wei", type: .person)]), 1)

        let domain = defaults.persistentDomain(forName: suiteName) ?? [:]
        let expectedKeys: Set<String> = [
            "\(learnedBase).sealed",
            "\(learnedBase).matter.\(idA.uuidString).sealed",
            "\(patternBase).sealed",
            "\(patternBase).matter.\(idA.uuidString).sealed"
        ]
        XCTAssertEqual(Set(domain.keys), expectedKeys)

        for key in domain.keys {
            XCTAssertFalse(key.contains("Zhang"), "a defaults key leaked a party name: \(key)")
            XCTAssertFalse(key.contains("Acme"), "a defaults key leaked a client name: \(key)")
            XCTAssertFalse(key.contains(matterLabel), "a defaults key leaked the matter label: \(key)")
        }

        // The blobs themselves stay sealed: no plaintext values on disk.
        for (_, anyValue) in domain {
            guard let data = anyValue as? Data else { continue }
            XCTAssertNil(data.range(of: Data("Acme Corporation".utf8)))
            XCTAssertNil(data.range(of: Data("Zhang Wei".utf8)))
        }
    }

    // MARK: - The global blob is never rewritten by scoped reads

    @MainActor
    func testReadingScopedStoresNeverRewritesTheGlobalBlob() {
        let global = learning(.global)
        global.record(accepted: [("Acme Holdings", .company)], rejected: [])
        let globalPatterns = patterns(.global)
        XCTAssertEqual(globalPatterns.merge([CustomPattern(text: "Acme Holdings", type: .company)]), 1)

        let learnedBlobBefore = defaults.data(forKey: "\(learnedBase).sealed")
        let patternBlobBefore = defaults.data(forKey: "\(patternBase).sealed")
        XCTAssertNotNil(learnedBlobBefore)
        XCTAssertNotNil(patternBlobBefore)

        // Construct matter layers and facades, read every effective view, and
        // reopen the global layer from disk.
        let facade = ScopedLearningStore(global: global, matter: learning(.matter(id: UUID())))
        _ = facade.suppressKeys
        _ = facade.redactPatterns
        let patternFacade = ScopedCustomPatternStore(
            global: globalPatterns, matter: patterns(.matter(id: UUID()))
        )
        _ = patternFacade.activePatterns
        _ = learning(.global).redactPatterns
        _ = patterns(.global).activePatterns

        XCTAssertEqual(defaults.data(forKey: "\(learnedBase).sealed"), learnedBlobBefore)
        XCTAssertEqual(defaults.data(forKey: "\(patternBase).sealed"), patternBlobBefore)
    }

    // MARK: - Matter deletion

    @MainActor
    func testRemoveMatterScopeDeletesExactlyThatMattersKeys() throws {
        let idA = UUID()
        let idB = UUID()

        let global = learning(.global)
        let matterA = learning(.matter(id: idA))
        let matterB = learning(.matter(id: idB))
        global.record(accepted: [("Keep Global", .company)], rejected: [])
        matterA.record(accepted: [], rejected: [("Drop Me", .company)])
        matterB.record(accepted: [], rejected: [("Keep B", .company)])

        let patternsA = patterns(.matter(id: idA))
        XCTAssertEqual(patternsA.merge([CustomPattern(text: "Drop Me Too", type: .company)]), 1)

        // A legacy plaintext key for the matter must be swept as well.
        let legacyKey = StoreScope.matter(id: idA).storageKey(base: learnedBase)
        defaults.set(Data("legacy".utf8), forKey: legacyKey)

        let learnedAKey = "\(learnedBase).matter.\(idA.uuidString).sealed"
        let patternAKey = "\(patternBase).matter.\(idA.uuidString).sealed"
        let learnedBKey = "\(learnedBase).matter.\(idB.uuidString).sealed"
        let sealedABlob = try XCTUnwrap(defaults.data(forKey: learnedAKey))
        let globalBlob = defaults.data(forKey: "\(learnedBase).sealed")
        let matterBBlob = defaults.data(forKey: learnedBKey)

        LearningStore.removeMatterScope(id: idA, defaults: defaults, baseKey: learnedBase)
        CustomPatternStore.removeMatterScope(id: idA, defaults: defaults, baseKey: patternBase)

        XCTAssertNil(defaults.data(forKey: learnedAKey))
        XCTAssertNil(defaults.data(forKey: patternAKey))
        XCTAssertNil(defaults.data(forKey: legacyKey))
        XCTAssertEqual(defaults.data(forKey: "\(learnedBase).sealed"), globalBlob)
        XCTAssertEqual(defaults.data(forKey: learnedBKey), matterBBlob)

        // The vault key went with the blob: the old ciphertext is unopenable.
        XCTAssertThrowsError(
            try LocalDataVault.open(sealedABlob, account: "store.\(learnedBase).matter.\(idA.uuidString)")
        )

        // Matter B still reads back intact.
        let reopenedB = learning(.matter(id: idB))
        XCTAssertTrue(reopenedB.suppressKeys.contains(LearningStore.key(value: "Keep B", type: .company)))
    }

    @MainActor
    func testAggregateRemoveMatterScopeCleansBothStoresUnderProductionKeys() {
        // Production base keys inside a throwaway suite; only matter-scoped
        // layers are constructed, so the developer machine's real global
        // vault accounts are never created or touched.
        let id = UUID()
        usedStorageKeys.insert(StoreScope.matter(id: id).storageKey(base: LearningStore.defaultStorageKey))
        usedStorageKeys.insert(StoreScope.matter(id: id).storageKey(base: CustomPatternStore.defaultStorageKey))

        let learned = LearningStore(scope: .matter(id: id), defaults: defaults)
        learned.record(accepted: [], rejected: [("Gone", .company)])
        let vocabulary = CustomPatternStore(scope: .matter(id: id), defaults: defaults)
        XCTAssertEqual(vocabulary.merge([CustomPattern(text: "Gone", type: .company)]), 1)

        let learnedKey = "\(LearningStore.defaultStorageKey).matter.\(id.uuidString).sealed"
        let patternKey = "\(CustomPatternStore.defaultStorageKey).matter.\(id.uuidString).sealed"
        XCTAssertNotNil(defaults.data(forKey: learnedKey))
        XCTAssertNotNil(defaults.data(forKey: patternKey))

        ScopedStores.removeMatterScope(id: id, defaults: defaults)

        XCTAssertNil(defaults.data(forKey: learnedKey))
        XCTAssertNil(defaults.data(forKey: patternKey))
    }
}
