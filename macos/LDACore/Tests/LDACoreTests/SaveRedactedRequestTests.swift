//
//  SaveRedactedRequestTests.swift
//  LDACoreTests
//
//  Review 2026-11-11, F12. Save Redacted exported whichever document was
//  active when the sheet was confirmed. The gate was checked once, before
//  the folder panel opened, and the panel is not modal: selecting another
//  tray row, or Scan All moving the selection, then wrote
//  <other>_redacted.txt for a document that was never scanned, with zero
//  entities, and ReviewModel.export itself checked no status.
//
//  A save is now a request that names the document it was made for
//  (SessionModel.saveRedactedRequest, taken when the panel opens), the gate
//  is checked again on that document immediately before the export, and
//  ReviewModel.export refuses a document that is not ready to save.
//
//  Hermetic: every store lives under a per-test directory and the default
//  workspaces are sealed with a passphrase, so no Keychain item is created.
//  Every value is invented.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore
@testable import LDAUI

@MainActor
final class SaveRedactedRequestTests: XCTestCase {

    private static let createdAt = "2026-11-11T00:00:00Z"

    private var workDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SaveRedactedRequestTests-\(UUID().uuidString)", isDirectory: true)
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

    private func outputDirectory() throws -> URL {
        let url = workDir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func written() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: outputDirectory().path).sorted()
    }

    /// Two documents in the tray, only the first scanned and selected.
    private func trayWithOneScannedDocument() async throws -> (SessionModel, SessionModel.DocumentEntry, SessionModel.DocumentEntry) {
        let alpha = try write("alpha.txt", "Mail alice@alpha.example about the matter.")
        let beta = try write("beta.txt", "Mail bob@beta.example about the matter.")
        let session = makeSession()
        await session.addDocuments([alpha, beta])
        let first = try XCTUnwrap(session.entries.first { $0.url.lastPathComponent == "alpha.txt" })
        let second = try XCTUnwrap(session.entries.first { $0.url.lastPathComponent == "beta.txt" })
        session.selectedID = first.id
        await first.model.anonymize()
        XCTAssertEqual(first.model.status, .ready)
        XCTAssertEqual(second.model.status, .imported)
        return (session, first, second)
    }

    // MARK: - The request names its document

    func testTheSaveExportsTheDocumentItWasRequestedForWhateverIsSelectedAtConfirm() async throws {
        let (session, first, second) = try await trayWithOneScannedDocument()
        let request = try XCTUnwrap(session.saveRedactedRequest())

        // While the folder panel is open the user selects the other row.
        session.selectedID = second.id
        let result = try await session.exportRedacted(
            request: request, to: try outputDirectory(), passphrase: nil, createdAtISO8601: Self.createdAt
        )

        XCTAssertEqual(result.redactedURL.lastPathComponent, "alpha_redacted.txt")
        XCTAssertEqual(try written(), ["alpha_redacted.txt"], "nothing is written for the unscanned document")
        let body = try String(contentsOf: result.redactedURL, encoding: .utf8)
        XCTAssertFalse(body.contains("alice@alpha.example"), body)
        XCTAssertEqual(first.model.status, .ready)
    }

    /// The independent review of F12: the sheet's count sentence read the
    /// document selected now, not the one the request names.
    func testTheSheetCountsTheDocumentTheRequestNames() async throws {
        let (session, first, second) = try await trayWithOneScannedDocument()
        let request = try XCTUnwrap(session.saveRedactedRequest())
        session.selectedID = second.id
        XCTAssertTrue(session.reviewModel(for: request) === first.model)
        session.removeDocument(id: first.id)
        XCTAssertNil(session.reviewModel(for: request))
    }

    func testNoRequestIsMadeWhileTheActiveDocumentCannotBeSaved() async throws {
        let (session, _, second) = try await trayWithOneScannedDocument()
        session.selectedID = second.id
        XCTAssertNil(session.saveRedactedRequest(), "an unscanned document cannot be saved")
    }

    // MARK: - The gate is checked again before the export

    func testARequestWhoseDocumentLeftTheTrayRefusesAndWritesNothing() async throws {
        let (session, first, _) = try await trayWithOneScannedDocument()
        let request = try XCTUnwrap(session.saveRedactedRequest())
        session.removeDocument(id: first.id)

        do {
            _ = try await session.exportRedacted(
                request: request, to: try outputDirectory(), passphrase: nil, createdAtISO8601: Self.createdAt
            )
            XCTFail("a save for a document no longer in the tray must refuse")
        } catch {}
        XCTAssertEqual(try written(), [])
    }

    func testARequestWhoseDocumentIsNoLongerReadyRefusesAndWritesNothing() async throws {
        let (session, first, _) = try await trayWithOneScannedDocument()
        let request = try XCTUnwrap(session.saveRedactedRequest())
        // A re-scan started while the panel was open.
        first.model.status = .detecting

        do {
            _ = try await session.exportRedacted(
                request: request, to: try outputDirectory(), passphrase: nil, createdAtISO8601: Self.createdAt
            )
            XCTFail("a save for a document that is being scanned again must refuse")
        } catch {}
        XCTAssertEqual(try written(), [])
    }

    func testTheReviewModelRefusesToExportADocumentThatWasNeverScanned() async throws {
        let (_, _, second) = try await trayWithOneScannedDocument()
        do {
            _ = try await second.model.export(
                to: try outputDirectory(), passphrase: nil, createdAtISO8601: Self.createdAt,
                keepMapping: { _ in self.workDir }
            )
            XCTFail("an unscanned document must not be exported with zero entities")
        } catch {}
        XCTAssertEqual(try written(), [])
    }
}
