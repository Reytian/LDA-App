//
//  PortfolioLibraryTests.swift
//  LDACoreTests
//
//  Tests for PortfolioLibrary: encrypted portfolio directory with index-based
//  listing, atomic saves, orphan tolerance, and cross-kind isolation.
//
//  Keychain gating: every test in this class depends on the Keychain because
//  PortfolioLibrary uses Keychain-held keys for both the portfolio container
//  (LDAPROF / "ai.openclaw.lda.profilekey", account "library") and the index
//  container (LDAPIDX / "ai.openclaw.lda.libraryindexkey", account "index").
//  In an unsigned non-app test process the Keychain may be unavailable, so we
//  probe it in setUpWithError and throw XCTSkip for the whole class when it is
//  inaccessible. This is a new pattern for PortfolioLibrary tests (vs the
//  per-test skip used in MappingStoreTests / ProfileStoreTests) because every
//  single test needs the Keychain; gating the whole class in setUp avoids
//  repeating the probe in every test body.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
import Security
@testable import LDACore

final class PortfolioLibraryTests: XCTestCase {

    // MARK: - Hermetic per-test root directory

    private var workDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()

        // Probe the Keychain before creating any state so we skip cleanly on
        // unsigned test processes that cannot access the Keychain.
        let probeService = "ai.openclaw.lda.libraryindexkey"
        let probeAccount = "portfolio-library-test-probe-\(UUID().uuidString)"
        let probeData = Data("probe".utf8)
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: probeService,
            kSecAttrAccount as String: probeAccount,
            kSecValueData as String: probeData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        let tolerated: Set<OSStatus> = [
            errSecMissingEntitlement,
            errSecNotAvailable,
            errSecInteractionNotAllowed,
            errSecAuthFailed
        ]
        if tolerated.contains(addStatus) {
            throw XCTSkip("Keychain unavailable in this test process (status \(addStatus)); skipping all PortfolioLibraryTests")
        }
        if addStatus == errSecSuccess {
            // Best-effort cleanup of the probe item.
            let deleteQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: probeService,
                kSecAttrAccount as String: probeAccount
            ]
            SecItemDelete(deleteQuery as CFDictionary)
        }
        // errSecDuplicateItem is also acceptable (means the Keychain is available).

        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PortfolioLibraryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir, FileManager.default.fileExists(atPath: workDir.path) {
            try? FileManager.default.removeItem(at: workDir)
        }
        workDir = nil
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    private func makeLibrary() throws -> PortfolioLibrary {
        try PortfolioLibrary(rootDirectory: workDir)
    }

    private func samplePortfolio(label: String = "Acme Ltd", kind: PortfolioKind = .company) -> ClientPortfolio {
        ClientPortfolio(
            label: label,
            fields: [
                ProfileField(
                    id: UUID(),
                    key: .companyName,
                    value: "Acme Holdings Limited",
                    sourceDocument: "cert.pdf",
                    sourceSnippet: "the name of the company is Acme Holdings Limited",
                    snippetVerified: true,
                    confidence: 0.95,
                    userEdited: false
                )
            ],
            sourceDocuments: ["cert.pdf"],
            createdAtISO8601: "2026-06-11T00:00:00Z",
            incomplete: false,
            kind: kind,
            modifiedAtISO8601: "2026-06-11T00:00:00Z"
        )
    }

    private func sampleIndividualPortfolio(label: String = "Jane Doe") -> ClientPortfolio {
        ClientPortfolio(
            label: label,
            fields: [
                ProfileField(
                    id: UUID(),
                    key: .clientName,
                    value: "Jane Doe",
                    sourceDocument: "passport.pdf",
                    sourceSnippet: "Name: Jane Doe",
                    snippetVerified: true,
                    confidence: 0.98,
                    userEdited: false
                )
            ],
            sourceDocuments: ["passport.pdf"],
            createdAtISO8601: "2026-06-11T00:00:00Z",
            incomplete: false,
            kind: .individual,
            modifiedAtISO8601: "2026-06-11T00:00:00Z"
        )
    }

    // MARK: - Create / list / load / save / delete round trip

    func testCreateListLoadSaveDeleteRoundTrip() throws {
        let lib = try makeLibrary()
        let portfolio = samplePortfolio()

        // Create
        let id = try lib.create(portfolio)

        // List: one entry, label matches
        let summaries = try lib.list()
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries[0].id, id)
        XCTAssertEqual(summaries[0].label, portfolio.label)
        XCTAssertEqual(summaries[0].kind, portfolio.kind)

        // Load: full portfolio matches
        let loaded = try lib.load(id: id)
        XCTAssertEqual(loaded.label, portfolio.label)
        XCTAssertEqual(loaded.fields.count, portfolio.fields.count)

        // Save with changed label
        var updated = loaded
        updated.label = "Acme Updated"
        updated.modifiedAtISO8601 = "2026-06-11T01:00:00Z"
        try lib.save(updated, id: id)

        let afterSave = try lib.load(id: id)
        XCTAssertEqual(afterSave.label, "Acme Updated")

        // Index reflects the new label
        let summaries2 = try lib.list()
        XCTAssertEqual(summaries2.count, 1)
        XCTAssertEqual(summaries2[0].label, "Acme Updated")

        // Delete
        try lib.delete(id: id)
        let summaries3 = try lib.list()
        XCTAssertEqual(summaries3.count, 0)
        XCTAssertThrowsError(try lib.load(id: id))
    }

    // MARK: - List sorted by label

    func testListSortedByLabel() throws {
        let lib = try makeLibrary()
        _ = try lib.create(samplePortfolio(label: "Zeta Corp"))
        _ = try lib.create(samplePortfolio(label: "Alpha Inc"))
        _ = try lib.create(samplePortfolio(label: "Mid Co"))

        let summaries = try lib.list()
        XCTAssertEqual(summaries.map(\.label), ["Alpha Inc", "Mid Co", "Zeta Corp"])
    }

    // MARK: - Summary fields correct

    func testSummaryFieldsCorrect() throws {
        let lib = try makeLibrary()
        let portfolio = samplePortfolio()
        let id = try lib.create(portfolio)

        let summaries = try lib.list()
        XCTAssertEqual(summaries.count, 1)
        let summary = summaries[0]

        XCTAssertEqual(summary.id, id)
        XCTAssertEqual(summary.label, portfolio.label)
        XCTAssertEqual(summary.kind, portfolio.kind)
        XCTAssertEqual(summary.fieldCount, portfolio.fields.count)
        XCTAssertEqual(summary.conflicted, !portfolio.conflictedKeys.isEmpty)
        XCTAssertFalse(summary.createdAtISO8601.isEmpty)
        XCTAssertFalse(summary.modifiedAtISO8601.isEmpty)
    }

    // MARK: - Atomic save: no .tmp residue

    func testAtomicSaveNoTmpResidue() throws {
        let lib = try makeLibrary()
        let portfolio = samplePortfolio()
        let id = try lib.create(portfolio)

        var updated = portfolio
        updated.modifiedAtISO8601 = "2026-06-11T02:00:00Z"
        try lib.save(updated, id: id)

        // No *.tmp files should remain in the directory after a successful save.
        let contents = try FileManager.default.contentsOfDirectory(
            at: workDir,
            includingPropertiesForKeys: nil
        )
        let tmpFiles = contents.filter { $0.pathExtension == "tmp" }
        XCTAssertTrue(tmpFiles.isEmpty, "Unexpected .tmp files after atomic save: \(tmpFiles.map(\.lastPathComponent))")
    }

    func testStrayTmpFileIgnoredByList() throws {
        let lib = try makeLibrary()
        let id = try lib.create(samplePortfolio())

        // Drop a stray .tmp file alongside the real portfolio file.
        let strayTmp = workDir.appendingPathComponent("\(UUID().uuidString).ldaprofile.tmp")
        try Data("garbage".utf8).write(to: strayTmp)

        // list() must not surface the stray .tmp as an entry.
        let summaries = try lib.list()
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries[0].id, id)
    }

    // MARK: - List decrypts only the index

    func testListDecryptsOnlyIndex() throws {
        let lib = try makeLibrary()
        let idA = try lib.create(samplePortfolio(label: "Alpha Inc"))
        let idB = try lib.create(samplePortfolio(label: "Beta Co"))
        let idC = try lib.create(samplePortfolio(label: "Gamma Ltd"))

        // Corrupt the portfolio file for idB on disk (flip bytes in the ciphertext
        // region so AES-GCM fails on load but the magic header is preserved).
        let fileB = workDir.appendingPathComponent("\(idB.uuidString).ldaprofile")
        var rawB = try Data(contentsOf: fileB)
        guard rawB.count > 20 else {
            XCTFail("Portfolio file too small to corrupt safely")
            return
        }
        rawB[rawB.count - 4] ^= 0xFF
        try rawB.write(to: fileB)

        // list() uses only the index and must return all 3 summaries.
        let summaries = try lib.list()
        XCTAssertEqual(summaries.count, 3)

        let ids = Set(summaries.map(\.id))
        XCTAssertTrue(ids.contains(idA))
        XCTAssertTrue(ids.contains(idB))
        XCTAssertTrue(ids.contains(idC))

        // Corruption surfaces only on load.
        XCTAssertThrowsError(try lib.load(id: idB))
    }

    // MARK: - Orphan file (decryptable): index deleted, rebuilt on list

    func testOrphanDecryptableRebuildsByRealLabel() throws {
        let lib = try makeLibrary()
        let portfolio = samplePortfolio(label: "Rebuild Me")
        let id = try lib.create(portfolio)

        // Confirm a clean list sets lastListReconciled to false.
        _ = try lib.list()
        XCTAssertFalse(lib.lastListReconciled)

        // Delete the index file to simulate drift.
        let indexFile = workDir.appendingPathComponent("index.ldapidx")
        try FileManager.default.removeItem(at: indexFile)

        // list() must rebuild from the portfolio files and surface the real label.
        let summaries = try lib.list()
        XCTAssertTrue(lib.lastListReconciled, "lastListReconciled should be true after rebuilding a deleted index")
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries[0].id, id)
        XCTAssertEqual(summaries[0].label, "Rebuild Me")

        // A subsequent clean list should clear the flag.
        _ = try lib.list()
        XCTAssertFalse(lib.lastListReconciled, "lastListReconciled should be false after a clean list")
    }

    // MARK: - Orphan file (undecryptable): garbage file surfaced as placeholder

    func testOrphanUndecryptableSurfacesAsPlaceholder() throws {
        let lib = try makeLibrary()

        // Drop a garbage .ldaprofile file into the directory.
        let garbageID = UUID()
        let garbagePath = workDir.appendingPathComponent("\(garbageID.uuidString).ldaprofile")
        try Data("not a real container at all".utf8).write(to: garbagePath)

        let summaries = try lib.list()
        // The garbage entry must appear in the list.
        let garbageSummary = summaries.first { $0.id == garbageID }
        XCTAssertNotNil(garbageSummary, "Undecryptable orphan file must be surfaced in list()")
        if let gs = garbageSummary {
            let shortID = String(garbageID.uuidString.prefix(8))
            XCTAssertTrue(
                gs.label.contains(shortID),
                "Placeholder label should contain short ID '\(shortID)', got '\(gs.label)'"
            )
        }

        // load(id:) for the garbage entry must throw.
        XCTAssertThrowsError(try lib.load(id: garbageID))

        // delete(id:) must remove it without throwing.
        XCTAssertNoThrow(try lib.delete(id: garbageID))
        XCTAssertFalse(FileManager.default.fileExists(atPath: garbagePath.path))
    }

    // MARK: - Index entry whose file is missing is pruned

    func testMissingFileRemovedFromList() throws {
        let lib = try makeLibrary()
        let id = try lib.create(samplePortfolio(label: "To Be Deleted"))

        // Verify normal state.
        let before = try lib.list()
        XCTAssertEqual(before.count, 1)

        // Remove the portfolio file but leave the index intact.
        let portfolioFile = workDir.appendingPathComponent("\(id.uuidString).ldaprofile")
        try FileManager.default.removeItem(at: portfolioFile)

        // list() must prune the dangling index entry.
        let after = try lib.list()
        XCTAssertEqual(after.count, 0)
        XCTAssertTrue(lib.lastListReconciled, "lastListReconciled should be true after pruning a dangling index entry")
    }

    // MARK: - Cross-kind rejection

    func testIndexContainerRejectedAsPortfolio() throws {
        // The index container (LDAPIDX magic) must be rejected by the portfolio
        // container loader (LDAPROF magic expects a different magic byte sequence).
        let lib = try makeLibrary()

        // Create at least one portfolio to force the index file to be written.
        _ = try lib.create(samplePortfolio())

        let indexFile = workDir.appendingPathComponent("index.ldapidx")
        XCTAssertTrue(FileManager.default.fileExists(atPath: indexFile.path))

        // Attempt to load the index file as a portfolio must fail because the
        // magic bytes differ. We probe via ProfileStore.load which uses the LDAPROF
        // container; the LDAPIDX magic bytes will cause a corrupt error.
        XCTAssertThrowsError(
            try ProfileStore.load(from: indexFile, protection: .passphrase("does not matter"))
        ) { error in
            guard case DocumentIOError.corrupt = error else {
                XCTFail("Expected corrupt for mismatched magic (index vs profile), got \(error)")
                return
            }
        }
    }

    func testPortfolioFileRejectedAsIndex() throws {
        // A portfolio file (LDAPROF magic) must be rejected by the index reader
        // (LDAPIDX magic). We create a portfolio, then try to decode its file as
        // if it were an index file by passing it to the index container's load path.
        // Because the implementation internals use EncryptedContainer with distinct
        // magic bytes, we verify via the observable library behavior: a portfolio
        // UUID file is NOT included in the index, so a corruption of the index file
        // with portfolio bytes causes list() to rebuild.
        let lib = try makeLibrary()
        let id = try lib.create(samplePortfolio(label: "Cross-Kind Test"))

        // Overwrite the index file with the bytes of the portfolio file.
        let portfolioFile = workDir.appendingPathComponent("\(id.uuidString).ldaprofile")
        let indexFile = workDir.appendingPathComponent("index.ldapidx")
        let portfolioBytes = try Data(contentsOf: portfolioFile)
        try portfolioBytes.write(to: indexFile)

        // list() must detect the corrupt/mismatched index and rebuild.
        // It should still find the portfolio file and return one summary.
        let summaries = try lib.list()
        XCTAssertTrue(lib.lastListReconciled, "lastListReconciled should be true after rebuilding a corrupted index")
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries[0].id, id)
    }

    // MARK: - Export / import round trip

    func testExportImportPassphraseRoundTrip() throws {
        // Library root is workDir. Export must go to a location OUTSIDE workDir.
        let exportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PortfolioLibraryTests-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: exportDir) }

        let lib = try makeLibrary()
        let original = samplePortfolio(label: "Export Me")
        let id = try lib.create(original)

        let exportURL = exportDir.appendingPathComponent("export.ldaprofile")
        try lib.exportPortfolio(id: id, to: exportURL, protection: .passphrase("export-pass"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: exportURL.path))

        // Import into a fresh library backed by a different directory.
        let importDir = workDir.appendingPathComponent("import-target", isDirectory: true)
        try FileManager.default.createDirectory(at: importDir, withIntermediateDirectories: true)
        let lib2 = try PortfolioLibrary(rootDirectory: importDir)

        let importedID = try lib2.importPortfolio(from: exportURL, protection: .passphrase("export-pass"))
        let loaded = try lib2.load(id: importedID)
        XCTAssertEqual(loaded.label, original.label)
        XCTAssertEqual(loaded.fields.count, original.fields.count)
    }

    // MARK: - Import legacy JSON (no kind / modifiedAt) defaults kind to company

    func testImportLegacyJSONDefaultsKindToCompany() throws {
        // Build a legacy JSON payload (no "kind" or "modifiedAtISO8601" keys) and
        // seal it in the LDAPROF EncryptedContainer directly. Import must succeed
        // and default kind to .company.
        let legacyJSON = """
        {
          "label": "Legacy Corp",
          "fields": [],
          "sourceDocuments": [],
          "createdAtISO8601": "2025-01-01T00:00:00Z",
          "incomplete": false
        }
        """.data(using: .utf8)!

        // Seal using the same container / protection that ProfileStore.save would use.
        let legacyFile = workDir.appendingPathComponent("legacy.ldaprofile")
        let container = EncryptedContainer(
            magic: Array("LDAPROF".utf8),
            keychainService: "ai.openclaw.lda.profilekey",
            containerDescription: "Profile file"
        )
        try container.save(legacyJSON, to: legacyFile, protection: .passphrase("legacy-pass"))

        let lib = try makeLibrary()
        let importedID = try lib.importPortfolio(from: legacyFile, protection: .passphrase("legacy-pass"))
        let loaded = try lib.load(id: importedID)
        XCTAssertEqual(loaded.kind, .company, "Legacy JSON without 'kind' must default to .company")
        XCTAssertEqual(loaded.label, "Legacy Corp")
        XCTAssertEqual(
            loaded.modifiedAtISO8601, "2025-01-01T00:00:00Z",
            "Legacy JSON without 'modifiedAtISO8601' must fall back to createdAtISO8601"
        )

        // The index summary must carry the same fallback value.
        let summary = try XCTUnwrap(lib.list().first { $0.id == importedID })
        XCTAssertEqual(summary.modifiedAtISO8601, "2025-01-01T00:00:00Z")
    }

    // MARK: - Undecryptable orphan: notice fires once, placeholder is persisted

    func testUndecryptableOrphanNoticeFiresOnceAndPlaceholderPersists() throws {
        let lib = try makeLibrary()

        let garbageID = UUID()
        let garbagePath = workDir.appendingPathComponent("\(garbageID.uuidString).ldaprofile")
        try Data("garbage bytes, not a container".utf8).write(to: garbagePath)

        // First list reconciles: the placeholder is added and written to the index.
        let first = try lib.list()
        XCTAssertTrue(lib.lastListReconciled, "First list over an orphan must reconcile")
        XCTAssertEqual(first.count, 1)

        // Second list must be clean: the placeholder now comes from the persisted
        // index, no reconcile happens, and the one-time notice flag clears. If
        // this reconciles again, the rewrite inside readIndexOrRebuild silently
        // failed and every future list() would degrade to a full rebuild.
        let second = try lib.list()
        XCTAssertFalse(
            lib.lastListReconciled,
            "Placeholder must be persisted to the index; a repeat reconcile means the index rewrite silently failed"
        )
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(second[0].id, garbageID)
        let shortID = String(garbageID.uuidString.prefix(8))
        XCTAssertTrue(second[0].label.contains(shortID), "Placeholder label must survive the round trip through the index")
    }

    // MARK: - Duplicate index IDs: list() survives and deduplicates (C1 regression)

    func testDuplicateIndexIDsSurvive() throws {
        let lib = try makeLibrary()

        // Create one real portfolio so we have a valid encrypted index to build on.
        let id = try lib.create(samplePortfolio(label: "Dedup Target"))

        // Hand-craft an index that contains the same UUID twice. We write it
        // directly through the index container (bypassing the library's upsert
        // logic) to simulate a corrupt index that arrived from an external source.
        let indexContainer = EncryptedContainer(
            magic: Array("LDAPIDX".utf8),
            keychainService: "ai.openclaw.lda.libraryindexkey",
            containerDescription: "Portfolio index"
        )
        let duplicateSummary = PortfolioSummary(
            id: id,
            label: "Dedup Target",
            kind: .company,
            createdAtISO8601: "2026-06-11T00:00:00Z",
            modifiedAtISO8601: "2026-06-11T00:00:00Z",
            fieldCount: 1,
            conflicted: false
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Write [summary, summary] -- same UUID twice.
        let corruptPayload = try encoder.encode([duplicateSummary, duplicateSummary])
        let indexFile = workDir.appendingPathComponent("index.ldapidx")
        try indexContainer.save(
            corruptPayload,
            to: indexFile,
            protection: .keychain(account: "index")
        )

        // list() must not crash and must return exactly one entry.
        let summaries = try lib.list()
        XCTAssertEqual(summaries.count, 1, "Duplicate index IDs must be deduplicated to one entry")
        XCTAssertEqual(summaries[0].id, id)
    }

    // MARK: - Summary heal on load (I3)

    func testLoadHealsStaleIndexEntry() throws {
        let lib = try makeLibrary()
        let portfolio = samplePortfolio(label: "Original Label")
        let id = try lib.create(portfolio)

        // Manually corrupt the index entry's label to simulate a stale index
        // (as if a crash occurred between file write and index write in save()).
        let indexContainer = EncryptedContainer(
            magic: Array("LDAPIDX".utf8),
            keychainService: "ai.openclaw.lda.libraryindexkey",
            containerDescription: "Portfolio index"
        )
        let indexFile = workDir.appendingPathComponent("index.ldapidx")
        // Read the real index.
        let existingPlaintext = try indexContainer.load(
            from: indexFile,
            protection: .keychain(account: "index")
        )
        var summaries = try JSONDecoder().decode([PortfolioSummary].self, from: existingPlaintext)
        XCTAssertEqual(summaries.count, 1)
        summaries[0].label = "STALE WRONG LABEL"
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let corruptedPayload = try encoder.encode(summaries)
        try indexContainer.save(
            corruptedPayload,
            to: indexFile,
            protection: .keychain(account: "index")
        )

        // Verify the stale label is actually in the index before healing.
        let beforeHeal = try lib.list()
        XCTAssertEqual(beforeHeal[0].label, "STALE WRONG LABEL", "Pre-condition: index must carry the stale label")

        // load(id:) decrypts the file and heals the index.
        _ = try lib.load(id: id)

        // list() must now show the correct label.
        let afterHeal = try lib.list()
        XCTAssertEqual(afterHeal.count, 1)
        XCTAssertEqual(afterHeal[0].label, "Original Label", "load(id:) must heal the stale index entry")
    }

    // MARK: - delete() propagates errors but tolerates missing file (I3/I4 delete)

    func testDeleteNonexistentIDCleansIndexWithoutThrowing() throws {
        let lib = try makeLibrary()
        let id = try lib.create(samplePortfolio(label: "To Delete"))

        // Confirm it's in the list.
        XCTAssertEqual(try lib.list().count, 1)

        // Remove the portfolio file directly, leaving the index entry intact.
        let portfolioFile = workDir.appendingPathComponent("\(id.uuidString).ldaprofile")
        try FileManager.default.removeItem(at: portfolioFile)

        // delete(id:) on an already-absent file must not throw, and must still
        // clean up the index entry.
        XCTAssertNoThrow(try lib.delete(id: id))
        XCTAssertEqual(try lib.list().count, 0, "Index entry must be removed even when the file was already gone")
    }

    // MARK: - list() propagates directory enumeration failure (I4)

    func testListPropagatesEnumerationFailure() throws {
        // Make the library root unreadable so contentsOfDirectory throws.
        let lib = try makeLibrary()
        _ = try lib.create(samplePortfolio())

        // Remove read+execute permission on the root directory.
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o000)],
            ofItemAtPath: workDir.path
        )
        defer {
            // Restore before tearDown tries to remove the directory.
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o755)],
                ofItemAtPath: workDir.path
            )
        }

        // list() must throw rather than silently return an empty array.
        XCTAssertThrowsError(try lib.list(), "list() must propagate directory enumeration failure")
    }

    // MARK: - lastIndexPersistFailed (I1)

    func testLastIndexPersistFailedClearsOnSuccessfulWrite() throws {
        let lib = try makeLibrary()
        // Initial state: not failed.
        XCTAssertFalse(lib.lastIndexPersistFailed)

        // Create a portfolio to write an index.
        _ = try lib.create(samplePortfolio())
        XCTAssertFalse(lib.lastIndexPersistFailed)

        // A successful save clears the flag.
        let id = try lib.create(samplePortfolio(label: "Second"))
        XCTAssertFalse(lib.lastIndexPersistFailed)

        // A successful delete clears the flag.
        try lib.delete(id: id)
        XCTAssertFalse(lib.lastIndexPersistFailed)
    }

    // MARK: - exportPortfolio rejects destinations inside the library directory

    func testExportToLibraryDirectoryThrows() throws {
        let lib = try makeLibrary()
        let id = try lib.create(samplePortfolio())

        // Destination is inside the library root directory.
        let insideLib = workDir.appendingPathComponent("inside-lib.ldaprofile")
        XCTAssertThrowsError(
            try lib.exportPortfolio(id: id, to: insideLib, protection: .passphrase("p"))
        ) { error in
            // Any error type is acceptable as long as it throws.
            _ = error
        }

        // Destination inside a subdirectory of the library root is also rejected.
        let subdir = workDir.appendingPathComponent("subdir", isDirectory: true)
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        let insideSubdir = subdir.appendingPathComponent("also-inside.ldaprofile")
        XCTAssertThrowsError(
            try lib.exportPortfolio(id: id, to: insideSubdir, protection: .passphrase("p"))
        )
    }

    // MARK: - lastListReconciled state

    func testLastListReconciledLifecycle() throws {
        let lib = try makeLibrary()
        _ = try lib.create(samplePortfolio())

        // Initial state: false before any list.
        XCTAssertFalse(lib.lastListReconciled)

        // Clean list: false.
        _ = try lib.list()
        XCTAssertFalse(lib.lastListReconciled)

        // Delete the index to force a rebuild.
        let indexFile = workDir.appendingPathComponent("index.ldapidx")
        try FileManager.default.removeItem(at: indexFile)

        // Rebuilding list: true.
        _ = try lib.list()
        XCTAssertTrue(lib.lastListReconciled)

        // Next clean list: false again.
        _ = try lib.list()
        XCTAssertFalse(lib.lastListReconciled)
    }
}
