//
//  WorkspaceArchiveTests.swift
//  LDACoreTests
//
//  The portable single-file workspace (.ldawork) at the format layer: package
//  then encrypt, passphrase only, an explicit format version, and no residue
//  on any failure path.
//
//  The headline test is testCiphertextRevealsNothingAboutItsContents: it is the
//  test that would have caught the leak class the format exists to block. An
//  outer zip stores entry names in plaintext, and entry names here are document
//  file names, which in PRC legal practice carry the parties' names.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
import ZIPFoundation
@testable import LDACore

final class WorkspaceArchiveTests: XCTestCase {

    private var workDir: URL!

    private static let passphrase = "correct horse battery staple"
    private static let createdAt = "2026-08-31T09:00:00Z"

    /// Distinctive strings that must never appear in a workspace file's bytes.
    private static let partyName = "Zhang Weiming"
    private static let documentName = "ZhangWeiming-arbitration-notice.txt"
    private static let matterLabel = "Nantong Textile v. Zhang"

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceArchiveTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        ZipImporter.cleanUpAllExpansions()
        ImportLimits.archiveBudgetSeam.clear()
        try? FileManager.default.removeItem(at: workDir)
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    private func write(_ name: String, _ content: String) throws -> URL {
        let url = workDir.appendingPathComponent(name)
        try Data(content.utf8).write(to: url)
        return url
    }

    private func makeSpan(_ text: String, start: Int) -> Span {
        Span(
            start: start,
            end: start + (text as NSString).length,
            type: .person,
            text: text,
            source: .llm,
            confidence: 0.9,
            priority: 50
        )
    }

