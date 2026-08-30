//
//  DocumentVaultTests.swift
//  LDACoreTests
//
//  The staging vault: documents enter it once, get an opaque handle, and every
//  later operation refers to the handle instead of the path. The vault is what
//  lets the MCP tool surface stop carrying file paths (the paths themselves are
//  PII: legal folders are named after the parties), so these tests care about
//  two things beyond plain storage correctness:
//
//   - handles are opaque: random hex, no relation to the original name;
//   - the on-disk layout never embeds the original filename; it survives only
//     inside the registry, reserved for human-facing export naming.
//
//  Every fixture lives under FileManager.temporaryDirectory so the tests are
//  hermetic. No Keychain is touched: the vault is encrypted at rest (phase 5)
//  and every test injects passphrase protection through the initializer seam,
//  so the vault master key account is never created by a test run.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
import CoreText
@testable import LDACore

final class DocumentVaultTests: XCTestCase {

    private var workDir: URL!
    private var vaultRoot: URL!
    private var vault: DocumentVault!

    /// Passphrase protection so no test touches the real Keychain.
    private static let protection = MappingProtection.passphrase("vault-unit-test-passphrase")

    /// A deliberately party-identifying fixture name, mirroring how PRC legal
    /// practice names files. The vault must keep this OUT of its object tree.
    private let sensitiveName = "ZhangSan-v-LiSi-divorce-agreement"

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocumentVaultTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        vaultRoot = workDir.appendingPathComponent("vault", isDirectory: true)
        vault = DocumentVault(rootDirectory: vaultRoot, protection: Self.protection)
    }

    /// A fresh instance over the same root and key, as a reopening app would.
    private func reopenedVault() -> DocumentVault {
        DocumentVault(rootDirectory: vaultRoot, protection: Self.protection)
    }

    override func tearDownWithError() throws {
        if let workDir, FileManager.default.fileExists(atPath: workDir.path) {
            try? FileManager.default.removeItem(at: workDir)
        }
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    @discardableResult
    private func writeFixture(named name: String, contents: String = "Mail jane@example.com now.") throws -> URL {
        let url = workDir.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func stageFixture(
        named name: String,
        contents: String = "Mail jane@example.com now."
    ) throws -> VaultEntry {
        let url = try writeFixture(named: name, contents: contents)
        return try vault.stage(fileURL: url, stagedAtISO8601: "2026-08-30T00:00:00Z")
    }

    // MARK: - Handle allocation

    func testStagingAllocatesDistinctOpaqueHandles() throws {
        // Arrange and act
        let first = try stageFixture(named: "\(sensitiveName).txt")
        let second = try stageFixture(named: "another-matter.txt")

        // Assert: doc_ prefix plus at least 12 hex characters, all distinct.
        for entry in [first, second] {
            XCTAssertTrue(
                entry.handle.range(of: "^doc_[0-9a-f]{12,}$", options: .regularExpression) != nil,
                "handle must be doc_ plus random hex, got \(entry.handle)"
            )
            XCTAssertFalse(
                entry.handle.contains("Zhang") || entry.handle.contains("divorce"),
                "handle must carry nothing derived from the name"
            )
        }
        XCTAssertNotEqual(first.handle, second.handle)
    }

    func testStagedEntryRecordsNeutralMetadataAndKeepsTheOriginalNameOnlyInTheRegistry() throws {
        let contents = "Wire the retainer to account 6225880100000000123."
        let entry = try stageFixture(named: "\(sensitiveName).txt", contents: contents)

        // Neutral metadata.
        XCTAssertEqual(entry.kind, .original)
        XCTAssertEqual(entry.format, "txt")
        XCTAssertEqual(entry.byteCount, Data(contents.utf8).count)
        XCTAssertEqual(entry.stagedAtISO8601, "2026-08-30T00:00:00Z")
        XCTAssertNil(entry.pageCount, "a text file has no page count")

        // The original name survives for export naming, in the registry only.
        XCTAssertEqual(entry.originalFilename, "\(sensitiveName).txt")

        // The object tree must not embed the original name anywhere.
        XCTAssertFalse(
            entry.relativePath.contains(sensitiveName),
            "stored path must not carry the original filename: \(entry.relativePath)"
        )
        let enumerated = try FileManager.default.subpathsOfDirectory(
            atPath: vaultRoot.appendingPathComponent(DocumentVault.objectsDirectoryName).path
        )
        for path in enumerated {
            XCTAssertFalse(path.contains(sensitiveName), "vault tree leaked the name into \(path)")
        }
    }

    func testStagingCopiesTheBytesRatherThanMovingTheSource() throws {
        let source = try writeFixture(named: "brief.txt", contents: "hello vault")
        let entry = try vault.stage(fileURL: source, stagedAtISO8601: "2026-08-30T00:00:00Z")

        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "the source stays where it was")
        let staged = try vault.readDocumentBytes(handle: entry.handle)
        XCTAssertEqual(String(decoding: staged, as: UTF8.self), "hello vault")
    }

    func testStagingAMissingFileThrows() {
        let missing = workDir.appendingPathComponent("nope.txt")
        XCTAssertThrowsError(
            try vault.stage(fileURL: missing, stagedAtISO8601: "2026-08-30T00:00:00Z")
        ) { error in
            guard case DocumentVaultError.sourceUnreadable = error else {
                return XCTFail("expected sourceUnreadable, got \(error)")
            }
        }
    }

    func testAnUnknownExtensionIsNormalizedToTxt() throws {
        // An exotic extension could itself carry matter information, and the
        // importer treats unknown extensions as text anyway.
        let entry = try stageFixture(named: "agreement.contract-of-zhang")
        XCTAssertEqual(entry.format, "txt")
        XCTAssertTrue(entry.relativePath.hasSuffix(".txt"))
    }

    func testPdfStagingRecordsThePageCount() throws {
        let pdfURL = workDir.appendingPathComponent("two-pages.pdf")
        try Self.makePDF(at: pdfURL, pages: [["Page one."], ["Page two."]])

        let entry = try vault.stage(fileURL: pdfURL, stagedAtISO8601: "2026-08-30T00:00:00Z")

        XCTAssertEqual(entry.format, "pdf")
        XCTAssertEqual(entry.pageCount, 2)
    }

    // MARK: - Registry persistence

    func testRegistrySurvivesReload() throws {
        let staged = try stageFixture(named: "\(sensitiveName).txt")

        // A fresh instance over the same root sees the same entries.
        let reopened = reopenedVault()
        let listed = try reopened.list()

        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed.first, staged)
    }

    func testListIsOrderedByStagingTime() throws {
        let older = try writeFixture(named: "a.txt")
        let newer = try writeFixture(named: "b.txt")
        let second = try vault.stage(fileURL: newer, stagedAtISO8601: "2026-08-30T02:00:00Z")
        let first = try vault.stage(fileURL: older, stagedAtISO8601: "2026-08-30T01:00:00Z")

        let handles = try vault.list().map(\.handle)
        XCTAssertEqual(handles, [first.handle, second.handle])
    }

    // MARK: - Derived artifacts

    func testPrepareThenCommitRegistersADerivedArtifact() throws {
        let original = try stageFixture(named: "\(sensitiveName).txt")

        let slot = try vault.prepareDerived(kind: .redacted)
        XCTAssertTrue(
            slot.handle.range(of: "^red_[0-9a-f]{12,}$", options: .regularExpression) != nil,
            "derived handles carry their own prefix, got \(slot.handle)"
        )
        let produced = slot.directory.appendingPathComponent("original_redacted.txt")
        try Data("Mail {EMAIL_1} now.".utf8).write(to: produced)
        let mapping = slot.directory.appendingPathComponent("original_redacted.ldamap")
        try Data("sealed".utf8).write(to: mapping)

        let entry = try vault.commit(
            slot: slot,
            primaryFile: produced,
            stagedAtISO8601: "2026-08-30T00:01:00Z",
            sourceHandle: original.handle,
            mappingFile: mapping,
            mappingAccountBase: slot.handle
        )

        XCTAssertEqual(entry.handle, slot.handle)
        XCTAssertEqual(entry.kind, .redacted)
        XCTAssertEqual(entry.format, "txt")
        XCTAssertEqual(entry.sourceHandle, original.handle)
        XCTAssertEqual(entry.mappingAccountBase, slot.handle)
        XCTAssertNil(entry.originalFilename, "derived artifacts record no name of their own")

        // The mapping location round-trips through the registry.
        let mappingURL = try vault.mappingFileURL(forHandle: entry.handle)
        XCTAssertEqual(mappingURL.standardizedFileURL.path, mapping.standardizedFileURL.path)

        // And a reloaded vault still lists both entries.
        let listed = try reopenedVault().list()
        XCTAssertEqual(Set(listed.map(\.handle)), [original.handle, entry.handle])
    }

    func testCommitRefusesAPrimaryFileOutsideTheVault() throws {
        let slot = try vault.prepareDerived(kind: .redacted)
        defer { vault.abort(slot: slot) }
        let outside = try writeFixture(named: "outside.txt")

        XCTAssertThrowsError(
            try vault.commit(
                slot: slot,
                primaryFile: outside,
                stagedAtISO8601: "2026-08-30T00:01:00Z",
                sourceHandle: nil,
                mappingFile: nil,
                mappingAccountBase: nil
            )
        ) { error in
            guard case DocumentVaultError.artifactOutsideVault = error else {
                return XCTFail("expected artifactOutsideVault, got \(error)")
            }
        }
    }

    func testAbortRemovesTheSlotDirectoryAndRegistersNothing() throws {
        let slot = try vault.prepareDerived(kind: .restored)
        try Data("half written".utf8).write(to: slot.directory.appendingPathComponent("restored.txt"))

        vault.abort(slot: slot)

        XCTAssertFalse(FileManager.default.fileExists(atPath: slot.directory.path))
        XCTAssertTrue(try vault.list().isEmpty)
    }

    func testPrepareDerivedRefusesTheOriginalKind() {
        XCTAssertThrowsError(try vault.prepareDerived(kind: .original))
    }

    // MARK: - Reading

    func testReadDocumentBytesOnAnUnknownHandleThrows() {
        XCTAssertThrowsError(try vault.readDocumentBytes(handle: "doc_ffffffffffff")) { error in
            guard case DocumentVaultError.unknownHandle(let handle) = error else {
                return XCTFail("expected unknownHandle, got \(error)")
            }
            XCTAssertEqual(handle, "doc_ffffffffffff")
        }
    }

    func testWithPlaintextFileURLYieldsAReadableFile() throws {
        let entry = try stageFixture(named: "brief.txt", contents: "readable")
        let text = try vault.withPlaintextFileURL(handle: entry.handle) { url in
            try String(contentsOf: url, encoding: .utf8)
        }
        XCTAssertEqual(text, "readable")
    }

    // MARK: - Export

    func testExportRefusesAnOriginal() throws {
        let entry = try stageFixture(named: "\(sensitiveName).txt")
        XCTAssertThrowsError(try vault.exportToOutbox(handle: entry.handle)) { error in
            guard case DocumentVaultError.notExportable = error else {
                return XCTFail("expected notExportable, got \(error)")
            }
        }
    }

    func testExportCopiesARedactedArtifactIntoTheOutboxNamedAfterTheOriginal() throws {
        // Stage an original with a human name, derive a redacted artifact from
        // it, and export: the OUTBOX copy gets the human-facing name back,
        // because the outbox is where the human collects results.
        let original = try stageFixture(named: "\(sensitiveName).txt")
        let slot = try vault.prepareDerived(kind: .redacted)
        let produced = slot.directory.appendingPathComponent("original_redacted.txt")
        try Data("Mail {EMAIL_1} now.".utf8).write(to: produced)
        let redacted = try vault.commit(
            slot: slot,
            primaryFile: produced,
            stagedAtISO8601: "2026-08-30T00:01:00Z",
            sourceHandle: original.handle,
            mappingFile: nil,
            mappingAccountBase: nil
        )

        let exported = try vault.exportToOutbox(handle: redacted.handle)

        XCTAssertEqual(exported.deletingLastPathComponent().path, vault.outboxDirectory.path)
        XCTAssertEqual(exported.lastPathComponent, "\(sensitiveName)_redacted.txt")
        XCTAssertEqual(
            try String(contentsOf: exported, encoding: .utf8),
            "Mail {EMAIL_1} now."
        )
    }

    func testExportTwiceDoesNotOverwriteTheFirstCopy() throws {
        let original = try stageFixture(named: "matter.txt")
        let slot = try vault.prepareDerived(kind: .redacted)
        let produced = slot.directory.appendingPathComponent("original_redacted.txt")
        try Data("first".utf8).write(to: produced)
        let redacted = try vault.commit(
            slot: slot,
            primaryFile: produced,
            stagedAtISO8601: "2026-08-30T00:01:00Z",
            sourceHandle: original.handle,
            mappingFile: nil,
            mappingAccountBase: nil
        )

        let first = try vault.exportToOutbox(handle: redacted.handle)
        let second = try vault.exportToOutbox(handle: redacted.handle)

        XCTAssertNotEqual(first.lastPathComponent, second.lastPathComponent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }

    // MARK: - Encryption at rest

    /// Raw bytes of a file inside the vault, read without going through the
    /// vault API. This is the attacker's view: cat, sudo, a backup agent.
    private func rawBytes(atVaultRelativePath relativePath: String) throws -> Data {
        let url = vaultRoot.appendingPathComponent(relativePath)
        return try XCTUnwrap(
            FileManager.default.contents(atPath: url.path),
            "expected a file at \(relativePath)"
        )
    }

    func testStagedObjectIsCiphertextOnDisk() throws {
        let secret = "Wire the retainer to account 6225880100000000123."
        let entry = try stageFixture(named: "\(sensitiveName).txt", contents: secret)

        let raw = try rawBytes(atVaultRelativePath: entry.relativePath)
        XCTAssertTrue(
            raw.starts(with: DocumentVault.objectMagic),
            "a stored object must be a vault container, not a plain copy"
        )
        XCTAssertFalse(
            String(decoding: raw, as: UTF8.self).contains("retainer"),
            "cat on a staged original must return ciphertext"
        )

        // The vault API still round-trips the plaintext.
        let read = try vault.readDocumentBytes(handle: entry.handle)
        XCTAssertEqual(String(decoding: read, as: UTF8.self), secret)
    }

    func testRegistryIsEncryptedAndCarriesNoFilenameBytes() throws {
        try stageFixture(named: "\(sensitiveName).txt")

        let sealedURL = vaultRoot.appendingPathComponent(DocumentVault.sealedRegistryFileName)
        let plainURL = vaultRoot.appendingPathComponent(DocumentVault.registryFileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sealedURL.path))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: plainURL.path),
            "an encrypted vault must not keep a plaintext registry"
        )

        let raw = try rawBytes(atVaultRelativePath: DocumentVault.sealedRegistryFileName)
        XCTAssertTrue(raw.starts(with: DocumentVault.registryMagic))
        XCTAssertFalse(
            String(decoding: raw, as: UTF8.self).contains(sensitiveName),
            "the registry holds the one PII metadata item and must be ciphertext"
        )
    }

    func testCommittedArtifactIsCiphertextOnDiskAndReadsBack() throws {
        let original = try stageFixture(named: "\(sensitiveName).txt")
        let slot = try vault.prepareDerived(kind: .redacted)
        let produced = slot.directory.appendingPathComponent("original_redacted.txt")
        try Data("Mail {EMAIL_1} now.".utf8).write(to: produced)

        let entry = try vault.commit(
            slot: slot,
            primaryFile: produced,
            stagedAtISO8601: "2026-08-30T00:01:00Z",
            sourceHandle: original.handle,
            mappingFile: nil,
            mappingAccountBase: nil
        )

        XCTAssertEqual(entry.byteCount, Data("Mail {EMAIL_1} now.".utf8).count,
                       "byteCount records the plaintext size, not the container size")
        let raw = try rawBytes(atVaultRelativePath: entry.relativePath)
        XCTAssertTrue(raw.starts(with: DocumentVault.objectMagic))
        XCTAssertFalse(String(decoding: raw, as: UTF8.self).contains("{EMAIL_1}"))
        XCTAssertEqual(
            String(decoding: try vault.readDocumentBytes(handle: entry.handle), as: UTF8.self),
            "Mail {EMAIL_1} now."
        )
    }

    func testCommitRemovesStrayUncommittedFilesFromTheSlotDirectory() throws {
        // The anonymize pipeline can write companions (a review PDF) next to
        // the primary artifact. Nothing registers them, so nothing could ever
        // read them back; leaving them behind would keep plaintext in the
        // vault forever.
        let slot = try vault.prepareDerived(kind: .redacted)
        let produced = slot.directory.appendingPathComponent("doc_redacted.txt")
        try Data("Mail {EMAIL_1} now.".utf8).write(to: produced)
        let mapping = slot.directory.appendingPathComponent("doc_redacted.ldamap")
        try Data("sealed-mapping-bytes".utf8).write(to: mapping)
        let stray = slot.directory.appendingPathComponent("doc_review.pdf")
        try Data("stray plaintext companion".utf8).write(to: stray)

        try vault.commit(
            slot: slot,
            primaryFile: produced,
            stagedAtISO8601: "2026-08-30T00:01:00Z",
            sourceHandle: nil,
            mappingFile: mapping,
            mappingAccountBase: nil
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: stray.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: produced.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: mapping.path))
        // The mapping sidecar is already an encrypted container of its own
        // kind; commit must record it untouched, never re-wrap it.
        XCTAssertEqual(
            try rawBytes(atVaultRelativePath: "objects/\(slot.handle)/doc_redacted.ldamap"),
            Data("sealed-mapping-bytes".utf8)
        )
    }

    func testWithPlaintextFileURLDecryptsToAGuardedScratchFileAndRemovesIt() throws {
        let entry = try stageFixture(named: "brief.txt", contents: "scratch me")

        var scratchURL: URL?
        let text = try vault.withPlaintextFileURL(handle: entry.handle) { url in
            scratchURL = url
            // Inside the vault root, so the PreToolUse hook guards it and it
            // never lands in a world-readable temporary directory.
            XCTAssertTrue(
                url.standardizedFileURL.path.hasPrefix(vaultRoot.standardizedFileURL.path),
                "scratch plaintext must stay inside the vault root: \(url.path)"
            )
            XCTAssertEqual(
                url.deletingLastPathComponent().lastPathComponent,
                DocumentVault.scratchDirectoryName
            )
            // Owner-only permissions from birth.
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.int16Value, 0o600)
            // The logical format survives so importers can dispatch on it.
            XCTAssertEqual(url.pathExtension, "txt")
            return try String(contentsOf: url, encoding: .utf8)
        }

        XCTAssertEqual(text, "scratch me")
        let survivor = try XCTUnwrap(scratchURL)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: survivor.path),
            "the decrypted scratch file must be gone once the body returns"
        )
    }

    func testScratchFileIsRemovedEvenWhenTheBodyThrows() throws {
        let entry = try stageFixture(named: "brief.txt", contents: "throwing body")
        struct BodyFailure: Error {}

        var scratchURL: URL?
        XCTAssertThrowsError(
            try vault.withPlaintextFileURL(handle: entry.handle) { url -> Void in
                scratchURL = url
                throw BodyFailure()
            }
        )
        let survivor = try XCTUnwrap(scratchURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: survivor.path))
    }

    func testWithPlaintextFileURLsDecryptsAllMembersAndRemovesAll() throws {
        let first = try stageFixture(named: "a.txt", contents: "alpha")
        let second = try stageFixture(named: "b.txt", contents: "beta")

        var seen: [URL] = []
        let texts: [String] = try vault.withPlaintextFileURLs(
            handles: [first.handle, second.handle]
        ) { urls in
            seen = urls
            return try urls.map { try String(contentsOf: $0, encoding: .utf8) }
        }

        XCTAssertEqual(texts, ["alpha", "beta"])
        XCTAssertEqual(seen.count, 2)
        for url in seen {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }

    func testAWrongKeyCannotReadTheVault() throws {
        let entry = try stageFixture(named: "brief.txt", contents: "locked")

        let wrongKey = DocumentVault(
            rootDirectory: vaultRoot,
            protection: .passphrase("not-the-vault-passphrase")
        )
        XCTAssertThrowsError(try wrongKey.readDocumentBytes(handle: entry.handle))
        XCTAssertThrowsError(try wrongKey.list())
    }

    // MARK: - Migration from the plaintext form

    /// Handcraft the pre-encryption on-disk form: a plaintext registry.json
    /// plus plaintext object files, exactly as the phase 4 vault wrote them.
    private func buildPlaintextFormVault(
        originalBody: String,
        redactedBody: String,
        mappingBytes: Data
    ) throws {
        let objects = vaultRoot.appendingPathComponent("objects", isDirectory: true)
        let docDir = objects.appendingPathComponent("doc_aaaaaaaaaaaa", isDirectory: true)
        let redDir = objects.appendingPathComponent("red_bbbbbbbbbbbb", isDirectory: true)
        try FileManager.default.createDirectory(at: docDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: redDir, withIntermediateDirectories: true)
        try Data(originalBody.utf8).write(to: docDir.appendingPathComponent("original.txt"))
        try Data(redactedBody.utf8).write(to: redDir.appendingPathComponent("original_redacted.txt"))
        try mappingBytes.write(to: redDir.appendingPathComponent("original_redacted.ldamap"))

        let registryJSON = """
        {
          "entries" : [
            {
              "byteCount" : \(Data(originalBody.utf8).count),
              "format" : "txt",
              "handle" : "doc_aaaaaaaaaaaa",
              "kind" : "original",
              "originalFilename" : "\(sensitiveName).txt",
              "relativePath" : "objects/doc_aaaaaaaaaaaa/original.txt",
              "stagedAtISO8601" : "2026-08-29T00:00:00Z"
            },
            {
              "byteCount" : \(Data(redactedBody.utf8).count),
              "format" : "txt",
              "handle" : "red_bbbbbbbbbbbb",
              "kind" : "redacted",
              "mappingAccountBase" : "red_bbbbbbbbbbbb",
              "mappingRelativePath" : "objects/red_bbbbbbbbbbbb/original_redacted.ldamap",
              "relativePath" : "objects/red_bbbbbbbbbbbb/original_redacted.txt",
              "sourceHandle" : "doc_aaaaaaaaaaaa",
              "stagedAtISO8601" : "2026-08-29T00:01:00Z"
            }
          ],
          "version" : 1
        }
        """
        try Data(registryJSON.utf8).write(
            to: vaultRoot.appendingPathComponent(DocumentVault.registryFileName)
        )
    }

    func testOpeningAPlaintextFormVaultMigratesItInPlaceWithoutLosingEntries() throws {
        let originalBody = "Mail jane@example.com about \(sensitiveName)."
        let redactedBody = "Mail {EMAIL_1} about the matter."
        let mappingBytes = Data("pretend-ldamap-container".utf8)
        try buildPlaintextFormVault(
            originalBody: originalBody,
            redactedBody: redactedBody,
            mappingBytes: mappingBytes
        )
        XCTAssertFalse(vault.isEncryptionAtRestActive(), "the plaintext form must be reported honestly")

        // The first open migrates: entries survive, plaintext is gone.
        let entries = try vault.list()
        XCTAssertEqual(entries.map(\.handle), ["doc_aaaaaaaaaaaa", "red_bbbbbbbbbbbb"])
        XCTAssertEqual(entries.first?.originalFilename, "\(sensitiveName).txt")

        XCTAssertTrue(vault.isEncryptionAtRestActive())
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: vaultRoot.appendingPathComponent(DocumentVault.registryFileName).path
        ))
        for relativePath in [
            "objects/doc_aaaaaaaaaaaa/original.txt",
            "objects/red_bbbbbbbbbbbb/original_redacted.txt"
        ] {
            let raw = try rawBytes(atVaultRelativePath: relativePath)
            XCTAssertTrue(raw.starts(with: DocumentVault.objectMagic), relativePath)
        }
        // The mapping sidecar is already its own encrypted container kind and
        // must migrate untouched.
        XCTAssertEqual(
            try rawBytes(atVaultRelativePath: "objects/red_bbbbbbbbbbbb/original_redacted.ldamap"),
            mappingBytes
        )

        // The content still round-trips through the vault API.
        XCTAssertEqual(
            String(decoding: try vault.readDocumentBytes(handle: "doc_aaaaaaaaaaaa"), as: UTF8.self),
            originalBody
        )
        XCTAssertEqual(
            String(decoding: try vault.readDocumentBytes(handle: "red_bbbbbbbbbbbb"), as: UTF8.self),
            redactedBody
        )

        // And no file under the migrated root still carries the plaintext.
        let survivors = try FileManager.default.subpathsOfDirectory(atPath: vaultRoot.path)
        for path in survivors {
            let url = vaultRoot.appendingPathComponent(path)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { continue }
            let text = String(decoding: try XCTUnwrap(
                FileManager.default.contents(atPath: url.path)
            ), as: UTF8.self)
            XCTAssertFalse(text.contains("jane@example.com"), "plaintext survived in \(path)")
            XCTAssertFalse(text.contains(sensitiveName), "the filename survived in \(path)")
        }
    }

    func testMigrationIsIdempotentWhenResumedAfterAPartialRun() throws {
        // Simulate a crash between object encryption and registry removal:
        // the plaintext registry still exists, but one object is already a
        // sealed container. Migration must skip it rather than double-wrap.
        try buildPlaintextFormVault(
            originalBody: "Mail jane@example.com now.",
            redactedBody: "Mail {EMAIL_1} now.",
            mappingBytes: Data("pretend-ldamap-container".utf8)
        )
        _ = try vault.list()
        // Recreate the crash by restoring the plaintext registry AFTER the
        // objects were sealed.
        let registryJSON = try rawBytes(atVaultRelativePath: DocumentVault.sealedRegistryFileName)
        XCTAssertTrue(registryJSON.starts(with: DocumentVault.registryMagic))
        try Data("""
        {"entries":[{"byteCount":26,"format":"txt","handle":"doc_aaaaaaaaaaaa","kind":"original","originalFilename":"\(sensitiveName).txt","relativePath":"objects/doc_aaaaaaaaaaaa/original.txt","stagedAtISO8601":"2026-08-29T00:00:00Z"}],"version":1}
        """.utf8).write(to: vaultRoot.appendingPathComponent(DocumentVault.registryFileName))

        let entries = try vault.list()
        XCTAssertEqual(entries.map(\.handle), ["doc_aaaaaaaaaaaa"])
        XCTAssertEqual(
            String(decoding: try vault.readDocumentBytes(handle: "doc_aaaaaaaaaaaa"), as: UTF8.self),
            "Mail jane@example.com now."
        )
        XCTAssertTrue(vault.isEncryptionAtRestActive())
    }

    // MARK: - Attest state helpers

    func testEncryptionStateReportingIsDerivedFromDisk() throws {
        // A fresh vault encrypts by construction.
        XCTAssertTrue(vault.isEncryptionAtRestActive())

        // A plaintext registry on disk means the guarantee does not hold yet.
        try FileManager.default.createDirectory(at: vaultRoot, withIntermediateDirectories: true)
        try Data("{\"entries\":[],\"version\":1}".utf8).write(
            to: vaultRoot.appendingPathComponent(DocumentVault.registryFileName)
        )
        XCTAssertFalse(vault.isEncryptionAtRestActive())

        // Any registry read migrates and the report flips back.
        _ = try vault.list()
        XCTAssertTrue(vault.isEncryptionAtRestActive())
    }

    func testKeyProtectionDescriptionNamesTheActiveMode() {
        XCTAssertEqual(vault.keyProtectionDescription, "passphrase")

        let keychainVault = DocumentVault(
            rootDirectory: vaultRoot,
            protection: .keychain(account: DocumentVault.masterKeyAccount)
        )
        let previous = KeychainAccessPolicy.requireUserPresence
        defer { KeychainAccessPolicy.requireUserPresence = previous }
        KeychainAccessPolicy.requireUserPresence = false
        XCTAssertEqual(keychainVault.keyProtectionDescription, "keychain-silent")
        KeychainAccessPolicy.requireUserPresence = true
        XCTAssertEqual(keychainVault.keyProtectionDescription, "keychain-userpresence")
    }

    func testDefaultProtectionHonorsTheEnvironmentPassphrase() {
        let fromEnvironment = DocumentVault.defaultProtection(
            environment: [DocumentVault.passphraseEnvironmentKey: "env-secret"]
        )
        guard case .passphrase(let value) = fromEnvironment else {
            return XCTFail("expected passphrase protection from the environment")
        }
        XCTAssertEqual(value, "env-secret")

        let fallback = DocumentVault.defaultProtection(environment: [:])
        guard case .keychain(let account) = fallback else {
            return XCTFail("expected the Keychain master key by default")
        }
        XCTAssertEqual(account, DocumentVault.masterKeyAccount)
    }

    // MARK: - PDF fixture helper

    private static let pageBounds = CGRect(x: 0, y: 0, width: 612, height: 792)

    static func makePDF(at url: URL, pages: [[String]]) throws {
        guard let consumer = CGDataConsumer(url: url as CFURL) else {
            throw XCTSkip("Could not create a PDF data consumer for the test fixture")
        }
        var mediaBox = pageBounds
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw XCTSkip("Could not create a PDF graphics context for the test fixture")
        }

        let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let black = CGColor(colorSpace: space, components: [0, 0, 0, 1])!

        for lines in pages {
            context.beginPage(mediaBox: &mediaBox)
            var y: CGFloat = pageBounds.height - 72
            for line in lines {
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: black
                ]
                let attributed = NSAttributedString(string: line, attributes: attributes)
                let ctLine = CTLineCreateWithAttributedString(attributed)
                context.textPosition = CGPoint(x: 72, y: y)
                CTLineDraw(ctLine, context)
                y -= 28
            }
            context.endPage()
        }
        context.closePDF()
    }
}

