//
//  WorkspaceMappingBindingTests.swift
//  LDACoreTests
//
//  Review 2026-11-11, F11. A mapping is not tied to the file it produced:
//  day 1 saves B with {EMAIL_1} = bob in B's workspace; day 2 saves A first
//  (the session gives {EMAIL_1} to alice), then B again, and B's workspace is
//  rewritten so the day-one file restores bob's places as alice.
//
//  Two rounds of fixes to the export seed and the restore choice each moved a
//  wrong restore somewhere else, so this release keeps 2.0's mapping choice
//  (owner's decision after the second independent review), pinned scenario
//  by scenario in F11ReleaseBehaviourTests, and binding each file to the
//  mapping that wrote it is designed separately
//  (docs/design/mapping-identity.md). What stays tested here: the files of
//  the session that wrote them restore right every way, a Word file and its
//  header carry the tokens its text spells, and a workspace that exists but
//  will not open is not overwritten when it would seed the export.
//
//  Hermetic: every store lives under a per-test directory and the default
//  workspaces are sealed with a passphrase, so no Keychain item is created.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore
@testable import LDAUI

@MainActor
final class WorkspaceMappingBindingTests: XCTestCase {

    private static let createdAt = "2026-11-11T00:00:00Z"
    private static let bodyA = "Engagement Letter. Mail alice@alpha.example about the matter."
    private static let bodyB = "Engagement Letter. Mail bob@beta.example about the matter."
    private static let bodyC = "Engagement Letter. Mail carol@gamma.example about the matter."
    private static let sharedA = "Mail alice@alpha.example, bob@beta.example and dan@beta.example about the matter."
    private static let sharedB = "Mail bob@beta.example and dan@beta.example about the matter."

