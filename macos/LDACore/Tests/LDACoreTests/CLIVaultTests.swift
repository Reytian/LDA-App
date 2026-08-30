//
//  CLIVaultTests.swift
//  LDACoreTests
//
//  The human intake path for the staging vault: lda vault stage and lda vault
//  list. The CLI is a human-facing edge, so unlike the MCP tools it may print
//  the original filename (a human needs the handle-to-document correlation);
//  the MCP boundary tests separately prove that correlation never crosses the
//  tool surface.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
import ZIPFoundation
@testable import LDACLI
@testable import LDACore

final class CLIVaultTests: XCTestCase {

    private var workDir: URL!
    private var vaultRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        assertNoTestSeamsInstalled()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CLIVaultTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        vaultRoot = workDir.appendingPathComponent("vault", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let workDir, FileManager.default.fileExists(atPath: workDir.path) {
            try? FileManager.default.removeItem(at: workDir)
        }
        try super.tearDownWithError()
    }

    @discardableResult
    private func writeFixture(named name: String, contents: String = "Mail jane@example.com now.") throws -> URL {
        let url = workDir.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    // MARK: - vault stage

    func testVaultStageStagesADocumentAndReportsTheHandle() throws {
        let source = try writeFixture(named: "matter.txt")

        let entries = try LDACLI.runVaultStage(
            inputs: [source],
            vaultRoot: vaultRoot,
            timestamp: { "2026-08-30T00:00:00Z" },
            protection: VaultTestSupport.protection
        )

        XCTAssertEqual(entries.count, 1)
        let entry = try XCTUnwrap(entries.first)
        XCTAssertTrue(entry.handle.hasPrefix("doc_"))
        XCTAssertEqual(entry.kind, "original")
        XCTAssertEqual(entry.format, "txt")
        XCTAssertEqual(entry.stagedAt, "2026-08-30T00:00:00Z")
        XCTAssertEqual(entry.originalFilename, "matter.txt")

        // The MCP surface sees the same staged document through its handle.
        let vaultEntry = try VaultTestSupport.vault(root: vaultRoot).entry(handle: entry.handle)
        XCTAssertEqual(vaultEntry.kind, .original)
    }

    func testVaultStageOfAMissingFileFailsWithInputNotFound() throws {
        let missing = workDir.appendingPathComponent("nope.txt")
        XCTAssertThrowsError(
            try LDACLI.runVaultStage(
                inputs: [missing],
                vaultRoot: vaultRoot,
                protection: VaultTestSupport.protection
            )
        ) { error in
            guard case CLIError.inputNotFound = error else {
                return XCTFail("expected inputNotFound, got \(error)")
            }
        }
    }

    func testVaultStageExpandsAZipIntoIndividualStagedDocuments() throws {
        // Build a small zip of two text documents, the way ZipImporterTests do.
        let zipURL = workDir.appendingPathComponent("bundle.zip")
        let archive = try Archive(url: zipURL, accessMode: .create)
        for (name, content) in [
            ("complaint.txt", "Filed by a@example.com."),
            ("annex.txt", "Reply to b@example.com.")
        ] {
            let data = Data(content.utf8)
            try archive.addEntry(
                with: name,
                type: .file,
                uncompressedSize: Int64(data.count),
                provider: { position, size in
                    data.subdata(in: Int(position)..<Int(position) + size)
                }
            )
        }

        let entries = try LDACLI.runVaultStage(
            inputs: [zipURL],
            vaultRoot: vaultRoot,
            timestamp: { "2026-08-30T00:00:00Z" },
            protection: VaultTestSupport.protection
        )

        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(
            Set(entries.compactMap(\.originalFilename)),
            ["complaint.txt", "annex.txt"]
        )
        // Every staged copy is readable through the vault after the zip
        // expansion scratch space is gone.
        let vault = VaultTestSupport.vault(root: vaultRoot)
        for entry in entries {
            XCTAssertNoThrow(try vault.readDocumentBytes(handle: entry.handle))
        }
    }

    // MARK: - vault list

    func testVaultListShowsOriginalsAndDerivedArtifacts() throws {
        let source = try writeFixture(named: "matter.txt")
        let staged = try LDACLI.runVaultStage(
            inputs: [source],
            vaultRoot: vaultRoot,
            timestamp: { "2026-08-30T00:00:00Z" },
            protection: VaultTestSupport.protection
        ).first!

        // Derive one artifact directly through the vault.
        let vault = VaultTestSupport.vault(root: vaultRoot)
        let slot = try vault.prepareDerived(kind: .redacted)
        let produced = slot.directory.appendingPathComponent("original_redacted.txt")
        try Data("Mail {EMAIL_1} now.".utf8).write(to: produced)
        try vault.commit(
            slot: slot,
            primaryFile: produced,
            stagedAtISO8601: "2026-08-30T00:01:00Z",
            sourceHandle: staged.handle,
            mappingFile: nil,
            mappingAccountBase: nil
        )

        let listed = try LDACLI.runVaultList(
            vaultRoot: vaultRoot,
            protection: VaultTestSupport.protection
        )

        XCTAssertEqual(listed.count, 2)
        XCTAssertEqual(listed[0].handle, staged.handle)
        XCTAssertEqual(listed[0].originalFilename, "matter.txt")
        XCTAssertEqual(listed[1].kind, "redacted")
        XCTAssertEqual(listed[1].sourceHandle, staged.handle)
        XCTAssertNil(listed[1].originalFilename)
    }

    func testVaultListOnAFreshVaultIsEmpty() throws {
        XCTAssertEqual(
            try LDACLI.runVaultList(
                vaultRoot: vaultRoot,
                protection: VaultTestSupport.protection
            ),
            []
        )
    }

    // MARK: - Encrypted vault

    /// The CLI runs in-process over the same encrypted DocumentVault: staging
    /// stores ciphertext, and list decrypts the registry to keep printing the
    /// human-facing correlation (handle to original filename).
    func testVaultStageAndListWorkOverTheEncryptedStore() throws {
        let source = try writeFixture(named: "matter.txt", contents: "Mail jane@example.com now.")
        let staged = try LDACLI.runVaultStage(
            inputs: [source],
            vaultRoot: vaultRoot,
            timestamp: { "2026-08-30T00:00:00Z" },
            protection: VaultTestSupport.protection
        ).first!

        // Ciphertext at rest: the stored object carries none of the body.
        let entry = try VaultTestSupport.vault(root: vaultRoot).entry(handle: staged.handle)
        let raw = try XCTUnwrap(FileManager.default.contents(
            atPath: vaultRoot.appendingPathComponent(entry.relativePath).path
        ))
        XCTAssertFalse(String(decoding: raw, as: UTF8.self).contains("jane@example.com"))

        // The human-facing listing still correlates handle and filename.
        let listed = try LDACLI.runVaultList(
            vaultRoot: vaultRoot,
            protection: VaultTestSupport.protection
        )
        XCTAssertEqual(listed.first?.handle, staged.handle)
        XCTAssertEqual(listed.first?.originalFilename, "matter.txt")
    }
}
