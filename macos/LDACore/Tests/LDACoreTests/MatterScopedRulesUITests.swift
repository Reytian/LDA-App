//
//  MatterScopedRulesUITests.swift
//  LDACoreTests
//
//  The session wiring for matter-scoped learned rules and vocabulary (F4):
//  selecting a matter adopts its stable scope id, the "apply learned rules to
//  this matter only" toggle routes writes into the matter layer (persisted
//  per matter under an id-only key), and the scoped facades reach every
//  document model, including the real export write path.
//
//  Hermetic: temp-rooted encrypted stores with passphrase protection, a
//  suite-scoped UserDefaults, and test-only store base keys so the developer
//  machine's production vault accounts are never touched.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore
@testable import LDAUI

@MainActor
final class MatterScopedRulesUITests: XCTestCase {

    private static let createdAt = "2026-08-31T00:00:00Z"

    private let learnedBase = "scope-ui-test.learnedTerms"
    private let patternBase = "scope-ui-test.customPatterns"

    private var workDir: URL!
    private var suiteName: String!
    private var suite: UserDefaults!
    private var usedStorageKeys: Set<String> = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MatterScopedRulesUITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        suiteName = "MatterScopedRulesUITests-\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)
        usedStorageKeys = [learnedBase, patternBase]
    }

    override func tearDownWithError() throws {
        suite.removePersistentDomain(forName: suiteName)
        for key in usedStorageKeys {
            LocalDataVault.deleteKey(account: "store.\(key)")
        }
        usedStorageKeys = []
        try? FileManager.default.removeItem(at: workDir)
        try super.tearDownWithError()
    }

    private func write(_ name: String, _ content: String) throws -> URL {
        let url = workDir.appendingPathComponent(name)
        try Data(content.utf8).write(to: url)
        return url
    }

    /// The global layers plus a session wired exactly the way LDAApp wires
    /// production, but over hermetic storage.
    private struct ScopedFixture {
        let session: SessionModel
        let globalLearning: LearningStore
        let globalPatterns: CustomPatternStore
    }

    private func makeScopedSession() -> ScopedFixture {
        let clientRoot = workDir.appendingPathComponent("clients")
        let session = SessionModel(
            makeModel: {
                let model = ReviewModel(modelPath: nil)
                model.useLLM = false
                return model
            },
            clientStore: { try ClientMappingStore(rootDirectory: clientRoot) }
        )
        session.clientProtection = { _ in .passphrase("pw") }
        let recordRoot = workDir.appendingPathComponent("records")
        session.recordStore = { try SessionRecordStore(rootDirectory: recordRoot) }
        session.recordProtection = { .passphrase("pw") }
        let matterRoot = workDir.appendingPathComponent("matters")
        session.matterStore = { try MatterMetadataStore(rootDirectory: matterRoot) }
        session.matterProtection = { .passphrase("pw") }
        let parkedURL = workDir.appendingPathComponent("parked-test.ldamap")
        session.parkedMappingURL = { parkedURL }
        session.parkedProtection = { .passphrase("parked-pw") }

        let globalLearning = LearningStore(defaults: suite, storageKey: learnedBase)
        let globalPatterns = CustomPatternStore(defaults: suite, storageKey: patternBase)
        let localSuite: UserDefaults = suite
        let localLearnedBase = learnedBase
        let localPatternBase = patternBase
        session.scopeDefaults = { localSuite }
        session.makeMatterLearningStore = { id in
            LearningStore(scope: .matter(id: id), defaults: localSuite, baseKey: localLearnedBase)
        }
        session.makeMatterPatternStore = { id in
            CustomPatternStore(scope: .matter(id: id), defaults: localSuite, baseKey: localPatternBase)
        }
        session.attachStores(learning: globalLearning, patterns: globalPatterns)
        return ScopedFixture(
            session: session,
            globalLearning: globalLearning,
            globalPatterns: globalPatterns
        )
    }

    /// A fresh matter-layer learning store over the same suite, for asserting
    /// what actually persisted under one matter id.
    private func matterLearningLayer(_ id: UUID) -> LearningStore {
        usedStorageKeys.insert(StoreScope.matter(id: id).storageKey(base: learnedBase))
        return LearningStore(scope: .matter(id: id), defaults: suite, baseKey: learnedBase)
    }

    private func trackMatterKeys(_ id: UUID) {
        usedStorageKeys.insert(StoreScope.matter(id: id).storageKey(base: learnedBase))
        usedStorageKeys.insert(StoreScope.matter(id: id).storageKey(base: patternBase))
    }

    // MARK: - Write routing

    func testMatterToggleRoutesRecordsToTheMatterLayerOnly() throws {
        let fixture = makeScopedSession()
        let session = fixture.session

        XCTAssertTrue(try session.selectMatter("Matter A"))
        XCTAssertNil(session.matterScopeID, "no metadata entry exists until scoping is used")
        XCTAssertEqual(session.learnedRuleWriteTarget, .global)

        try session.setScopeLearnedRulesToMatter(true)
        let idA = try XCTUnwrap(session.matterScopeID)
        trackMatterKeys(idA)
        XCTAssertEqual(session.learnedRuleWriteTarget, .matter)

        // The exact write the export path performs.
        let store = try XCTUnwrap(session.emptyModel.learningStore)
        XCTAssertTrue(store.record(
            accepted: [],
            rejected: [("Schedule A", .company)],
            to: session.emptyModel.learningWriteTarget()
        ))

        let key = LearningStore.key(value: "Schedule A", type: .company)
        XCTAssertTrue(store.suppressKeys.contains(key))
        XCTAssertTrue(
            fixture.globalLearning.suppressKeys.isEmpty,
            "a matter-scoped write must not land in the global layer"
        )
        XCTAssertTrue(matterLearningLayer(idA).suppressKeys.contains(key))

        // A different matter's facade must not see the rule.
        let idB = UUID()
        trackMatterKeys(idB)
        let facadeB = ScopedLearningStore(
            global: fixture.globalLearning,
            matter: matterLearningLayer(idB)
        )
        XCTAssertFalse(facadeB.suppressKeys.contains(key), "matter A's rule leaked into matter B")
    }

    func testToggleOffAndNoMatterWriteTheGlobalLayer() throws {
        let fixture = makeScopedSession()
        let session = fixture.session

        // No matter selected: global.
        XCTAssertEqual(session.learnedRuleWriteTarget, .global)
        XCTAssertNil(session.emptyModel.learningStore?.matter)

        // Matter selected with the toggle off: still global.
        XCTAssertTrue(try session.selectMatter("Matter A"))
        try session.setScopeLearnedRulesToMatter(true)
        let idA = try XCTUnwrap(session.matterScopeID)
        trackMatterKeys(idA)
        try session.setScopeLearnedRulesToMatter(false)
        XCTAssertEqual(session.learnedRuleWriteTarget, .global)

        let store = try XCTUnwrap(session.emptyModel.learningStore)
        store.record(
            accepted: [],
            rejected: [("Exhibit 12", .company)],
            to: session.emptyModel.learningWriteTarget()
        )
        let key = LearningStore.key(value: "Exhibit 12", type: .company)
        XCTAssertTrue(fixture.globalLearning.suppressKeys.contains(key))
        XCTAssertFalse(matterLearningLayer(idA).suppressKeys.contains(key))
    }

    func testExportRecordsDecisionsIntoTheMatterLayer() async throws {
        let fixture = makeScopedSession()
        let session = fixture.session
        XCTAssertTrue(try session.selectMatter("Matter A"))
        try session.setScopeLearnedRulesToMatter(true)
        let idA = try XCTUnwrap(session.matterScopeID)
        trackMatterKeys(idA)

        let doc = try write("a.txt", "Mail john@acme.com please.")
        await session.addDocuments([doc])
        await session.anonymizeAll()
        let model = session.entries[0].model
        let entityID = try XCTUnwrap(model.entities.first?.id)
        model.setAccepted(entityID, false)

        let outDir = workDir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        _ = try await model.export(
            to: outDir,
            passphrase: "pw",
            createdAtISO8601: Self.createdAt
        )

        let key = LearningStore.key(value: "john@acme.com", type: .email)
        XCTAssertTrue(
            matterLearningLayer(idA).suppressKeys.contains(key),
            "the export write path must honor the matter scope"
        )
        XCTAssertFalse(fixture.globalLearning.suppressKeys.contains(key))
    }

    // MARK: - Toggle persistence and key derivation

    func testToggleKeyEmbedsOnlyTheMatterID() {
        let id = UUID()
        let key = SessionModel.matterScopeToggleKey(for: id)
        XCTAssertEqual(
            key,
            "com.haotianyi.LDA.scopeLearnedRulesToMatter.matter.\(id.uuidString)"
        )
    }

    func testTogglePersistsPerMatterAcrossSelections() throws {
        let fixture = makeScopedSession()
        let session = fixture.session

        XCTAssertTrue(try session.selectMatter("Matter A"))
        try session.setScopeLearnedRulesToMatter(true)
        let idA = try XCTUnwrap(session.matterScopeID)
        trackMatterKeys(idA)

        // Switching to another matter drops A's scope and starts B global.
        XCTAssertTrue(try session.selectMatter("Matter B"))
        XCTAssertFalse(session.scopeLearnedRulesToMatter)
        XCTAssertNil(session.matterScopeID)
        XCTAssertEqual(session.learnedRuleWriteTarget, .global)

        // Coming back to A restores its persisted toggle and stable id.
        XCTAssertTrue(try session.selectMatter("Matter A"))
        XCTAssertEqual(session.matterScopeID, idA)
        XCTAssertTrue(session.scopeLearnedRulesToMatter)
        XCTAssertEqual(session.learnedRuleWriteTarget, .matter)
    }

    func testToggleWithoutAMatterIsANoOp() throws {
        let fixture = makeScopedSession()
        try fixture.session.setScopeLearnedRulesToMatter(true)
        XCTAssertFalse(fixture.session.scopeLearnedRulesToMatter)
        XCTAssertNil(fixture.session.matterScopeID)
    }

    // MARK: - Vocabulary union

    func testMatterVocabularyReachesTheModelsAndStaysOutOfOtherScopes() throws {
        let fixture = makeScopedSession()
        let session = fixture.session
        XCTAssertTrue(try session.selectMatter("Matter A"))
        try session.setScopeLearnedRulesToMatter(true)
        let idA = try XCTUnwrap(session.matterScopeID)
        trackMatterKeys(idA)

        let pattern = CustomPattern(text: "Project Nightjar", type: .company)
        let added = try XCTUnwrap(session.scopedPatternStore).merge([pattern], to: .matter)
        XCTAssertEqual(added, 1)

        XCTAssertTrue(
            session.emptyModel.customPatternProvider().contains { $0.text == "Project Nightjar" },
            "the matter vocabulary must reach detection through the facade"
        )
        XCTAssertTrue(
            fixture.globalPatterns.activePatterns.isEmpty,
            "a matter-targeted merge must not touch the global vocabulary"
        )

        // Leaving the matter removes its vocabulary from the effective set.
        XCTAssertTrue(try session.selectMatter(nil))
        XCTAssertFalse(
            session.emptyModel.customPatternProvider().contains { $0.text == "Project Nightjar" }
        )
    }
}