// MARK: - Crash-leftover scratch sweep (security audit F-001)

extension DocumentVaultTests {

    private var scratchDir: URL {
        vaultRoot.appendingPathComponent(DocumentVault.scratchDirectoryName, isDirectory: true)
    }

    /// A PID that belonged to a real process that has since exited: spawn
    /// /usr/bin/true and wait for it. Recently valid, provably dead.
    private func deadProcessID() throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        return process.processIdentifier
    }

    private func plantScratchFile(named name: String) throws -> URL {
        try FileManager.default.createDirectory(
            at: scratchDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let url = scratchDir.appendingPathComponent(name)
        try Data("LEFTOVER PLAINTEXT".utf8).write(to: url)
        return url
    }

    /// A scratch file whose owning process died (a crash during anonymize)
    /// must be removed by the next vault use, or "encrypted at rest" is a lie
    /// for exactly the documents that were in flight at crash time.
    func testDeadProcessScratchLeftoverIsSweptOnNextUse() throws {
        let deadPID = try deadProcessID()
        let leftover = try plantScratchFile(named: "pt_\(deadPID)_abcdef123456.txt")

        _ = try vault.list()

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: leftover.path),
            "a dead process's scratch plaintext must be swept on the next vault use"
        )
    }

    /// A scratch file with no parseable owner (the pre-PID naming) is treated
    /// as a leftover and swept: only vault code writes here, and every live
    /// writer tags its files with its own PID.
    func testUnparseableScratchNameIsSweptOnNextUse() throws {
        let leftover = try plantScratchFile(named: "pt_abcdef123456.txt")

        _ = try vault.list()

        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path))
    }

    /// A live process's scratch file is IN USE and must survive the sweep:
    /// the CLI and the MCP server can operate on one vault concurrently.
    func testLiveProcessScratchFileSurvivesSweep() throws {
        let livePID = ProcessInfo.processInfo.processIdentifier
        let inUse = try plantScratchFile(named: "pt_\(livePID)_abcdef123456.txt")

        _ = try vault.list()

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: inUse.path),
            "a live process's scratch file must not be swept out from under it"
        )
        try? FileManager.default.removeItem(at: inUse)
    }

    /// The scratch files the vault itself creates carry the creator's PID, so
    /// the sweep can tell in-use files from crash leftovers.
    func testScratchFilesAreTaggedWithTheCreatorPID() throws {
        let source = workDir.appendingPathComponent("tagged.txt")
        try Data("scratch tag fixture".utf8).write(to: source)
        let entry = try vault.stage(fileURL: source, stagedAtISO8601: "2026-08-30T00:00:00Z")

        let expectedTag = "pt_\(ProcessInfo.processInfo.processIdentifier)_"
        var seen: [String] = []
        _ = try vault.withPlaintextFileURL(handle: entry.handle) { url -> Int in
            seen.append(url.lastPathComponent)
            return 0
        }
        XCTAssertEqual(seen.count, 1)
        XCTAssertTrue(
            seen[0].hasPrefix(expectedTag),
            "scratch name \(seen[0]) must start with \(expectedTag)"
        )
    }
}
