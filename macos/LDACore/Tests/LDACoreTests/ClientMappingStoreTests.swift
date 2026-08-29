//
//  ClientMappingStoreTests.swift
//  LDACoreTests
//
//  Tests for client-profile identity persistence (R10): one encrypted Mapping
//  per client label, reused as the seed for every session under that client,
//  so the same client's entities keep the same placeholders across sessions
//  and documents.
//
//  Passphrase protection keeps the tests hermetic (no Keychain access from the
//  unsigned test process).
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class ClientMappingStoreTests: XCTestCase {

    private let stamp = "2026-06-11T00:00:00Z"
    private var root: URL!
    private var store: ClientMappingStore!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClientMappingStoreTests-\(UUID().uuidString)", isDirectory: true)
        store = try ClientMappingStore(rootDirectory: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func mapping(label: String, entries: [MappingEntry]) -> Mapping {
        Mapping(
            entries: Dictionary(uniqueKeysWithValues: entries.map { ($0.token, $0) }),
            createdAtISO8601: stamp,
            sourceFile: label
        )
    }

    private func entry(_ token: String, _ value: String, _ type: EntityType) -> MappingEntry {
        MappingEntry(token: token, value: value, type: type, surfaceText: value, aliases: [])
    }

    // MARK: - Round trip

    func testSaveThenLoadRoundTrips() throws {
        let saved = mapping(
            label: "Garcia Matter",
            entries: [entry("{PERSON_1}", "Maria Garcia", .person)]
        )
        try store.save(saved, label: "Garcia Matter", protection: .passphrase("pw"))

        let loaded = try store.load(label: "Garcia Matter", protection: .passphrase("pw"))

        XCTAssertEqual(loaded, saved)
    }

    func testLoadMissingLabelReturnsNil() throws {
        XCTAssertNil(try store.load(label: "Nobody", protection: .passphrase("pw")))
    }

    func testSaveOverwritesWithUnionAcrossSessions() throws {
        let first = mapping(
            label: "Acme",
            entries: [entry("{COMPANY_1}", "Acme Corp", .company)]
        )
        try store.save(first, label: "Acme", protection: .passphrase("pw"))

        var second = first
        let newEntry = entry("{PERSON_1}", "John Smith", .person)
        second.entries[newEntry.token] = newEntry
        try store.save(second, label: "Acme", protection: .passphrase("pw"))

        let loaded = try store.load(label: "Acme", protection: .passphrase("pw"))
        XCTAssertEqual(loaded?.entries.count, 2)
    }

    // MARK: - Listing and deletion

    func testListReturnsOpaqueRandomIdentifiersWithoutLabelLeakage() throws {
        try store.save(mapping(label: "Zeta", entries: []), label: "Zeta", protection: .passphrase("pw"))
        try store.save(mapping(label: "Alpha", entries: []), label: "Alpha", protection: .passphrase("pw"))

        let identifiers = try store.list()
        XCTAssertEqual(identifiers.count, 2)
        XCTAssertTrue(identifiers.allSatisfy { UUID(uuidString: $0) != nil })
        XCTAssertFalse(identifiers.contains { $0.contains("Alpha") || $0.contains("Zeta") })
    }

    func testResolvedListReadsExactLabelsFromEncryptedMappings() throws {
        try store.save(
            mapping(label: "Garcia: Deal", entries: []),
            label: "Garcia: Deal",
            protection: .passphrase("pw")
        )

        let result = try store.listResolvedLabels { _ in .passphrase("pw") }

        XCTAssertEqual(result.labels, ["Garcia: Deal"])
        XCTAssertEqual(result.unreadableCount, 0)
    }

    func testResolvedListKeepsReadableLabelsWhenOneMappingCannotUnlock() throws {
        try store.save(
            mapping(label: "Alpha", entries: []),
            label: "Alpha",
            protection: .passphrase("pw")
        )
        try MappingStore.save(
            mapping(label: "Broken", entries: []),
            to: root.appendingPathComponent("\(UUID().uuidString).ldaclient"),
            protection: .passphrase("other")
        )

        let result = try store.listResolvedLabels { _ in .passphrase("pw") }

        XCTAssertEqual(result.labels, ["Alpha"])
        XCTAssertEqual(result.unreadableCount, 1)
    }

    func testUnreadableOpaqueMappingBlocksLoadAndSaveInsteadOfResettingIdentity() throws {
        try store.save(
            mapping(label: "Locked Matter", entries: []),
            label: "Locked Matter",
            protection: .passphrase("original-password")
        )

        XCTAssertThrowsError(
            try store.load(label: "New Matter", protection: .passphrase("wrong-password"))
        )
        XCTAssertThrowsError(
            try store.save(
                mapping(label: "New Matter", entries: []),
                label: "New Matter",
                protection: .passphrase("wrong-password")
            )
        )
        XCTAssertEqual(try store.list().count, 1)
    }

    func testDeleteRemovesClient() throws {
        try store.save(mapping(label: "Gone", entries: []), label: "Gone", protection: .passphrase("pw"))
        try store.delete(label: "Gone", protection: .passphrase("pw"))

        XCTAssertEqual(try store.list(), [])
        XCTAssertNil(try store.load(label: "Gone", protection: .passphrase("pw")))
    }

    func testRenameMovesTheEncryptedMappingAndPreservesEntries() throws {
        let saved = mapping(
            label: "Acme Matter",
            entries: [entry("{COMPANY_1}", "Acme Corp", .company)]
        )
        try store.save(saved, label: "Acme Matter", protection: .passphrase("pw"))

        let renamed = try store.rename(
            from: "Acme Matter",
            to: "Acme Transaction",
            oldProtection: .passphrase("pw"),
            newProtection: .passphrase("pw")
        )

        XCTAssertTrue(renamed)
        XCTAssertNil(try store.load(label: "Acme Matter", protection: .passphrase("pw")))
        let loaded = try XCTUnwrap(
            try store.load(label: "Acme Transaction", protection: .passphrase("pw"))
        )
        XCTAssertEqual(loaded.entries, saved.entries)
        XCTAssertEqual(loaded.sourceFile, "Acme Transaction")
    }

    func testRenameSupportsDifferentExactLabelsWithTheSameFileSlug() throws {
        try store.save(
            mapping(label: "Garcia Deal", entries: []),
            label: "Garcia Deal",
            protection: .passphrase("pw")
        )

        XCTAssertTrue(
            try store.rename(
                from: "Garcia Deal",
                to: "Garcia: Deal",
                oldProtection: .passphrase("pw"),
                newProtection: .passphrase("pw")
            )
        )

        let resolution = try store.listResolvedLabels { _ in .passphrase("pw") }
        XCTAssertEqual(resolution.labels, ["Garcia: Deal"])
    }

    func testRenameMigratesALegacySlugFileToAnOpaqueIdentifier() throws {
        let legacyURL = root.appendingPathComponent("Legacy Matter.ldaclient")
        try MappingStore.save(
            mapping(label: "Legacy Matter", entries: []),
            to: legacyURL,
            protection: .passphrase("pw")
        )

        XCTAssertTrue(
            try store.rename(
                from: "Legacy Matter",
                to: "Current Matter",
                oldProtection: .passphrase("pw"),
                newProtection: .passphrase("pw")
            )
        )

        let identifiers = try store.list()
        XCTAssertEqual(identifiers.count, 1)
        XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(identifiers.first)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
        XCTAssertNotNil(
            try store.load(label: "Current Matter", protection: .passphrase("pw"))
        )
    }

    func testRenameRejectsAnOccupiedDestination() throws {
        try store.save(mapping(label: "Alpha", entries: []), label: "Alpha", protection: .passphrase("pw"))
        try store.save(mapping(label: "Beta", entries: []), label: "Beta", protection: .passphrase("pw"))

        XCTAssertThrowsError(
            try store.rename(
                from: "Alpha",
                to: "Beta",
                oldProtection: .passphrase("pw"),
                newProtection: .passphrase("pw")
            )
        )
        XCTAssertNotNil(try store.load(label: "Alpha", protection: .passphrase("pw")))
        XCTAssertNotNil(try store.load(label: "Beta", protection: .passphrase("pw")))
    }

    func testRenameOfMatterWithoutMappingIsANoOp() throws {
        XCTAssertFalse(
            try store.rename(
                from: "Missing",
                to: "Renamed",
                oldProtection: .passphrase("pw"),
                newProtection: .passphrase("pw")
            )
        )
    }

    // MARK: - Label safety

    func testPunctuationAndCaseDifferencesRemainSeparateMappings() throws {
        try store.save(
            mapping(label: "Acme/Inc", entries: [entry("{COMPANY_1}", "Acme", .company)]),
            label: "Acme/Inc",
            protection: .passphrase("pw")
        )
        try store.save(
            mapping(label: "Acme:Inc", entries: [entry("{COMPANY_1}", "Acme Colon", .company)]),
            label: "Acme:Inc",
            protection: .passphrase("pw")
        )
        try store.save(
            mapping(label: "acme/inc", entries: [entry("{COMPANY_1}", "Lowercase", .company)]),
            label: "acme/inc",
            protection: .passphrase("pw")
        )

        XCTAssertEqual(
            try store.listResolvedLabels { _ in .passphrase("pw") }.labels,
            ["Acme/Inc", "Acme:Inc", "acme/inc"]
        )
        XCTAssertEqual(
            try store.load(label: "Acme/Inc", protection: .passphrase("pw"))?
                .entries["{COMPANY_1}"]?.value,
            "Acme"
        )
        XCTAssertEqual(
            try store.load(label: "Acme:Inc", protection: .passphrase("pw"))?
                .entries["{COMPANY_1}"]?.value,
            "Acme Colon"
        )
    }

    func testEmptyLabelIsRejected() {
        XCTAssertThrowsError(
            try store.save(mapping(label: "", entries: []), label: "  ", protection: .passphrase("pw"))
        )
    }

    // MARK: - Seeding behavior end to end

    func testClientSeedKeepsIdentitiesAcrossSessions() throws {
        // Session 1 under the client.
        let docDir = root.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: docDir, withIntermediateDirectories: true)
        let doc1 = docDir.appendingPathComponent("first.txt")
        try Data("Mail john@acme.com now.".utf8).write(to: doc1)

        let session1 = try LDAService.anonymizeSession(
            inputs: [doc1],
            createdAtISO8601: stamp,
            seedMapping: try store.load(label: "Acme", protection: .passphrase("pw"))
        )
        try store.save(session1.mapping, label: "Acme", protection: .passphrase("pw"))

        // Session 2, days later, a different document, same client.
        let doc2 = docDir.appendingPathComponent("second.txt")
        try Data("Reach john@acme.com or mary@beta.io.".utf8).write(to: doc2)

        let session2 = try LDAService.anonymizeSession(
            inputs: [doc2],
            createdAtISO8601: stamp,
            seedMapping: try store.load(label: "Acme", protection: .passphrase("pw"))
        )

        // The address seen in session 1 keeps its token in session 2.
        XCTAssertTrue(session2.documents[0].redactedMarkdown.contains("{EMAIL_1}"))
        XCTAssertTrue(session2.documents[0].redactedMarkdown.contains("{EMAIL_2}"))
    }

    // MARK: - Keychain account derivation (pure)

    func testKeychainAccountIsSharedAndDoesNotExposeTheLabel() {
        let account = ClientMappingStore.keychainAccount(label: "Garcia Matter")
        XCTAssertEqual(account, ClientMappingStore.keychainAccount(label: "Other"))
        XCTAssertEqual(account, "lda-client-mappings")
        XCTAssertFalse(account.localizedCaseInsensitiveContains("Garcia"))
    }
}
