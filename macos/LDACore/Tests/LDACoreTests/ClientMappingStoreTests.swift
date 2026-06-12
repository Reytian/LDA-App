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

    func testListReturnsSavedLabelsSorted() throws {
        try store.save(mapping(label: "Zeta", entries: []), label: "Zeta", protection: .passphrase("pw"))
        try store.save(mapping(label: "Alpha", entries: []), label: "Alpha", protection: .passphrase("pw"))

        XCTAssertEqual(try store.list(), ["Alpha", "Zeta"])
    }

    func testDeleteRemovesClient() throws {
        try store.save(mapping(label: "Gone", entries: []), label: "Gone", protection: .passphrase("pw"))
        try store.delete(label: "Gone")

        XCTAssertEqual(try store.list(), [])
        XCTAssertNil(try store.load(label: "Gone", protection: .passphrase("pw")))
    }

    // MARK: - Label safety

    func testSlugCollisionIsDetectedNotSilentlyMerged() throws {
        // "Acme/Inc" and "Acme:Inc" sanitize to the same file name. Loading the
        // second label must fail loudly rather than hand one client's mapping
        // to another (cross-client identity bleed).
        try store.save(
            mapping(label: "Acme/Inc", entries: [entry("{COMPANY_1}", "Acme", .company)]),
            label: "Acme/Inc",
            protection: .passphrase("pw")
        )

        XCTAssertThrowsError(
            try store.load(label: "Acme:Inc", protection: .passphrase("pw"))
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

    func testKeychainAccountIsStablePerLabel() {
        let account = ClientMappingStore.keychainAccount(label: "Garcia Matter")
        XCTAssertEqual(account, ClientMappingStore.keychainAccount(label: "Garcia Matter"))
        XCTAssertTrue(account.hasPrefix("lda-client-"))
        XCTAssertNotEqual(account, ClientMappingStore.keychainAccount(label: "Other"))
    }
}
