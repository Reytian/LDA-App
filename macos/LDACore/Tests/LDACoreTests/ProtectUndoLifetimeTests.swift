//
//  ProtectUndoLifetimeTests.swift
//  LDACoreTests
//
//  Review 2026-11-11, F15. Protect's undo outlived its document. The step was
//  registered with the window's UndoManager, which does not retain its
//  target: after the document was removed from the tray, Cmd-Z called a
//  deallocated model (the probe aborted), and after a re-scan it wrote back
//  the entity list of the old scan.
//
//  A model's undo steps are now removed when its document is removed from
//  the tray (one document, the whole tray for a workspace or a matter
//  switch), replaced by another file, or scanned again, and a step that
//  outlives its scan does nothing when run.
//
//  These tests count the window's undo steps rather than calling a removed
//  document's step: that call is the crash.
//
//  Hermetic: every store lives under a per-test directory. Every value is
//  invented.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore
@testable import LDAUI

@MainActor
final class ProtectUndoLifetimeTests: XCTestCase {

    private static let body = "Agreement between Jordan Ellis and the buyer. Jordan Ellis signs."

    private var workDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProtectUndoLifetimeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
        try super.tearDownWithError()
    }

    private func makeSession() -> SessionModel {
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
        let workspaces = workDir.appendingPathComponent("workspaces", isDirectory: true)
        try? FileManager.default.createDirectory(at: workspaces, withIntermediateDirectories: true)
        session.defaultWorkspaceDirectory = { workspaces }
        session.defaultWorkspaceProtection = { _ in .passphrase("workspace-pw") }
        return session
    }

    private func write(_ name: String, _ content: String) throws -> URL {
        let url = workDir.appendingPathComponent(name)
        try Data(content.utf8).write(to: url)
        return url
    }

    /// A scanned document with one Protect step registered in `undo`.
    private func protectedDocument(
        in session: SessionModel,
        undo: UndoManager
    ) async throws -> SessionModel.DocumentEntry {
        let url = try write("agreement-\(UUID().uuidString).txt", Self.body)
        await session.addDocuments([url])
        let entry = try XCTUnwrap(session.entries.last)
        session.selectedID = entry.id
        await entry.model.anonymize()
        let range = (Self.body as NSString).range(of: "Jordan Ellis")
        // One user event, one closed undo group, as the menu command makes it.
        undo.beginUndoGrouping()
        let outcome = entry.model.protectSelection(range: range, type: .person, undoManager: undo)
        undo.endUndoGrouping()
        XCTAssertNil(outcome.refusal, "fixture: the protect must change the list")
        XCTAssertTrue(undo.canUndo, "fixture: the protect registered a step")
        return entry
    }

    // MARK: - The document goes away

    func testRemovingTheDocumentFromTheTrayRemovesItsSteps() async throws {
        let session = makeSession()
        let undo = UndoManager()
        undo.groupsByEvent = false
        let entry = try await protectedDocument(in: session, undo: undo)

        session.removeDocument(id: entry.id)

        XCTAssertFalse(undo.canUndo, "Cmd-Z would call the removed document's model")
    }

    func testClearingTheTrayForAnotherMatterRemovesEverySteps() async throws {
        let session = makeSession()
        let undo = UndoManager()
        undo.groupsByEvent = false
        _ = try await protectedDocument(in: session, undo: undo)

        XCTAssertTrue(session.selectClient("Matter B", discardingDocuments: true))

        XCTAssertFalse(undo.canUndo)
    }

    func testReplacingTheDocumentRemovesItsSteps() async throws {
        let session = makeSession()
        let undo = UndoManager()
        undo.groupsByEvent = false
        let entry = try await protectedDocument(in: session, undo: undo)

        await entry.model.open(try write("other.txt", "Another agreement with nobody in it."))

        XCTAssertFalse(undo.canUndo)
    }

    // MARK: - The scan it belonged to is replaced

    func testAReScanRemovesTheStepsOfTheOldScan() async throws {
        let session = makeSession()
        let undo = UndoManager()
        undo.groupsByEvent = false
        let entry = try await protectedDocument(in: session, undo: undo)

        await entry.model.anonymize()
        let rescanned = entry.model.entities

        XCTAssertFalse(undo.canUndo, "the step would write back the old scan's list")
        if undo.canUndo { undo.undo() }
        XCTAssertEqual(entry.model.entities, rescanned)
    }

    func testAStepThatOutlivesItsScanDoesNothing() async throws {
        let session = makeSession()
        let undo = UndoManager()
        undo.groupsByEvent = false
        let entry = try await protectedDocument(in: session, undo: undo)
        let protected = entry.model.entities

        // The scan the step belonged to is retired without the step being
        // removed (a second window's undo manager, say).
        entry.model.retireProtectUndoSteps()
        XCTAssertTrue(undo.canUndo)
        undo.undo()

        XCTAssertEqual(entry.model.entities, protected, "a stale step writes nothing back")
    }
}