    private var workDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceMappingBindingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
        try super.tearDownWithError()
    }

    private func makeSession(workspacePassphrase: String = "workspace-pw") -> SessionModel {
        let session = SessionModel(
            makeModel: {
                let model = ReviewModel(modelPath: nil)
                model.useLLM = false
                return model
            },
            clientStore: { try ClientMappingStore(rootDirectory: self.workDir.appendingPathComponent("clients")) }
        )
        session.clientProtection = { _ in .passphrase("pw") }
        session.recordStore = { try SessionRecordStore(rootDirectory: self.workDir.appendingPathComponent("records")) }
        session.recordProtection = { .passphrase("pw") }
        session.matterStore = { try MatterMetadataStore(rootDirectory: self.workDir.appendingPathComponent("matters")) }
        session.matterProtection = { .passphrase("pw") }
        let parked = workDir.appendingPathComponent("parked/parked.ldamap")
        try? FileManager.default.createDirectory(at: parked.deletingLastPathComponent(), withIntermediateDirectories: true)
        session.parkedMappingURL = { parked }
        session.parkedProtection = { .passphrase("parked-pw") }
        session.exportSidecarProtection = { _ in .passphrase("ai-sidecar-pw") }
        let workspaces = workDir.appendingPathComponent("workspaces", isDirectory: true)
        try? FileManager.default.createDirectory(at: workspaces, withIntermediateDirectories: true)
        session.defaultWorkspaceDirectory = { workspaces }
        session.defaultWorkspaceProtection = { _ in .passphrase(workspacePassphrase) }
        return session
    }

    private func write(_ name: String, _ content: String) throws -> URL {
        let url = workDir.appendingPathComponent(name)
        try Data(content.utf8).write(to: url)
        return url
    }

    private func outputDirectory(_ name: String) -> URL {
        workDir.appendingPathComponent(name, isDirectory: true)
    }

    /// Export `document` from `session`, making it the active one first.
    private func export(_ document: URL, from session: SessionModel, into folder: String) async throws -> ExportResult {
        let entry = try XCTUnwrap(session.entries.first { $0.url.standardizedFileURL == document.standardizedFileURL })
        session.selectedID = entry.id
        return try await session.exportRedacted(to: outputDirectory(folder), passphrase: nil, createdAtISO8601: Self.createdAt)
    }

    private func dayOne(_ documentB: URL) async throws -> ExportResult {
        let session = makeSession()
        await session.addDocuments([documentB])
        await session.anonymizeAll()
        return try await export(documentB, from: session, into: "day1")
    }

    private func restored(_ redacted: URL, with mapping: Mapping) throws -> String {
        Restorer.restore(text: try String(contentsOf: redacted, encoding: .utf8), mapping: mapping).text
    }

    private func writeDocx(_ name: String, _ line: String, header: String? = nil) throws -> URL {
        guard let header else {
            return try DocxTestPackage.write(
                body: DocxTestPackage.paragraph(DocxTestPackage.run(line)),
                to: workDir.appendingPathComponent(name)
            )
        }
        return try DocxTestPackage.write(
            body: DocxTestPackage.paragraph(DocxTestPackage.run(line)) + DocxTestPackage.sectionWithHeaderAndFooter,
            extraParts: [
                ("word/header1.xml", DocxTestPackage.wordPart(
                    rootTag: "hdr", body: DocxTestPackage.paragraph(DocxTestPackage.run(header))
                )),
                ("word/footer1.xml", DocxTestPackage.wordPart(
                    rootTag: "ftr", body: DocxTestPackage.paragraph(DocxTestPackage.run("Page"))
                ))
            ],
            to: workDir.appendingPathComponent(name)
        )
    }

    /// The header of a redacted Word file restored with `mapping`, as XML.
    private func restoredHeader(of redacted: URL, with mapping: Mapping) throws -> String {
        let mappingURL = workDir.appendingPathComponent("header-\(UUID().uuidString).ldamap")
        try MappingStore.save(mapping, to: mappingURL, protection: .passphrase("header-pw"))
        let restoredURL = workDir.appendingPathComponent("restored-\(UUID().uuidString).docx")
        _ = try LDAService.restore(editedRedacted: redacted, mapping: mappingURL,
                                   protection: .passphrase("header-pw"), output: restoredURL)
        return try DocxTestPackage.readPart("word/header1.xml", from: restoredURL)
    }

    /// The text of an exported file, a Word file read through its importer.
    private func text(of result: ExportResult) throws -> String {
        let url = result.redactedURL
        if url.pathExtension == "docx" { return try DocxImporter().importDocument(url).text }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func mapping(from source: SessionModel.RestoreMappingSource) -> Mapping? {
        switch source {
        case .session(let found), .defaultWorkspace(let found), .clientProfile(let found): return found
        default: return nil
        }
    }

    /// `redacted` saved as a file named `name` (no sidecar beside it) and
    /// restored with the mapping restore picks for that file.
    private func restoredAsFile(
        named name: String,
        _ redacted: String,
        in session: SessionModel,
        folder: URL? = nil
    ) throws -> String? {
        let url = (folder ?? workDir).appendingPathComponent(name)
        try Data(redacted.utf8).write(to: url)
        guard let found = mapping(from: try session.restoreMappingSource(for: url)) else { return nil }
        return Restorer.restore(text: redacted, mapping: found).text
    }

    // MARK: - The files of the session that wrote them

    /// After the day-two exports, B's new file restores to B's values through
    /// the session mapping, as an AI reply saved under a new name, through
    /// the clipboard, and with B's workspace (the first F11 fix had broken
    /// the reply and the clipboard).
    func testTheDayTwoFileRestoresTheSameThroughTheSessionAndItsWorkspace() async throws {
        let documentA = try write("alpha.txt", Self.bodyA)
        let documentB = try write("beta.txt", Self.bodyB)
        _ = try await dayOne(documentB)

        let dayTwo = makeSession()
        await dayTwo.addDocuments([documentA, documentB])
        await dayTwo.anonymizeAll()
        _ = try await export(documentA, from: dayTwo, into: "day2")
        let second = try await export(documentB, from: dayTwo, into: "day2")
        let redacted = try String(contentsOf: second.redactedURL, encoding: .utf8)

        let reply = try write("reply-from-ai.txt", redacted)
        let source = try dayTwo.restoreMappingSource(for: reply)
        let mapping: Mapping
        switch source {
        case .session(let found), .defaultWorkspace(let found), .clientProfile(let found): mapping = found
        default: return XCTFail("no mapping for the reply: \(source)")
        }
        XCTAssertEqual(Restorer.restore(text: redacted, mapping: mapping).text, Self.bodyB, "the reply under a new name")
        let session = try XCTUnwrap(dayTwo.sessionMapping)
        XCTAssertEqual(Restorer.restore(text: redacted, mapping: session).text, Self.bodyB, "the clipboard path")
        let workspace = try XCTUnwrap(try makeSession().defaultWorkspaceMapping(forSource: documentB))
        XCTAssertEqual(try restored(second.redactedURL, with: workspace), Self.bodyB, "B's own workspace")
    }

    /// The same day two with Word files (second independent review of F11):
    /// the Word rewrite takes the tokens the tokenizer gave this text
    /// (TokenizeResult.replacementBySurface), so the .docx restores like the
    /// text, through the session, B's workspace and as a reply restored as a
    /// Word file.
    func testAWordDayTwoFileRestoresTheSameThroughTheSessionAndItsWorkspace() async throws {
        let documentA = try writeDocx("alpha.docx", Self.bodyA)
        let documentB = try writeDocx("beta.docx", Self.bodyB)
        let dayOneSession = makeSession()
        await dayOneSession.addDocuments([documentB])
        await dayOneSession.anonymizeAll()
        _ = try await export(documentB, from: dayOneSession, into: "day1")

        let dayTwo = makeSession()
        await dayTwo.addDocuments([documentA, documentB])
        await dayTwo.anonymizeAll()
        let otherFile = try await export(documentA, from: dayTwo, into: "day2")
        let second = try await export(documentB, from: dayTwo, into: "day2")
        let redactedA = try text(of: otherFile)
        let redactedB = try text(of: second)

        let session = try XCTUnwrap(dayTwo.sessionMapping)
        XCTAssertEqual(Restorer.restore(text: redactedB, mapping: session).text, Self.bodyB, "B through the session")
        XCTAssertEqual(Restorer.restore(text: redactedA, mapping: session).text, Self.bodyA, "A through the session")
        let workspace = try XCTUnwrap(try makeSession().defaultWorkspaceMapping(forSource: documentB))
        XCTAssertEqual(Restorer.restore(text: redactedB, mapping: workspace).text, Self.bodyB, "B's own workspace")

        // The AI's reply about B, edited in Word and saved under a new name,
        // restored as a Word file with the mapping restore picks for it.
        let reply = workDir.appendingPathComponent("reply-from-ai.docx")
        try FileManager.default.copyItem(at: second.redactedURL, to: reply)
        let picked = try XCTUnwrap(mapping(from: try dayTwo.restoreMappingSource(for: reply)))
        let mappingURL = workDir.appendingPathComponent("picked.ldamap")
        try MappingStore.save(picked, to: mappingURL, protection: .passphrase("picked-pw"))
        let restoredURL = workDir.appendingPathComponent("restored.docx")
        _ = try LDAService.restore(editedRedacted: reply, mapping: mappingURL,
                                   protection: .passphrase("picked-pw"), output: restoredURL)
        XCTAssertEqual(try DocxImporter().importDocument(restoredURL).text, Self.bodyB, "the restored Word reply")
    }

    /// The Word header pass looked tokens up in the mapping in dictionary
    /// order. It now spells the body's token for a value the body has, and a
    /// value only the header carries gets a token of its own that restores.
    func testAWordHeaderSpellsTheBodysTokens() async throws {
        let documentA = try write("alpha.txt", "Mail alice@alpha.example and carol@gamma.example about the matter.")
        let documentB = try writeDocx(
            "beta.docx", Self.bodyB,
            header: "Copy bob@beta.example and dan@beta.example on every page."
        )
        let dayOneSession = makeSession()
        await dayOneSession.addDocuments([documentB])
        await dayOneSession.anonymizeAll()
        _ = try await export(documentB, from: dayOneSession, into: "day1")

        let dayTwo = makeSession()
        await dayTwo.addDocuments([documentA, documentB])
        await dayTwo.anonymizeAll()
        _ = try await export(documentA, from: dayTwo, into: "day2")
        let second = try await export(documentB, from: dayTwo, into: "day2")

        let session = try XCTUnwrap(dayTwo.sessionMapping)
        let header = try restoredHeader(of: second.redactedURL, with: session)
        XCTAssertTrue(header.contains("Copy bob@beta.example and dan@beta.example on every page."),
                      "the day-2 header through the session: \(header)")
        XCTAssertFalse(header.contains("alice@alpha.example") || header.contains("carol@gamma.example"), header)
        let workspace = try XCTUnwrap(try makeSession().defaultWorkspaceMapping(forSource: documentB))
        let restored = try restoredHeader(of: second.redactedURL, with: workspace)
        XCTAssertTrue(restored.contains("Copy bob@beta.example and dan@beta.example on every page."),
                      "the day-2 header through B's workspace: \(restored)")
    }

    /// Values the two documents share (second independent review of F11):
    /// day 1 saves B (bob, dan), day 2 saves A (alice, bob, dan), then B.
    func testValuesBothDocumentsHoldRestoreTheSameThroughTheSession() async throws {
        let documentA = try write("alpha.txt", Self.sharedA)
        let documentB = try write("beta.txt", Self.sharedB)
        _ = try await dayOne(documentB)

        let dayTwo = makeSession()
        await dayTwo.addDocuments([documentA, documentB])
        await dayTwo.anonymizeAll()
        let otherFile = try await export(documentA, from: dayTwo, into: "day2")
        let second = try await export(documentB, from: dayTwo, into: "day2")

        let session = try XCTUnwrap(dayTwo.sessionMapping)
        XCTAssertEqual(try restored(second.redactedURL, with: session), Self.sharedB, "B through the session")
        XCTAssertEqual(try restored(otherFile.redactedURL, with: session), Self.sharedA, "A through the session")
        let workspace = try XCTUnwrap(try makeSession().defaultWorkspaceMapping(forSource: documentB))
        XCTAssertEqual(try restored(second.redactedURL, with: workspace), Self.sharedB, "B's own workspace")
        let workspaceA = try XCTUnwrap(try makeSession().defaultWorkspaceMapping(forSource: documentA))
        XCTAssertEqual(try restored(otherFile.redactedURL, with: workspaceA), Self.sharedA, "A's own workspace")
    }

    /// Three documents over two days (second independent review of F11):
    /// each day-two file restored by its own name, as a reply under a new
    /// name and through the session, and one reply quoting all three.
    func testThreeDocumentsOverTwoDaysRestoreEveryWayAUserWould() async throws {
        let documentA = try write("alpha.txt", Self.bodyA)
        let documentB = try write("beta.txt", Self.bodyB)
        let documentC = try write("gamma.txt", Self.bodyC)

        let dayOneSession = makeSession()
        await dayOneSession.addDocuments([documentB, documentC])
        await dayOneSession.anonymizeAll()
        _ = try await export(documentB, from: dayOneSession, into: "day1")
        _ = try await export(documentC, from: dayOneSession, into: "day1")

        let dayTwo = makeSession()
        await dayTwo.addDocuments([documentA, documentB, documentC])
        await dayTwo.anonymizeAll()
        let secondA = try await export(documentA, from: dayTwo, into: "day2")
        let secondC = try await export(documentC, from: dayTwo, into: "day2")
        let secondB = try await export(documentB, from: dayTwo, into: "day2")
        let session = try XCTUnwrap(dayTwo.sessionMapping)

        for (label, result, body) in [("A", secondA, Self.bodyA), ("B", secondB, Self.bodyB), ("C", secondC, Self.bodyC)] {
            let redacted = try String(contentsOf: result.redactedURL, encoding: .utf8)
            XCTAssertEqual(try restoredAsFile(named: "reply-\(label).txt", redacted, in: dayTwo), body,
                           "the day-2 file of \(label) as a reply under a new name")
            XCTAssertEqual(try restoredAsFile(named: result.redactedURL.lastPathComponent, redacted, in: dayTwo), body,
                           "the day-2 file of \(label) by its own name")
            XCTAssertEqual(Restorer.restore(text: redacted, mapping: session).text, body,
                           "the day-2 file of \(label) through the session")
        }

        let quoted = try [secondA, secondB, secondC]
            .map { try String(contentsOf: $0.redactedURL, encoding: .utf8) }
            .joined(separator: "\n")
        XCTAssertEqual(Restorer.restore(text: quoted, mapping: session).text,
                       [Self.bodyA, Self.bodyB, Self.bodyC].joined(separator: "\n"),
                       "one reply quoting all three files")
    }

    // MARK: - A workspace that will not open

    /// Kept from F11: 2.0 read the workspace that seeds an export with try?,
    /// so a locked or refused Keychain read as "no seed" and the export
    /// replaced it, stranding the files earlier exports wrote.
    func testAWorkspaceThatExistsButWillNotOpenIsNotOverwritten() async throws {
        let documentB = try write("beta.txt", Self.bodyB)
        let first = try await dayOne(documentB)

        // A later session cannot open B's workspace (another key).
        let locked = makeSession(workspacePassphrase: "another-key")
        await locked.addDocuments([documentB])
        await locked.anonymizeAll()
        do {
            _ = try await export(documentB, from: locked, into: "day2")
            XCTFail("an export that cannot read the workspace it would replace must refuse")
        } catch {}

        let workspace = try XCTUnwrap(try makeSession().defaultWorkspaceMapping(forSource: documentB))
        XCTAssertEqual(try restored(first.redactedURL, with: workspace), Self.bodyB, "the workspace is untouched")
    }

    // MARK: - Restore order

    func testASessionMappingThatAgreesWithTheWorkspaceIsUsedFirst() async throws {
        // 2.0's restore order.
        let documentB = try write("beta.txt", Self.bodyB)
        let session = makeSession()
        await session.addDocuments([documentB])
        await session.anonymizeAll()
        let result = try await export(documentB, from: session, into: "same")
        guard case .session = try session.restoreMappingSource(for: result.redactedURL) else {
            return XCTFail("a session mapping that covers the workspace keeps its place in the order")
        }
    }
}
