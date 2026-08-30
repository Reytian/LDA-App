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
//  hermetic. No Keychain is touched: the vault stores plaintext today (phase 5
//  adds encryption at rest behind the same API).
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

    /// A deliberately party-identifying fixture name, mirroring how PRC legal
    /// practice names files. The vault must keep this OUT of its object tree.
    private let sensitiveName = "ZhangSan-v-LiSi-divorce-agreement"

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocumentVaultTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        vaultRoot = workDir.appendingPathComponent("vault", isDirectory: true)
        vault = DocumentVault(rootDirectory: vaultRoot)
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
        let reopened = DocumentVault(rootDirectory: vaultRoot)
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
        let listed = try DocumentVault(rootDirectory: vaultRoot).list()
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
