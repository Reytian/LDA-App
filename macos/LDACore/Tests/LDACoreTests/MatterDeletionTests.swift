//
//  MatterDeletionTests.swift
//  LDACoreTests
//
//  End-to-end storage contract for irreversible matter deletion. Tests use
//  passphrase-protected file stores and process-unique fake scoped-store blobs,
//  so no production or shared Keychain account is read, changed, or removed.
//
//  House rules: English only. No em-dash or en-dash-as-separator.
//

import XCTest
@testable import LDACore
@testable import LDAUI

@MainActor
final class MatterDeletionTests: XCTestCase {

    private static let createdAt = "2026-09-01T00:00:00Z"
    private static let protection = MappingProtection.passphrase("matter-delete-pw")

    private var workDir: URL!
    private var persistedDefaultsKeys: [(defaults: UserDefaults, key: String)] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MatterDeletionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        for item in persistedDefaultsKeys {
            item.defaults.removeObject(forKey: item.key)
        }
        persistedDefaultsKeys = []
        try? FileManager.default.removeItem(at: workDir)
        try super.tearDownWithError()
    }

    private final class EraseRecorder {
        var matterIDs: [UUID] = []
    }

    private struct Fixture {
        let session: SessionModel
        let defaults: UserDefaults
        let learnedBase: String
        let patternBase: String
        let clientStore: ClientMappingStore
        let recordStore: SessionRecordStore
        let matterStore: MatterMetadataStore
        let eraseRecorder: EraseRecorder
    }

    private struct RuleArtifacts {
        let learnedStorageKey: String
        let patternStorageKey: String
        let learnedPlaintext: Data
        let learnedSealed: Data
        let patternPlaintext: Data
        let patternSealed: Data
    }

    private enum LockedStore: String, CaseIterable {
        case clients
        case records
        case metadata
    }

    private func makeFixture(_ suffix: String) throws -> Fixture {
        let root = workDir.appendingPathComponent(suffix, isDirectory: true)
        let clientStore = try ClientMappingStore(
            rootDirectory: root.appendingPathComponent("clients", isDirectory: true)
        )
        let recordStore = try SessionRecordStore(
            rootDirectory: root.appendingPathComponent("records", isDirectory: true)
        )
        let matterStore = try MatterMetadataStore(
            rootDirectory: root.appendingPathComponent("matters", isDirectory: true)
        )
        let (defaults, _) = TestNamespace.defaults("matter-delete-\(suffix)")
        let learnedBase = TestNamespace.storeBaseKey("matter-delete-learned-\(suffix)")
        let patternBase = TestNamespace.storeBaseKey("matter-delete-pattern-\(suffix)")

        let session = SessionModel(
            makeModel: {
                let model = ReviewModel(modelPath: nil)
                model.useLLM = false
                return model
            },
            clientStore: { clientStore }
        )
        session.clientProtection = { _ in Self.protection }
        session.recordStore = { recordStore }
        session.recordProtection = { Self.protection }
        session.matterStore = { matterStore }
        session.matterProtection = { Self.protection }
        session.parkedMappingURL = {
            root.appendingPathComponent("parked.ldamap")
        }
        session.parkedProtection = { Self.protection }
        session.legacyDefaults = { defaults }
        session.scopeDefaults = { defaults }
        let eraseRecorder = EraseRecorder()
        session.eraseMatterScope = { id, scopeDefaults in
            eraseRecorder.matterIDs.append(id)
            for base in [learnedBase, patternBase] {
                let storageKey = StoreScope.matter(id: id).storageKey(base: base)
                scopeDefaults.removeObject(forKey: storageKey)
                scopeDefaults.removeObject(forKey: StoreBlobKeys.sealed(storageKey))
            }
        }

        return Fixture(
            session: session,
            defaults: defaults,
            learnedBase: learnedBase,
            patternBase: patternBase,
            clientStore: clientStore,
            recordStore: recordStore,
            matterStore: matterStore,
            eraseRecorder: eraseRecorder
        )
    }

    private func mapping(label: String, value: String) -> Mapping {
        let token = "{EMAIL_1}"
        return Mapping(
            entries: [
                token: MappingEntry(
                    token: token,
                    value: value,
                    type: .email,
                    surfaceText: value,
                    aliases: []
                )
            ],
            createdAtISO8601: Self.createdAt,
            sourceFile: label
        )
    }

    private func record(label: String, protectedValues: Int = 1) -> SessionRecord {
        SessionRecord(
            createdAtISO8601: Self.createdAt,
            clientLabel: label,
            documents: [],
            protectedValueCount: protectedValues
        )
    }

    private func track(storageKey: String, defaults: UserDefaults) {
        persistedDefaultsKeys.append((defaults, storageKey))
        persistedDefaultsKeys.append((defaults, StoreBlobKeys.sealed(storageKey)))
    }

    private func trackToggle(id: UUID, defaults: UserDefaults) {
        persistedDefaultsKeys.append((defaults, SessionModel.matterScopeToggleKey(for: id)))
    }

    private func seedRules(
        _ fixture: Fixture,
        scope: StoreScope,
        marker: String
    ) -> RuleArtifacts {
        let learnedStorageKey = scope.storageKey(base: fixture.learnedBase)
        let patternStorageKey = scope.storageKey(base: fixture.patternBase)
        track(storageKey: learnedStorageKey, defaults: fixture.defaults)
        track(storageKey: patternStorageKey, defaults: fixture.defaults)

        let learnedPlaintext = Data("\(marker) learned plaintext".utf8)
        let learnedSealed = Data("\(marker) learned sealed".utf8)
        let patternPlaintext = Data("\(marker) pattern plaintext".utf8)
        let patternSealed = Data("\(marker) pattern sealed".utf8)
        fixture.defaults.set(learnedPlaintext, forKey: learnedStorageKey)
        fixture.defaults.set(learnedSealed, forKey: StoreBlobKeys.sealed(learnedStorageKey))
        fixture.defaults.set(patternPlaintext, forKey: patternStorageKey)
        fixture.defaults.set(patternSealed, forKey: StoreBlobKeys.sealed(patternStorageKey))

        return RuleArtifacts(
            learnedStorageKey: learnedStorageKey,
            patternStorageKey: patternStorageKey,
            learnedPlaintext: learnedPlaintext,
            learnedSealed: learnedSealed,
            patternPlaintext: patternPlaintext,
            patternSealed: patternSealed
        )
    }

    private func assertRulesRemainReadable(
        _ artifacts: RuleArtifacts,
        fixture: Fixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            fixture.defaults.data(forKey: artifacts.learnedStorageKey),
            artifacts.learnedPlaintext,
            file: file,
            line: line
        )
        XCTAssertEqual(
            fixture.defaults.data(forKey: StoreBlobKeys.sealed(artifacts.learnedStorageKey)),
            artifacts.learnedSealed,
            file: file,
            line: line
        )
        XCTAssertEqual(
            fixture.defaults.data(forKey: artifacts.patternStorageKey),
            artifacts.patternPlaintext,
            file: file,
            line: line
        )
        XCTAssertEqual(
            fixture.defaults.data(forKey: StoreBlobKeys.sealed(artifacts.patternStorageKey)),
            artifacts.patternSealed,
            file: file,
            line: line
        )
    }

    func testActiveMatterDeletionIsRefusedWithoutMutation() throws {
        let fixture = try makeFixture("active")
        let metadata = try fixture.matterStore.ensure(
            label: "Active Matter",
            protection: Self.protection
        )
        XCTAssertTrue(try fixture.session.selectMatter("Active Matter"))
        try fixture.session.setScopeLearnedRulesToMatter(true)
        trackToggle(id: metadata.id, defaults: fixture.defaults)
        let rules = seedRules(fixture, scope: .matter(id: metadata.id), marker: "active")
        try fixture.clientStore.save(
            mapping(label: "Active Matter", value: "active@example.com"),
            label: "Active Matter",
            protection: Self.protection
        )
        let history = record(label: "Active Matter")
        try fixture.recordStore.save(history, protection: Self.protection)

        var eraserCalled = false
        fixture.session.eraseMatterScope = { _, _ in eraserCalled = true }

        XCTAssertThrowsError(try fixture.session.deleteMatter("Active Matter"))

        XCTAssertFalse(eraserCalled)
        XCTAssertNotNil(
            try fixture.clientStore.load(label: "Active Matter", protection: Self.protection)
        )
        XCTAssertNotNil(try fixture.recordStore.load(id: history.id, protection: Self.protection))
        XCTAssertEqual(
            try fixture.matterStore.list(protection: Self.protection).metadata.map(\.id),
            [metadata.id]
        )
        XCTAssertNotNil(
            fixture.defaults.data(forKey: StoreBlobKeys.sealed(rules.learnedStorageKey))
        )
        XCTAssertNotNil(
            fixture.defaults.data(forKey: StoreBlobKeys.sealed(rules.patternStorageKey))
        )
        XCTAssertEqual(
            fixture.defaults.object(forKey: SessionModel.matterScopeToggleKey(for: metadata.id))
                as? Bool,
            true
        )
        assertRulesRemainReadable(rules, fixture: fixture)
    }

    func testArchivedRenamedMatterDeletionErasesOwnedDataAndPreservesOtherScopes() throws {
        let fixture = try makeFixture("complete")
        let globalRules = seedRules(fixture, scope: .global, marker: "global")

        let originalLabel = "Acme Matter"
        let currentLabel = "Acme Transaction"
        let target = try fixture.matterStore.ensure(
            label: originalLabel,
            protection: Self.protection
        )
        XCTAssertTrue(try fixture.session.selectMatter(originalLabel))
        try fixture.session.setScopeLearnedRulesToMatter(true)
        trackToggle(id: target.id, defaults: fixture.defaults)
        let targetRules = seedRules(
            fixture,
            scope: .matter(id: target.id),
            marker: "target"
        )

        let other = try fixture.matterStore.ensure(
            label: "Other Matter",
            protection: Self.protection
        )
        let otherRules = seedRules(
            fixture,
            scope: .matter(id: other.id),
            marker: "other"
        )
        trackToggle(id: other.id, defaults: fixture.defaults)
        fixture.defaults.set(true, forKey: SessionModel.matterScopeToggleKey(for: other.id))

        try fixture.clientStore.save(
            mapping(label: originalLabel, value: "old@example.com"),
            label: originalLabel,
            protection: Self.protection
        )
        let aliasHistory = record(label: originalLabel)
        try fixture.recordStore.save(aliasHistory, protection: Self.protection)

        try fixture.session.renameMatter(from: originalLabel, to: currentLabel)

        // A stale alias mapping can survive from an older installation. The
        // metadata aliases still make it owned by the same matter.
        try fixture.clientStore.save(
            mapping(label: originalLabel, value: "alias@example.com"),
            label: originalLabel,
            protection: Self.protection
        )
        let currentHistory = record(label: currentLabel, protectedValues: 2)
        try fixture.recordStore.save(currentHistory, protection: Self.protection)

        try fixture.clientStore.save(
            mapping(label: "Other Matter", value: "other@example.com"),
            label: "Other Matter",
            protection: Self.protection
        )
        let otherHistory = record(label: "Other Matter", protectedValues: 3)
        try fixture.recordStore.save(otherHistory, protection: Self.protection)

        XCTAssertTrue(
            try fixture.session.setMatterArchived(
                currentLabel,
                isArchived: true,
                discardingDocuments: true
            )
        )

        try fixture.session.deleteMatter(currentLabel)

        XCTAssertEqual(fixture.eraseRecorder.matterIDs, [target.id])

        let metadata = try fixture.matterStore.list(protection: Self.protection)
        XCTAssertEqual(metadata.unreadableCount, 0)
        XCTAssertEqual(metadata.metadata.map(\.label), ["Other Matter"])
        XCTAssertNil(
            try fixture.clientStore.load(label: currentLabel, protection: Self.protection)
        )
        XCTAssertNil(
            try fixture.clientStore.load(label: originalLabel, protection: Self.protection)
        )
        XCTAssertNotNil(
            try fixture.clientStore.load(label: "Other Matter", protection: Self.protection)
        )
        let remainingRecords = try fixture.recordStore.resolve(protection: Self.protection)
        XCTAssertEqual(remainingRecords.unreadableCount, 0)
        XCTAssertEqual(remainingRecords.records.map(\.id), [otherHistory.id])

        XCTAssertNil(
            fixture.defaults.data(forKey: StoreBlobKeys.sealed(targetRules.learnedStorageKey))
        )
        XCTAssertNil(
            fixture.defaults.data(forKey: StoreBlobKeys.sealed(targetRules.patternStorageKey))
        )
        XCTAssertNil(fixture.defaults.data(forKey: targetRules.learnedStorageKey))
        XCTAssertNil(fixture.defaults.data(forKey: targetRules.patternStorageKey))
        XCTAssertNil(
            fixture.defaults.object(forKey: SessionModel.matterScopeToggleKey(for: target.id))
        )
        assertRulesRemainReadable(globalRules, fixture: fixture)
        assertRulesRemainReadable(otherRules, fixture: fixture)
        XCTAssertEqual(
            fixture.defaults.object(forKey: SessionModel.matterScopeToggleKey(for: other.id))
                as? Bool,
            true
        )
    }

    func testDuplicateMetadataIDFailsBeforeAnyDeletionMutation() throws {
        let fixture = try makeFixture("duplicate-metadata-id")
        let target = try fixture.matterStore.ensure(
            label: "Duplicate ID Matter",
            protection: Self.protection
        )
        try fixture.matterStore.setArchived(
            label: target.label,
            isArchived: true,
            protection: Self.protection
        )
        let rules = seedRules(
            fixture,
            scope: .matter(id: target.id),
            marker: "duplicate-id"
        )
        try fixture.clientStore.save(
            mapping(label: target.label, value: "duplicate@example.com"),
            label: target.label,
            protection: Self.protection
        )

        let metadataFile = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: fixture.matterStore.root,
                includingPropertiesForKeys: nil
            ).first { $0.pathExtension == "ldamatter" }
        )
        let duplicateFile = fixture.matterStore.root.appendingPathComponent(
            "\(UUID().uuidString).ldamatter"
        )
        try FileManager.default.copyItem(at: metadataFile, to: duplicateFile)

        XCTAssertThrowsError(try fixture.session.deleteMatter(target.label))

        XCTAssertTrue(fixture.eraseRecorder.matterIDs.isEmpty)
        XCTAssertNotNil(
            try fixture.clientStore.load(label: target.label, protection: Self.protection)
        )
        assertRulesRemainReadable(rules, fixture: fixture)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: fixture.matterStore.root,
                includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "ldamatter" }.count,
            2
        )
    }

    func testOverlappingMetadataLabelAndAliasOwnershipFailsBeforeAnyDeletionMutation() throws {
        let fixture = try makeFixture("overlapping-metadata-label")
        let target = try fixture.matterStore.ensure(
            label: "Shared Label Matter",
            protection: Self.protection
        )
        try fixture.matterStore.setArchived(
            label: target.label,
            isArchived: true,
            protection: Self.protection
        )
        let rules = seedRules(
            fixture,
            scope: .matter(id: target.id),
            marker: "overlapping-label"
        )
        try fixture.clientStore.save(
            mapping(label: target.label, value: "shared@example.com"),
            label: target.label,
            protection: Self.protection
        )

        let staging = try MatterMetadataStore(
            rootDirectory: workDir.appendingPathComponent(
                "overlapping-metadata-staging",
                isDirectory: true
            )
        )
        _ = try staging.ensure(label: target.label, protection: Self.protection)
        try staging.rename(
            from: target.label,
            to: "Conflicting Current Label",
            protection: Self.protection
        )
        try staging.setArchived(
            label: "Conflicting Current Label",
            isArchived: true,
            protection: Self.protection
        )
        try moveOnlyFile(from: staging.root, to: fixture.matterStore.root)

        XCTAssertThrowsError(try fixture.session.deleteMatter(target.label))

        XCTAssertTrue(fixture.eraseRecorder.matterIDs.isEmpty)
        XCTAssertNotNil(
            try fixture.clientStore.load(label: target.label, protection: Self.protection)
        )
        assertRulesRemainReadable(rules, fixture: fixture)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: fixture.matterStore.root,
                includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "ldamatter" }.count,
            2
        )
    }

    func testEachUnreadableStoreFailsBeforeAnyDeletionMutation() throws {
        for lockedStore in LockedStore.allCases {
            let fixture = try makeFixture("locked-\(lockedStore.rawValue)")
            let target = try fixture.matterStore.ensure(
                label: "Locked Boundary Matter",
                protection: Self.protection
            )
            try fixture.matterStore.setArchived(
                label: target.label,
                isArchived: true,
                protection: Self.protection
            )
            let rules = seedRules(
                fixture,
                scope: .matter(id: target.id),
                marker: lockedStore.rawValue
            )
            trackToggle(id: target.id, defaults: fixture.defaults)
            fixture.defaults.set(true, forKey: SessionModel.matterScopeToggleKey(for: target.id))
            try fixture.clientStore.save(
                mapping(label: target.label, value: "locked@example.com"),
                label: target.label,
                protection: Self.protection
            )
            let history = record(label: target.label)
            try fixture.recordStore.save(history, protection: Self.protection)
            try addUnreadableFile(to: lockedStore, fixture: fixture)

            var eraserCalled = false
            fixture.session.eraseMatterScope = { _, _ in eraserCalled = true }

            XCTAssertThrowsError(
                try fixture.session.deleteMatter(target.label),
                "\(lockedStore.rawValue) must fail closed"
            )

            XCTAssertFalse(eraserCalled, "\(lockedStore.rawValue) was not preflighted")
            XCTAssertTrue(
                try fixture.clientStore.listResolvedLabels { _ in Self.protection }
                    .labels.contains(target.label)
            )
            XCTAssertNotNil(
                try fixture.recordStore.load(id: history.id, protection: Self.protection)
            )
            XCTAssertTrue(
                try fixture.matterStore.list(protection: Self.protection).metadata
                    .contains { $0.id == target.id }
            )
            XCTAssertNotNil(
                fixture.defaults.data(forKey: StoreBlobKeys.sealed(rules.learnedStorageKey))
            )
            XCTAssertNotNil(
                fixture.defaults.data(forKey: StoreBlobKeys.sealed(rules.patternStorageKey))
            )
            XCTAssertEqual(
                fixture.defaults.object(forKey: SessionModel.matterScopeToggleKey(for: target.id))
                    as? Bool,
                true
            )
        }
    }

    private func addUnreadableFile(to store: LockedStore, fixture: Fixture) throws {
        let wrongProtection = MappingProtection.passphrase("wrong-\(store.rawValue)")
        switch store {
        case .clients:
            let staging = try ClientMappingStore(
                rootDirectory: workDir.appendingPathComponent(
                    "locked-client-staging-\(UUID().uuidString)",
                    isDirectory: true
                )
            )
            try staging.save(
                mapping(label: "Unreadable Client", value: "unreadable@example.com"),
                label: "Unreadable Client",
                protection: wrongProtection
            )
            try moveOnlyFile(from: staging.root, to: fixture.clientStore.root)
        case .records:
            try fixture.recordStore.save(
                record(label: "Unreadable Record"),
                protection: wrongProtection
            )
        case .metadata:
            let staging = try MatterMetadataStore(
                rootDirectory: workDir.appendingPathComponent(
                    "locked-metadata-staging-\(UUID().uuidString)",
                    isDirectory: true
                )
            )
            try staging.setArchived(
                label: "Unreadable Metadata",
                isArchived: true,
                protection: wrongProtection
            )
            try moveOnlyFile(from: staging.root, to: fixture.matterStore.root)
        }
    }

    private func moveOnlyFile(from source: URL, to destination: URL) throws {
        let file = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: source,
                includingPropertiesForKeys: nil
            ).first
        )
        try FileManager.default.moveItem(
            at: file,
            to: destination.appendingPathComponent(file.lastPathComponent)
        )
    }
}