    /// A payload with two documents, decisions on both, a mapping, an
    /// override, and a matter scope.
    private func makeFullPayload() throws -> (payload: WorkspacePayload, sources: [UUID: URL]) {
        let firstID = UUID()
        let secondID = UUID()
        let firstURL = try write(Self.documentName, "\(Self.partyName) filed the notice.")
        let secondURL = try write("exhibit-b.txt", "Counterparty: Acme Trading Ltd.")

        let documents = [
            WorkspaceDocumentRecord(
                id: firstID,
                name: Self.documentName,
                contentKind: "txt",
                archivePath: WorkspaceArchive.documentArchivePath(id: firstID, name: Self.documentName)
            ),
            WorkspaceDocumentRecord(
                id: secondID,
                name: "exhibit-b.txt",
                contentKind: "txt",
                archivePath: WorkspaceArchive.documentArchivePath(id: secondID, name: "exhibit-b.txt")
            )
        ]
        let manifest = WorkspaceManifest(
            formatVersion: WorkspaceArchive.currentFormatVersion,
            createdAtISO8601: Self.createdAt,
            appVersion: "1.0",
            matterLabel: Self.matterLabel,
            matterScopeID: UUID(),
            substitutionStyle: .pseudonym,
            documents: documents
        )
        let snapshot = WorkspaceReviewSnapshot(
            documentID: firstID,
            textDigest: WorkspaceReviewSnapshot.digest(of: "\(Self.partyName) filed the notice."),
            entities: [
                WorkspaceEntityRecord(
                    id: UUID(),
                    span: makeSpan(Self.partyName, start: 0),
                    accepted: true,
                    token: "Mr. Kingsley"
                )
            ]
        )
        let mapping = Mapping(
            entries: [
                "Mr. Kingsley": MappingEntry(
                    token: "Mr. Kingsley",
                    value: Self.partyName,
                    type: .person,
                    surfaceText: Self.partyName,
                    aliases: []
                )
            ],
            createdAtISO8601: Self.createdAt,
            sourceFile: Self.documentName,
            style: .pseudonym
        )
        let payload = WorkspacePayload(
            manifest: manifest,
            documentSources: [firstID: firstURL, secondID: secondURL],
            mapping: mapping,
            sessionState: WorkspaceSessionState(pseudonymOverrides: [Self.partyName: "Mr. Kingsley"]),
            snapshots: [snapshot],
            matterLearnedTermsJSON: Data(#"[{"value":"Acme Trading Ltd."}]"#.utf8),
            matterCustomPatternsJSON: Data(#"[{"text":"Nantong Textile"}]"#.utf8)
        )
        return (payload, [firstID: firstURL, secondID: secondURL])
    }

    // MARK: - Ciphertext hygiene

    func testCiphertextRevealsNothingAboutItsContents() throws {
        let (payload, _) = try makeFullPayload()
        let fileURL = workDir.appendingPathComponent("matter.ldawork")

        try WorkspaceArchive.write(payload, to: fileURL, passphrase: Self.passphrase)

        let bytes = try Data(contentsOf: fileURL)
        // Document names, party names, the matter label: none may survive as
        // readable bytes. An outer-zip design would publish the file names in
        // the central directory, which is exactly the leak this asserts against.
        for secret in [Self.partyName, Self.documentName, Self.matterLabel,
                       "exhibit-b.txt", "Acme Trading Ltd.", "Nantong Textile",
                       "Mr. Kingsley", "manifest.json"] {
            XCTAssertFalse(
                bytes.range(of: Data(secret.utf8)) != nil,
                "the ciphertext leaks \(secret)"
            )
        }
        // No inner zip signature either: the zip is INSIDE the ciphertext, so
        // no tool can even tell it is an archive.
        XCTAssertNil(bytes.range(of: Data([0x50, 0x4B, 0x03, 0x04])),
                     "a local file header is visible in the ciphertext")
        XCTAssertNil(bytes.range(of: Data([0x50, 0x4B, 0x01, 0x02])),
                     "a central directory header is visible in the ciphertext")
    }

    func testTheFileIsNotConfusableWithAMappingSidecar() throws {
        let (payload, _) = try makeFullPayload()
        let fileURL = workDir.appendingPathComponent("matter.ldawork")
        try WorkspaceArchive.write(payload, to: fileURL, passphrase: Self.passphrase)

        let bytes = try Data(contentsOf: fileURL)
        XCTAssertEqual(Array(bytes.prefix(6)), Array("LDAWRK".utf8))

        // A mapping sidecar fed to the workspace reader fails on the magic,
        // not on the passphrase.
        let sidecarURL = workDir.appendingPathComponent("sidecar.ldamap")
        try MappingStore.save(
            Mapping(entries: [:], createdAtISO8601: Self.createdAt, sourceFile: "x.txt"),
            to: sidecarURL,
            protection: .passphrase(Self.passphrase)
        )
        XCTAssertThrowsError(
            try WorkspaceArchive.read(from: sidecarURL, passphrase: Self.passphrase)
        ) { error in
            guard case WorkspaceArchiveError.damagedFile = error else {
                return XCTFail("expected damagedFile, got \(error)")
            }
        }
    }

    // MARK: - Round trip

    func testRoundTripPreservesEveryPartOfTheWorkspace() throws {
        let (payload, sources) = try makeFullPayload()
        let fileURL = workDir.appendingPathComponent("matter.ldawork")

        try WorkspaceArchive.write(payload, to: fileURL, passphrase: Self.passphrase)
        let opened = try WorkspaceArchive.read(from: fileURL, passphrase: Self.passphrase)
        defer { opened.expansion.cleanUp() }

        XCTAssertEqual(opened.manifest.formatVersion, WorkspaceArchive.currentFormatVersion)
        XCTAssertEqual(opened.manifest.matterLabel, Self.matterLabel)
        XCTAssertEqual(opened.manifest.matterScopeID, payload.manifest.matterScopeID)
        XCTAssertEqual(opened.manifest.substitutionStyle, .pseudonym)
        XCTAssertEqual(opened.manifest.createdAtISO8601, Self.createdAt)
        XCTAssertEqual(opened.manifest.documents.map(\.name),
                       [Self.documentName, "exhibit-b.txt"])

        // Original bytes come back byte identical.
        for (id, source) in sources {
            let restored = try XCTUnwrap(opened.documentURLs[id])
            XCTAssertEqual(try Data(contentsOf: restored), try Data(contentsOf: source))
            XCTAssertEqual(restored.lastPathComponent, source.lastPathComponent)
        }
        XCTAssertEqual(opened.orderedDocumentURLs.count, 2)

        XCTAssertEqual(opened.mapping, payload.mapping)
        XCTAssertEqual(opened.sessionState.pseudonymOverrides, [Self.partyName: "Mr. Kingsley"])
        XCTAssertEqual(opened.snapshots.count, 1)
        let snapshot = try XCTUnwrap(opened.snapshots[payload.snapshots[0].documentID])
        XCTAssertEqual(snapshot, payload.snapshots[0])
        XCTAssertEqual(opened.matterLearnedTermsJSON, payload.matterLearnedTermsJSON)
        XCTAssertEqual(opened.matterCustomPatternsJSON, payload.matterCustomPatternsJSON)
    }

    func testOpeningNeedsOnlyTheFileAndThePassphrase() throws {
        // Nothing in the open path consults the Keychain: the container is
        // constructed with passphrase protection only. Proven structurally by
        // reading a file written in this process from a passphrase alone, with
        // the in-process key cache purged so no cached Keychain key can help.
        let (payload, _) = try makeFullPayload()
        let fileURL = workDir.appendingPathComponent("handoff.ldawork")
        try WorkspaceArchive.write(payload, to: fileURL, passphrase: Self.passphrase)

        EncryptedContainer.purgeKeyCache()

        let opened = try WorkspaceArchive.read(from: fileURL, passphrase: Self.passphrase)
        defer { opened.expansion.cleanUp() }
        XCTAssertEqual(opened.manifest.documents.count, 2)
    }

    func testAWorkspaceWithoutMatterOrMappingRoundTrips() throws {
        let id = UUID()
        let url = try write("plain.txt", "No matter here.")
        let manifest = WorkspaceManifest(
            formatVersion: WorkspaceArchive.currentFormatVersion,
            createdAtISO8601: Self.createdAt,
            appVersion: nil,
            matterLabel: nil,
            matterScopeID: nil,
            substitutionStyle: .token,
            documents: [
                WorkspaceDocumentRecord(
                    id: id,
                    name: "plain.txt",
                    contentKind: "txt",
                    archivePath: WorkspaceArchive.documentArchivePath(id: id, name: "plain.txt")
                )
            ]
        )
        let fileURL = workDir.appendingPathComponent("plain.ldawork")
        try WorkspaceArchive.write(
            WorkspacePayload(manifest: manifest, documentSources: [id: url]),
            to: fileURL,
            passphrase: Self.passphrase
        )

        let opened = try WorkspaceArchive.read(from: fileURL, passphrase: Self.passphrase)
        defer { opened.expansion.cleanUp() }
        XCTAssertNil(opened.mapping)
        XCTAssertNil(opened.manifest.matterLabel)
        XCTAssertNil(opened.matterLearnedTermsJSON)
        XCTAssertTrue(opened.sessionState.pseudonymOverrides.isEmpty)
        XCTAssertTrue(opened.snapshots.isEmpty)
    }

    // MARK: - Failure paths

    func testWrongPassphraseIsItsOwnErrorAndLeavesNoResidue() throws {
        let (payload, _) = try makeFullPayload()
        let fileURL = workDir.appendingPathComponent("matter.ldawork")
        try WorkspaceArchive.write(payload, to: fileURL, passphrase: Self.passphrase)

        let before = ZipImporter.liveExpansionCount
        XCTAssertThrowsError(try WorkspaceArchive.read(from: fileURL, passphrase: "wrong")) { error in
            XCTAssertEqual(error as? WorkspaceArchiveError, .wrongPassphrase)
        }
        XCTAssertEqual(ZipImporter.liveExpansionCount, before, "a failed open left a temp directory")
    }

    func testATruncatedFileIsDamagedNotAWrongPassphrase() throws {
        let (payload, _) = try makeFullPayload()
        let fileURL = workDir.appendingPathComponent("matter.ldawork")
        try WorkspaceArchive.write(payload, to: fileURL, passphrase: Self.passphrase)

        // Truncate into the container header, which is checked structurally.
        let bytes = try Data(contentsOf: fileURL)
        try bytes.prefix(12).write(to: fileURL)

        let before = ZipImporter.liveExpansionCount
        XCTAssertThrowsError(
            try WorkspaceArchive.read(from: fileURL, passphrase: Self.passphrase)
        ) { error in
            guard case WorkspaceArchiveError.damagedFile = error else {
                return XCTFail("expected damagedFile, got \(error)")
            }
        }
        XCTAssertEqual(ZipImporter.liveExpansionCount, before)
    }

    func testAFutureFormatVersionSaysUpdateLDANotCorrupt() throws {
        let (payload, sources) = try makeFullPayload()
        let fileURL = workDir.appendingPathComponent("future.ldawork")
        try writeArchive(
            payload,
            sources: sources,
            to: fileURL,
            forcingFormatVersion: WorkspaceArchive.currentFormatVersion + 1
        )

        let before = ZipImporter.liveExpansionCount
        XCTAssertThrowsError(
            try WorkspaceArchive.read(from: fileURL, passphrase: Self.passphrase)
        ) { error in
            XCTAssertEqual(
                error as? WorkspaceArchiveError,
                .createdByNewerVersion(found: 2, supported: WorkspaceArchive.currentFormatVersion)
            )
            XCTAssertEqual(
                (error as? WorkspaceArchiveError)?.errorDescription?
                    .contains("newer version of LDA"),
                true
            )
        }
        XCTAssertEqual(ZipImporter.liveExpansionCount, before)
    }

    func testAFutureFormatVersionWinsOverAnUnreadableManifestBody() throws {
        // A future schema may well not decode into today's manifest type. The
        // version probe must run first, or the user is told their file is
        // damaged when it is merely newer.
        let fileURL = workDir.appendingPathComponent("alien.ldawork")
        try writeRawArchive(
            members: ["manifest.json": Data(#"{"formatVersion":9,"somethingElse":true}"#.utf8)],
            to: fileURL
        )

        XCTAssertThrowsError(
            try WorkspaceArchive.read(from: fileURL, passphrase: Self.passphrase)
        ) { error in
            XCTAssertEqual(
                error as? WorkspaceArchiveError,
                .createdByNewerVersion(found: 9, supported: WorkspaceArchive.currentFormatVersion)
            )
        }
    }

    func testAnArchiveWithoutAManifestIsDamaged() throws {
        let fileURL = workDir.appendingPathComponent("empty.ldawork")
        try writeRawArchive(members: ["session.json": Data("{}".utf8)], to: fileURL)

        XCTAssertThrowsError(
            try WorkspaceArchive.read(from: fileURL, passphrase: Self.passphrase)
        ) { error in
            guard case WorkspaceArchiveError.damagedFile = error else {
                return XCTFail("expected damagedFile, got \(error)")
            }
        }
    }

    func testAMissingSourceDocumentAbortsTheExportNamingIt() throws {
        let (payload, sources) = try makeFullPayload()
        let missing = try XCTUnwrap(sources.values.first { $0.lastPathComponent == Self.documentName })
        try FileManager.default.removeItem(at: missing)

        let fileURL = workDir.appendingPathComponent("aborted.ldawork")
        XCTAssertThrowsError(
            try WorkspaceArchive.write(payload, to: fileURL, passphrase: Self.passphrase)
        ) { error in
            guard case WorkspaceArchiveError.documentUnreadable(let name, _) = error else {
                return XCTFail("expected documentUnreadable, got \(error)")
            }
            XCTAssertEqual(name, Self.documentName)
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fileURL.path),
            "a failed export wrote a partial workspace file"
        )
    }

    // MARK: - Cleanup contract and ceilings

    func testAnOpenedWorkspaceIsRegisteredUntilCleanedUp() throws {
        let (payload, _) = try makeFullPayload()
        let fileURL = workDir.appendingPathComponent("matter.ldawork")
        try WorkspaceArchive.write(payload, to: fileURL, passphrase: Self.passphrase)

        let before = ZipImporter.liveExpansionCount
        let opened = try WorkspaceArchive.read(from: fileURL, passphrase: Self.passphrase)
        XCTAssertEqual(ZipImporter.liveExpansionCount, before + 1)

        let directory = opened.expansion.directory
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        opened.expansion.cleanUp()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertEqual(ZipImporter.liveExpansionCount, before)
    }

    func testCleanUpAllExpansionsRemovesAnOpenedWorkspace() throws {
        let (payload, _) = try makeFullPayload()
        let fileURL = workDir.appendingPathComponent("matter.ldawork")
        try WorkspaceArchive.write(payload, to: fileURL, passphrase: Self.passphrase)

        let opened = try WorkspaceArchive.read(from: fileURL, passphrase: Self.passphrase)
        let directory = opened.expansion.directory

        // The app-quit and tray-emptied boundary. Same sweep that clears a
        // dropped .zip, so a workspace cannot outlive the session either.
        ZipImporter.cleanUpAllExpansions()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testAWorkspaceOverTheInflatedBudgetIsRejectedAndLeavesNothing() throws {
        let id = UUID()
        let url = try write("bulky.txt", String(repeating: "A", count: 8_192))
        let manifest = WorkspaceManifest(
            formatVersion: WorkspaceArchive.currentFormatVersion,
            createdAtISO8601: Self.createdAt,
            appVersion: nil,
            matterLabel: nil,
            matterScopeID: nil,
            substitutionStyle: .token,
            documents: [
                WorkspaceDocumentRecord(
                    id: id,
                    name: "bulky.txt",
                    contentKind: "txt",
                    archivePath: WorkspaceArchive.documentArchivePath(id: id, name: "bulky.txt")
                )
            ]
        )
        let fileURL = workDir.appendingPathComponent("bulky.ldawork")
        try WorkspaceArchive.write(
            WorkspacePayload(manifest: manifest, documentSources: [id: url]),
            to: fileURL,
            passphrase: Self.passphrase
        )

        // The budget meters ACTUAL inflated bytes, so a highly compressible
        // payload is stopped by what it expands to, not by its stored size.
        ImportLimits.archiveBudgetSeam.value = 1_024
        let before = ZipImporter.liveExpansionCount
        XCTAssertThrowsError(
            try WorkspaceArchive.read(from: fileURL, passphrase: Self.passphrase)
        ) { error in
            guard case WorkspaceArchiveError.tooLarge = error else {
                return XCTFail("expected tooLarge, got \(error)")
            }
        }
        XCTAssertEqual(ZipImporter.liveExpansionCount, before, "a rejected open left a temp directory")
    }

    func testADocumentPathEscapingTheArchiveIsRefused() throws {
        let id = UUID()
        let manifest = WorkspaceManifest(
            formatVersion: WorkspaceArchive.currentFormatVersion,
            createdAtISO8601: Self.createdAt,
            appVersion: nil,
            matterLabel: nil,
            matterScopeID: nil,
            substitutionStyle: .token,
            documents: [
                WorkspaceDocumentRecord(
                    id: id,
                    name: "evil.txt",
                    contentKind: "txt",
                    archivePath: "documents/../../../../tmp/evil.txt"
                )
            ]
        )
        let fileURL = workDir.appendingPathComponent("evil.ldawork")
        try writeRawArchive(
            members: [
                "manifest.json": try JSONEncoder().encode(manifest),
                "documents/../../../../tmp/evil.txt": Data("pwned".utf8)
            ],
            to: fileURL
        )

        let before = ZipImporter.liveExpansionCount
        XCTAssertThrowsError(
            try WorkspaceArchive.read(from: fileURL, passphrase: Self.passphrase)
        ) { error in
            guard case WorkspaceArchiveError.damagedFile = error else {
                return XCTFail("expected damagedFile, got \(error)")
            }
        }
        XCTAssertEqual(ZipImporter.liveExpansionCount, before)
    }

    func testASafeEntryNameCannotTraverseOrHide() {
        XCTAssertEqual(WorkspaceArchive.safeEntryName("../../etc/passwd"), "passwd")
        XCTAssertEqual(WorkspaceArchive.safeEntryName(".hidden"), "_.hidden")
        XCTAssertEqual(WorkspaceArchive.safeEntryName(".."), "document")
        XCTAssertEqual(WorkspaceArchive.safeEntryName("   "), "document")
        XCTAssertEqual(WorkspaceArchive.safeEntryName("contract.docx"), "contract.docx")
    }

    // MARK: - Raw archive helpers

    /// Write a workspace whose manifest carries an arbitrary format version.
    private func writeArchive(
        _ payload: WorkspacePayload,
        sources: [UUID: URL],
        to url: URL,
        forcingFormatVersion version: Int
    ) throws {
        var members: [String: Data] = [:]
        var manifest = payload.manifest
        manifest.formatVersion = version
        members[WorkspaceArchive.manifestEntryPath] = try JSONEncoder().encode(manifest)
        for record in manifest.documents {
            members[record.archivePath] = try Data(contentsOf: try XCTUnwrap(sources[record.id]))
        }
        try writeRawArchive(members: members, to: url)
    }

    /// Build an inner zip from exact member bytes and seal it the way the
    /// format does, so a test can produce archives the writer would never emit.
    private func writeRawArchive(members: [String: Data], to url: URL) throws {
        try WorkspaceArchiveFixtures.write(members: members, to: url, passphrase: Self.passphrase)
    }
}
