//
//  SidecarDefaultAndWorkspaceTests.swift
//  LDACoreTests
//
//  Three defaults changed together, and this suite exists to hold them
//  together: no .ldamap beside the output unless asked for, a passphrase
//  whenever one IS asked for, and the mapping kept in a workspace named after
//  the document so the first two cost nothing.
//
//  THE ACCEPTANCE QUESTION, asked of every export path: can a document
//  redacted with DEFAULT settings still be restored afterwards, with the user
//  having saved nothing extra? Half of this change shipped alone would produce
//  a redacted document whose key exists nowhere, which is the worst outcome
//  this product has, so the question is asked in the same session, after the
//  session is gone, and after a second export has rewritten the workspace.
//
//  Deterministic-only (no GGUF model). Hermetic in the file system: every
//  store lives under a per-test temporary directory whose name carries a
//  UUID, which also makes the default workspaces' Keychain accounts unique per
//  run, because those accounts are derived from a name containing a digest of
//  the source PATH. Every key minted is deleted in tearDown.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore
@testable import LDAUI

@MainActor
final class SidecarDefaultAndWorkspaceTests: XCTestCase {

    private static let createdAt = "2026-09-04T00:00:00Z"

    private var workDir: URL!
    private var workspaceDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "SidecarDefaultAndWorkspaceTests-\(UUID().uuidString)",
                isDirectory: true
            )
        workspaceDir = workDir.appendingPathComponent("workspaces", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Every default workspace this run created was sealed with a real
        // Keychain key, on purpose: the claim under test is that the app opens
        // it with nothing the user typed. Delete the keys rather than leave
        // them behind.
        for url in (try? FileManager.default.contentsOfDirectory(
            at: workspaceDir,
            includingPropertiesForKeys: nil
        )) ?? [] where url.pathExtension == WorkspaceArchive.fileExtension {
            try? WorkspaceArchive.deleteKeychainKey(
                account: DefaultWorkspace.keychainAccount(for: url)
            )
        }
        try? FileManager.default.removeItem(at: workDir)
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    /// A session whose stores all live under this test's own directory. The
    /// default workspace protection is deliberately NOT injected: it is the
    /// production Keychain rule, because "needs nothing the user typed" is
    /// exactly what these tests are about.
    private func makeSession() -> SessionModel {
        let session = SessionModel(
            makeModel: {
                let model = ReviewModel(modelPath: nil)
                model.useLLM = false
                return model
            },
            clientStore: {
                try ClientMappingStore(
                    rootDirectory: self.workDir.appendingPathComponent("clients")
                )
            }
        )
        session.clientProtection = { _ in .passphrase("pw") }
        session.recordStore = {
            try SessionRecordStore(rootDirectory: self.workDir.appendingPathComponent("records"))
        }
        session.recordProtection = { .passphrase("pw") }
        session.matterStore = {
            try MatterMetadataStore(rootDirectory: self.workDir.appendingPathComponent("matters"))
        }
        session.matterProtection = { .passphrase("pw") }
        let parkedURL = workDir
            .appendingPathComponent("parked", isDirectory: true)
            .appendingPathComponent("parked.ldamap")
        try? FileManager.default.createDirectory(
            at: parkedURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        session.parkedMappingURL = { parkedURL }
        session.parkedProtection = { .passphrase("parked-pw") }
        session.exportSidecarProtection = { _ in .passphrase("ai-sidecar-pw") }
        session.defaultWorkspaceDirectory = { self.workspaceDir }
        return session
    }

    private func write(_ name: String, _ content: String, in directory: URL? = nil) throws -> URL {
        let root = directory ?? workDir!
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent(name)
        try Data(content.utf8).write(to: url)
        return url
    }

    /// A session holding one scanned document, ready to export.
    private func scannedSession(
        document: URL
    ) async throws -> SessionModel {
        let session = makeSession()
        await session.addDocuments([document])
        await session.anonymizeAll()
        return session
    }

    private func exportDirectory(_ name: String = "out") -> URL {
        workDir.appendingPathComponent(name, isDirectory: true)
    }

    /// Paths compared as resolved strings throughout: the temporary directory
    /// reaches these tests as /var/... and comes back from
    /// contentsOfDirectory as /private/var/..., which are the same directory
    /// and unequal URLs.
    private func resolved(_ url: URL) -> String {
        url.resolvingSymlinksInPath().path
    }

    private func ldamapFiles(in directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? [])
            .filter { $0.pathExtension == MappingStore.fileExtension }
            .map { resolved($0) }
            .sorted()
    }

    private func workspaceFiles() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(
            at: workspaceDir,
            includingPropertiesForKeys: nil
        )) ?? [])
            .filter { $0.pathExtension == WorkspaceArchive.fileExtension }
            .map { resolved($0) }
            .sorted()
    }

    /// The document fixture. One email is enough: the point of every test here
    /// is where the key lives, not what detection found.
    private static let body = "Engagement Letter. Mail john@acme.example about the matter."

    // MARK: - (b) No sidecar by default

    func testADefaultExportWritesNoMappingFileBesideTheDocument() async throws {
        let document = try write("contract.txt", Self.body)
        let session = try await scannedSession(document: document)
        let outputDir = exportDirectory()

        let result = try await session.exportRedacted(
            to: outputDir,
            passphrase: nil,
            createdAtISO8601: Self.createdAt
        )

        XCTAssertNil(result.mappingURL, "a default export must write no sidecar")
        XCTAssertEqual(
            ldamapFiles(in: outputDir), [],
            "no .ldamap may appear in the folder the redacted document is sent from"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.redactedURL.path))
    }

    // MARK: - (c) The mapping is kept, and the export says where

    func testADefaultExportKeepsTheMappingInAWorkspaceNamedAfterTheDocument() async throws {
        let document = try write("contract.txt", Self.body)
        let session = try await scannedSession(document: document)

        let result = try await session.exportRedacted(
            to: exportDirectory(),
            passphrase: nil,
            createdAtISO8601: Self.createdAt
        )

        let workspaceURL = try XCTUnwrap(
            result.workspaceURL,
            "an export must report where it kept the key"
        )
        XCTAssertEqual(workspaceFiles(), [resolved(workspaceURL)])
        XCTAssertTrue(
            workspaceURL.lastPathComponent.hasPrefix("contract"),
            "the workspace must be named after the document, got "
                + workspaceURL.lastPathComponent
        )
        XCTAssertEqual(workspaceURL.pathExtension, WorkspaceArchive.fileExtension)
    }

    /// Repeated exports of the same document update one file. A workspace per
    /// export would litter, and worse, would leave the user guessing which of
    /// several files is the key to the copy they sent.
    func testTheDefaultWorkspaceIsCreatedOnceForRepeatedExportsOfOneDocument() async throws {
        let document = try write("contract.txt", Self.body)
        let session = try await scannedSession(document: document)

        let first = try await session.exportRedacted(
            to: exportDirectory(),
            passphrase: nil,
            createdAtISO8601: Self.createdAt
        )
        let second = try await session.exportRedacted(
            to: exportDirectory(),
            passphrase: nil,
            createdAtISO8601: Self.createdAt
        )

        XCTAssertNotEqual(
            first.redactedURL, second.redactedURL,
            "the second export must not overwrite the first document"
        )
        XCTAssertEqual(first.workspaceURL, second.workspaceURL)
        XCTAssertEqual(workspaceFiles().count, 1, "exactly one workspace for one document")
    }

    /// The workspace is sealed with a Keychain key, not a passphrase. Stated as
    /// a refusal, because the whole reason it is not passphrase protected is
    /// that nobody was asked for one.
    func testTheDefaultWorkspaceIsNotPassphraseProtected() async throws {
        let document = try write("contract.txt", Self.body)
        let session = try await scannedSession(document: document)
        let result = try await session.exportRedacted(
            to: exportDirectory(),
            passphrase: nil,
            createdAtISO8601: Self.createdAt
        )
        let workspaceURL = try XCTUnwrap(result.workspaceURL)

        XCTAssertThrowsError(
            try WorkspaceArchive.readMapping(from: workspaceURL, protection: .passphrase("")),
            "a Keychain sealed workspace must not open as a passphrase one"
        )
        XCTAssertNotNil(
            try WorkspaceArchive.readMapping(
                from: workspaceURL,
                protection: .keychain(
                    account: DefaultWorkspace.keychainAccount(for: workspaceURL)
                )
            )
        )
    }

    // MARK: - The acceptance question

    func testADefaultExportIsRestorableInTheSameSession() async throws {
        let document = try write("contract.txt", Self.body)
        let session = try await scannedSession(document: document)
        let result = try await session.exportRedacted(
            to: exportDirectory(),
            passphrase: nil,
            createdAtISO8601: Self.createdAt
        )

        let source = try session.restoreMappingSource(for: result.redactedURL)
        guard case .session(let mapping) = source else {
            return XCTFail("expected the session's own mapping, got \(source)")
        }
        try assertRestores(result.redactedURL, with: mapping, in: session, to: Self.body)
    }

    /// The test this whole change stands or falls on: the app is closed, the
    /// session mapping is gone, no sidecar was ever written, and the redacted
    /// document must still come back.
    func testADefaultExportIsRestorableAfterTheSessionIsGone() async throws {
        let document = try write("contract.txt", Self.body)
        let exporting = try await scannedSession(document: document)
        let result = try await exporting.exportRedacted(
            to: exportDirectory(),
            passphrase: nil,
            createdAtISO8601: Self.createdAt
        )

        // A brand new session: nothing in memory, nothing parked, no matter
        // selected. Only what is on disk can answer.
        let relaunched = makeSession()
        let source = try relaunched.restoreMappingSource(for: result.redactedURL)
        guard case .defaultWorkspace(let mapping) = source else {
            return XCTFail("expected the document's default workspace, got \(source)")
        }
        try assertRestores(result.redactedURL, with: mapping, in: relaunched, to: Self.body)
    }

    /// A second export after a relaunch REWRITES the document's workspace.
    /// That is only safe because the export seeds from what the workspace
    /// already held, so the replacement is a superset and the FIRST export's
    /// redacted file still restores.
    ///
    /// The document is EDITED between the two exports, which is what makes
    /// this a real check rather than a tautology: with different text the
    /// second export mints {EMAIL_1} for a different address, so an unseeded
    /// rewrite would leave the first redacted file restoring to the wrong
    /// person with no orphan token and no warning anywhere.
    func testASecondExportAfterARelaunchDoesNotStrandTheFirstFile() async throws {
        let document = try write("contract.txt", Self.body)
        let first = try await (try await scannedSession(document: document)).exportRedacted(
            to: exportDirectory(),
            passphrase: nil,
            createdAtISO8601: Self.createdAt
        )

        // The user edits the document and exports again from a fresh session,
        // which resolves to the SAME workspace and rewrites it.
        let editedBody = "Engagement Letter. Mail jane@beta.example about the matter."
        _ = try write("contract.txt", editedBody)
        let reexporting = try await scannedSession(document: document)
        let second = try await reexporting.exportRedacted(
            to: exportDirectory(),
            passphrase: nil,
            createdAtISO8601: Self.createdAt
        )
        XCTAssertEqual(second.workspaceURL, first.workspaceURL)
        XCTAssertNotEqual(first.redactedURL, second.redactedURL)

        // Both redacted files still restore, each to its own text.
        let relaunched = makeSession()
        let firstSource = try relaunched.restoreMappingSource(for: first.redactedURL)
        guard case .defaultWorkspace(let mapping) = firstSource else {
            return XCTFail("expected the document's default workspace, got \(firstSource)")
        }
        try assertRestores(first.redactedURL, with: mapping, in: relaunched, to: Self.body)
        try assertRestores(second.redactedURL, with: mapping, in: relaunched, to: editedBody)
    }

    /// Export for AI is the other export path, and it is held to the same
    /// question: nothing extra saved, still restorable.
    func testExportForAIIsRestorableWithNothingExtraSaved() async throws {
        let document = try write("contract.txt", Self.body)
        let session = try await scannedSession(document: document)
        let markdownURL = exportDirectory().appendingPathComponent("handoff.md")
        try FileManager.default.createDirectory(
            at: exportDirectory(),
            withIntermediateDirectories: true
        )
        let outcome = try XCTUnwrap(
            try session.exportForAI(to: markdownURL, createdAtISO8601: Self.createdAt)
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: outcome.mappingURL.path))
        let source = try session.restoreMappingSource(for: markdownURL)
        guard case .sidecar(let sidecarURL) = source else {
            return XCTFail("expected the handoff's own sidecar, got \(source)")
        }
        let mapping = try SessionModel.loadSidecarMapping(
            at: sidecarURL,
            primary: markdownURL,
            passphrase: "ai-sidecar-pw"
        )
        XCTAssertFalse(mapping.entries.isEmpty, "the handoff key must not be empty")
    }

    // MARK: - (a) A deliberate sidecar, and its passphrase

    func testADeliberateSidecarIsWrittenAndOpensOnlyWithItsPassphrase() async throws {
        let document = try write("contract.txt", Self.body)
        let session = try await scannedSession(document: document)
        let outputDir = exportDirectory()
        let phrase = "correct horse battery staple"

        let result = try await session.exportRedacted(
            to: outputDir,
            passphrase: phrase,
            createdAtISO8601: Self.createdAt
        )

        let sidecarURL = try XCTUnwrap(
            result.mappingURL,
            "a passphrase must produce the sidecar the user asked for"
        )
        XCTAssertEqual(ldamapFiles(in: outputDir), [resolved(sidecarURL)])
        XCTAssertThrowsError(
            try MappingStore.load(
                from: sidecarURL,
                protection: .keychain(
                    account: SessionModel.sidecarKeychainAccount(for: sidecarURL)
                )
            ),
            "a sidecar must never be Keychain sealed: it exists to travel"
        )
        let mapping = try MappingStore.load(from: sidecarURL, protection: .passphrase(phrase))
        XCTAssertFalse(mapping.entries.isEmpty)

        // Both homes hold the key: asking for a travelling copy does not stop
        // the local one being kept.
        XCTAssertNotNil(result.workspaceURL)
    }

    /// The one place the sidecar decision is made, checked directly: no
    /// passphrase means no sidecar, an unconfirmed or short one means no
    /// sidecar either, and only a valid pair produces one.
    func testTheSidecarRuleWritesNothingWithoutAConfirmedPassphrase() {
        XCTAssertNil(
            MappingSidecarPresentation.sidecarPassphrase(
                wantsSidecar: false, passphrase: "", confirmation: ""
            )
        )
        XCTAssertNil(
            MappingSidecarPresentation.sidecarPassphrase(
                wantsSidecar: false, passphrase: "typed anyway", confirmation: "typed anyway"
            ),
            "a passphrase typed then declined must not write a file"
        )
        XCTAssertNil(
            MappingSidecarPresentation.sidecarPassphrase(
                wantsSidecar: true, passphrase: "", confirmation: ""
            )
        )
        XCTAssertNil(
            MappingSidecarPresentation.sidecarPassphrase(
                wantsSidecar: true, passphrase: "short", confirmation: "short"
            )
        )
        XCTAssertNil(
            MappingSidecarPresentation.sidecarPassphrase(
                wantsSidecar: true, passphrase: "long enough", confirmation: "long enouhg"
            )
        )
        XCTAssertEqual(
            MappingSidecarPresentation.sidecarPassphrase(
                wantsSidecar: true, passphrase: "long enough", confirmation: "long enough"
            ),
            "long enough"
        )
    }

    func testTheSidecarIssueNamesTheMappingFileRatherThanAWorkspace() {
        let issue = try? XCTUnwrap(
            MappingSidecarPresentation.issue(
                wantsSidecar: true, passphrase: "", confirmation: ""
            )
        )
        XCTAssertEqual(issue, .empty)
        let message = MappingSidecarPresentation.message(for: .empty, language: .english)
        XCTAssertTrue(
            message.contains("mapping file"),
            "the empty case must name what the user is actually writing: \(message)"
        )
        XCTAssertFalse(message.contains("workspace"))
    }

    // MARK: - Failing closed rather than shipping an unrestorable file

    /// If the key cannot be kept anywhere, the export must not leave a
    /// redacted document behind. Such a file looks like a finished deliverable
    /// and nothing can reverse it, which is worse than no export at all.
    func testAnExportThatCannotKeepItsKeyLeavesNoRedactedFile() async throws {
        let document = try write("contract.txt", Self.body)
        let session = try await scannedSession(document: document)
        session.defaultWorkspaceDirectory = { throw DocumentIOError.unreadable("no room") }
        let outputDir = exportDirectory()

        do {
            _ = try await session.exportRedacted(
                to: outputDir,
                passphrase: nil,
                createdAtISO8601: Self.createdAt
            )
            XCTFail("an export with nowhere to keep its key must throw")
        } catch {
            // Expected. What matters is what is NOT on disk.
        }
        let leftovers = ((try? FileManager.default.contentsOfDirectory(
            at: outputDir,
            includingPropertiesForKeys: nil
        )) ?? []).map(\.lastPathComponent)
        XCTAssertEqual(
            leftovers, [],
            "a redacted document was left with no key anywhere: \(leftovers)"
        )
    }

    /// The same failure with a sidecar asked for is NOT fatal: the key is
    /// beside the document, so the export stands and only the local copy is
    /// missing.
    func testASidecarSurvivesAWorkspaceThatCannotBeWritten() async throws {
        let document = try write("contract.txt", Self.body)
        let session = try await scannedSession(document: document)
        session.defaultWorkspaceDirectory = { throw DocumentIOError.unreadable("no room") }

        let result = try await session.exportRedacted(
            to: exportDirectory(),
            passphrase: "correct horse battery staple",
            createdAtISO8601: Self.createdAt
        )

        XCTAssertNil(result.workspaceURL, "the card must not claim a home that failed")
        let sidecarURL = try XCTUnwrap(result.mappingURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.redactedURL.path))
        XCTAssertFalse(
            try MappingStore.load(
                from: sidecarURL,
                protection: .passphrase("correct horse battery staple")
            ).entries.isEmpty
        )
    }

    // MARK: - A mapping that can still travel

    /// Removing the default sidecar must not remove the ways a mapping leaves
    /// this Mac, or a document could never be restored by a colleague. Save
    /// Workspace is the other one, and it stays passphrase protected.
    func testSaveWorkspaceStillCarriesTheMappingUnderAPassphrase() async throws {
        let document = try write("contract.txt", Self.body)
        let session = try await scannedSession(document: document)
        let result = try await session.exportRedacted(
            to: exportDirectory(),
            passphrase: nil,
            createdAtISO8601: Self.createdAt
        )
        XCTAssertNotNil(result.workspaceURL)

        let travelling = workDir.appendingPathComponent("handover.ldawork")
        try session.saveWorkspace(
            to: travelling,
            passphrase: "a passphrase for a colleague",
            createdAtISO8601: Self.createdAt
        )

        let carried = try XCTUnwrap(
            try WorkspaceArchive.readMapping(
                from: travelling,
                protection: .passphrase("a passphrase for a colleague")
            )
        )
        XCTAssertFalse(carried.entries.isEmpty, "the handover file must carry the key")
        // And it needs nothing from this Mac's Keychain, which is the whole
        // difference between the travelling form and the default one.
        XCTAssertThrowsError(
            try WorkspaceArchive.readMapping(
                from: travelling,
                protection: .keychain(
                    account: DefaultWorkspace.keychainAccount(for: travelling)
                )
            )
        )
    }

    // MARK: - Never guessing between two same-stemmed documents

    /// Two matters each holding a "contract.txt" is ordinary practice. They
    /// must get their own workspace, and Restore must refuse to choose: opening
    /// the wrong one would put the wrong party's name into the document, which
    /// no warning on screen would catch.
    func testTwoDocumentsWithTheSameNameKeepSeparateWorkspacesAndRestoreDoesNotGuess() async throws {
        let firstDir = workDir.appendingPathComponent("matter-a", isDirectory: true)
        let secondDir = workDir.appendingPathComponent("matter-b", isDirectory: true)
        let firstDoc = try write("contract.txt", "Mail alpha@one.example now.", in: firstDir)
        let secondDoc = try write("contract.txt", "Mail beta@two.example now.", in: secondDir)

        let firstResult = try await (try await scannedSession(document: firstDoc)).exportRedacted(
            to: firstDir.appendingPathComponent("out", isDirectory: true),
            passphrase: nil,
            createdAtISO8601: Self.createdAt
        )
        let secondResult = try await (try await scannedSession(document: secondDoc)).exportRedacted(
            to: secondDir.appendingPathComponent("out", isDirectory: true),
            passphrase: nil,
            createdAtISO8601: Self.createdAt
        )

        XCTAssertNotEqual(
            firstResult.workspaceURL, secondResult.workspaceURL,
            "one document's export must never overwrite another's only key"
        )
        XCTAssertEqual(workspaceFiles().count, 2)

        let relaunched = makeSession()
        let source = try relaunched.restoreMappingSource(for: firstResult.redactedURL)
        XCTAssertEqual(
            source, .none,
            "with two candidates the app must ask rather than pick, got \(source)"
        )
    }

    // MARK: - The naming rules, directly

    func testTheRedactedNameResolvesBackToItsDocumentStem() {
        XCTAssertEqual(DefaultWorkspace.documentStem(forRedactedFileNamed: "contract_redacted.txt"), "contract")
        XCTAssertEqual(DefaultWorkspace.documentStem(forRedactedFileNamed: "contract_redacted.docx"), "contract")
        XCTAssertEqual(DefaultWorkspace.documentStem(forRedactedFileNamed: "contract_redacted_2.txt"), "contract")
        XCTAssertEqual(DefaultWorkspace.documentStem(forRedactedFileNamed: "contract_redacted_17.txt"), "contract")
        XCTAssertEqual(
            DefaultWorkspace.documentStem(forRedactedFileNamed: "my_redacted_notes_redacted.txt"),
            "my_redacted_notes"
        )
        // Names this app never wrote must resolve to nothing rather than to a
        // plausible looking guess.
        XCTAssertNil(DefaultWorkspace.documentStem(forRedactedFileNamed: "contract.txt"))
        XCTAssertNil(DefaultWorkspace.documentStem(forRedactedFileNamed: "_redacted.txt"))
        XCTAssertNil(DefaultWorkspace.documentStem(forRedactedFileNamed: "contract_redacted_final.txt"))
    }

    func testTheWorkspaceNameIsStablePerDocumentAndUniquePerPath() {
        let first = URL(fileURLWithPath: "/matters/a/contract.docx")
        let again = URL(fileURLWithPath: "/matters/a/./contract.docx")
        let other = URL(fileURLWithPath: "/matters/b/contract.docx")

        XCTAssertEqual(
            DefaultWorkspace.fileName(forSource: first),
            DefaultWorkspace.fileName(forSource: again),
            "the same document must resolve to one workspace, or exports litter"
        )
        XCTAssertNotEqual(
            DefaultWorkspace.fileName(forSource: first),
            DefaultWorkspace.fileName(forSource: other),
            "two documents named alike must not share a file"
        )
        XCTAssertTrue(DefaultWorkspace.fileName(forSource: first).hasPrefix("contract"))
        XCTAssertTrue(
            DefaultWorkspace.fileName(forSource: first)
                .hasSuffix("." + WorkspaceArchive.fileExtension)
        )
    }

    /// A source whose name cannot be a path component must still resolve to
    /// one, and must not escape the workspace directory.
    func testAnAwkwardDocumentNameStaysOnePathComponent() {
        for name in ["..", ".", ".hidden.txt", "a:b.txt", " "] {
            let url = URL(fileURLWithPath: "/matters/a").appendingPathComponent(name)
            let resolved = DefaultWorkspace.url(forSource: url, in: workspaceDir)
            XCTAssertEqual(
                resolved.deletingLastPathComponent().standardizedFileURL,
                workspaceDir.standardizedFileURL,
                "\(name) escaped the workspace directory as \(resolved.path)"
            )
            XCTAssertFalse(resolved.lastPathComponent.hasPrefix("."), name)
        }
    }

    // MARK: - Helpers

    /// Restore `redacted` with `mapping` and assert the original text is back.
    private func assertRestores(
        _ redacted: URL,
        with mapping: Mapping,
        in session: SessionModel,
        to expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let output = workDir.appendingPathComponent("restored-\(UUID().uuidString).txt")
        let report = try session.restoreFile(redacted, mapping: mapping, output: output)
        XCTAssertGreaterThan(report.restoredCount, 0, "nothing was put back", file: file, line: line)
        XCTAssertTrue(report.orphanTokens.isEmpty, "orphans: \(report.orphanTokens)", file: file, line: line)
        XCTAssertEqual(
            try String(contentsOf: output, encoding: .utf8),
            expected,
            "restore must reproduce the original text",
            file: file,
            line: line
        )
    }
}
