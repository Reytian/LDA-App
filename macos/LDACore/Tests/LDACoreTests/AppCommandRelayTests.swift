//
//  AppCommandRelayTests.swift
//  LDACoreTests
//
//  Review 2026-11-11, F13. Commands were per-document counters observed
//  through the active document. Switching between two tray documents whose
//  anonymizeRequestToken differed looked like a scan request, so the newly
//  selected document was scanned and a reviewed one re-scanned (its
//  keep-visible choices and manual protections dropped); the restore and
//  export counters opened their panels the same way, and so did the Protect
//  Selection counter for its chooser. The handlers hung off
//  Group { if isActive { ... } }, so a command issued from Restore, Fill or
//  Matters switched mode and did nothing, a double-clicked .ldawork was not
//  opened, and the card resets on a matter or selection change never ran.
//
//  Now one AppCommand at a time goes through a relay the session owns:
//  RootShell, which is never torn down, switches to the command's mode, and
//  that mode's shell takes it once, when it is active. Selecting a document
//  is not a command. The shell's card belongs to the matter and document it
//  was shown for (AppShellCardContext), checked again when the shell comes
//  back. The chooser opens only for a request made on the document it shows
//  (ChooserRequestGate).
//
//  The shells themselves are views; these tests drive the relay and the two
//  decisions the views now delegate.
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
final class AppCommandRelayTests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppCommandRelayTests-\(UUID().uuidString)", isDirectory: true)
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
        session.exportSidecarProtection = { _ in .passphrase("ai-sidecar-pw") }
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

    /// Two documents in the tray, the first scanned, the second not.
    private func tray() async throws -> (SessionModel, SessionModel.DocumentEntry, SessionModel.DocumentEntry) {
        let alpha = try write("alpha.txt", "Mail alice@alpha.example about the matter.")
        let beta = try write("beta.txt", "Mail bob@beta.example about the matter.")
        let session = makeSession()
        await session.addDocuments([alpha, beta])
        let first = try XCTUnwrap(session.entries.first { $0.url.lastPathComponent == "alpha.txt" })
        let second = try XCTUnwrap(session.entries.first { $0.url.lastPathComponent == "beta.txt" })
        session.selectedID = first.id
        await first.model.anonymize()
        return (session, first, second)
    }

    // MARK: - Selecting a document is not a command

    func testSelectingAnotherDocumentAsksForNothing() async throws {
        let (session, first, second) = try await tray()

        // The menu commands for the selected document, each taken once.
        session.requestScan()
        XCTAssertEqual(session.commands.take(for: .anonymize), .scan(documentID: first.id))
        session.requestSaveRedacted()
        XCTAssertEqual(session.commands.take(for: .anonymize), .saveRedacted(documentID: first.id))
        session.requestRestore()
        XCTAssertEqual(session.commands.take(for: .deanonymize), .restore)

        // Selecting the other document, and back again, is not a request.
        session.selectedID = second.id
        XCTAssertNil(session.commands.take(for: .anonymize), "selecting a document is not a scan or a save")
        XCTAssertNil(session.commands.take(for: .deanonymize), "nor a restore")
        session.selectedID = first.id
        XCTAssertNil(session.commands.take(for: .anonymize))
        XCTAssertNil(session.commands.take(for: .deanonymize))
        XCTAssertEqual(second.model.status, .imported, "the unscanned document was not scanned")
    }

    func testACommandTheDocumentCannotTakeIsNotQueued() async throws {
        let (session, _, second) = try await tray()
        session.selectedID = second.id
        session.requestSaveRedacted()
        XCTAssertNil(session.commands.take(for: .anonymize), "an unscanned document cannot be saved")
    }

    func testAScanIsNotQueuedForADocumentWhoseImportFailed() async throws {
        let (session, _, second) = try await tray()
        session.selectedID = second.id
        second.model.status = .failed("unreadable")
        session.requestScan()
        XCTAssertNil(session.commands.take(for: .anonymize),
                     "an empty document must not be scannable; re-opening is the recovery")
    }

    // MARK: - No command is lost to the mode it was issued from

    func testACommandIssuedFromAnotherModeWaitsForItsModeAndIsTakenOnce() {
        let session = makeSession()

        // Cmd-O pressed while Restore is shown.
        session.requestOpen()
        XCTAssertEqual(session.commands.nextMode, .anonymize, "RootShell switches to Redact first")
        XCTAssertNil(session.commands.take(for: .deanonymize), "Restore does not take Redact's command")
        XCTAssertEqual(session.commands.take(for: .anonymize), .openDocuments)
        XCTAssertNil(session.commands.take(for: .anonymize), "taken once")
        XCTAssertNil(session.commands.nextMode)

        // A double-clicked workspace and report, Export for AI and Scan All.
        let workspace = workDir.appendingPathComponent("matter.ldawork")
        let report = workDir.appendingPathComponent("matter.ldareport")
        session.requestOpenWorkspace(workspace)
        session.requestOpenReport(report)
        session.requestExportForAI()
        session.requestScanAll()
        XCTAssertEqual(session.commands.take(for: .anonymize), .openWorkspace(workspace))
        XCTAssertEqual(session.commands.take(for: .anonymize), .openReport(report))
        XCTAssertEqual(session.commands.take(for: .anonymize), .exportForAI)
        XCTAssertEqual(session.commands.take(for: .anonymize), .scanAll)

        // Cmd-R pressed while Redact is shown goes to Restore.
        session.requestRestore()
        XCTAssertEqual(session.commands.nextMode, .deanonymize)
        XCTAssertEqual(session.commands.take(for: .deanonymize), .restore)
    }

    // MARK: - The card belongs to the matter and document it was shown for

    func testTheCardContextChangesWithTheMatterAndTheSelection() async throws {
        let (session, first, second) = try await tray()
        let shown = AppShellCardContext(session: session)
        XCTAssertEqual(AppShellCardContext(session: session), shown)

        session.selectedID = second.id
        XCTAssertNotEqual(AppShellCardContext(session: session), shown, "another document")
        session.selectedID = first.id
        XCTAssertEqual(AppShellCardContext(session: session), shown)

        XCTAssertTrue(session.selectClient("Matter B", discardingDocuments: true))
        XCTAssertNotEqual(AppShellCardContext(session: session), shown, "another matter")
    }

    // MARK: - The Protect Selection chooser

    func testTheChooserOpensOnlyForARequestMadeOnTheDocumentItShows() {
        let alphaModel = NSObject()
        let betaModel = NSObject()
        let alpha = ObjectIdentifier(alphaModel)
        let beta = ObjectIdentifier(betaModel)
        var gate = ChooserRequestGate(owner: alpha, token: 2)
        XCTAssertFalse(gate.update(owner: alpha, token: 2), "nothing new")
        XCTAssertTrue(gate.update(owner: alpha, token: 3), "Protect Selection on the shown document")
        XCTAssertFalse(gate.update(owner: beta, token: 0), "switching to a document with another count")
        XCTAssertFalse(gate.update(owner: alpha, token: 3), "and back")
        XCTAssertTrue(gate.update(owner: alpha, token: 4))
        withExtendedLifetime((alphaModel, betaModel)) {}
    }
}
