//
//  ExportForAIFlowTests.swift
//  LDACoreTests
//
//  The ordering rule of Export for AI: the destination is chosen BEFORE the
//  handoff is built, because buildHandToAI parks the session and writes an
//  activity record. A cancelled panel must leave the session exactly as it
//  was, and the panel must never open when nothing is ready.
//
//  Deterministic-only (no GGUF model). Hermetic: every store lives under the
//  temporary directory with passphrase protection, so no Keychain access.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore
@testable import LDAUI

@MainActor
final class ExportForAIFlowTests: XCTestCase {

    private static let createdAt = "2026-09-02T00:00:00Z"
    private var workDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExportForAIFlowTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
        try super.tearDownWithError()
    }

    private func makeSession() -> SessionModel {
        let clientRoot = workDir.appendingPathComponent("clients")
        let session = SessionModel(
            makeModel: {
                let model = ReviewModel(modelPath: nil)
                model.useLLM = false
                return model
            },
            clientStore: { try ClientMappingStore(rootDirectory: clientRoot) }
        )
        session.clientProtection = { _ in .passphrase("pw") }
        let recordRoot = workDir.appendingPathComponent("records")
        session.recordStore = { try SessionRecordStore(rootDirectory: recordRoot) }
        session.recordProtection = { .passphrase("pw") }
        let matterRoot = workDir.appendingPathComponent("matters")
        session.matterStore = { try MatterMetadataStore(rootDirectory: matterRoot) }
        session.matterProtection = { .passphrase("pw") }
        let parkedURL = workDir.appendingPathComponent("parked-test.ldamap")
        session.parkedMappingURL = { parkedURL }
        session.parkedProtection = { .passphrase("parked-pw") }
        session.exportSidecarProtection = { _ in .passphrase("sidecar-pw") }
        return session
    }

    /// A session with one scanned document, ready to export.
    private func makeReadySession() async throws -> SessionModel {
        let session = makeSession()
        let doc = workDir.appendingPathComponent("a.txt")
        try Data("Mail john@acme.com please.".utf8).write(to: doc)
        await session.addDocuments([doc])
        await session.anonymizeAll()
        return session
    }

    private func assertSessionUntouched(_ session: SessionModel) throws {
        XCTAssertNil(session.sessionMapping)
        XCTAssertNil(session.currentRecordID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try session.parkedMappingURL().path))
        XCTAssertNil(session.entries.first?.model.entities.first?.token)
    }

    func testCancellingTheSavePanelLeavesTheSessionUntouched() async throws {
        let session = try await makeReadySession()
        var panelOpened = false

        let outcome = ExportForAIFlow.run(
            session: session,
            chooseDestination: {
                panelOpened = true
                return nil
            },
            createdAtISO8601: Self.createdAt
        )

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertTrue(panelOpened)
        try assertSessionUntouched(session)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: workDir.path).sorted(), ["a.txt"])
    }

    func testNothingReadyNeverOpensThePanel() async throws {
        let session = makeSession()
        let doc = workDir.appendingPathComponent("a.txt")
        try Data("Untouched.".utf8).write(to: doc)
        await session.addDocuments([doc])
        var panelOpened = false

        let outcome = ExportForAIFlow.run(
            session: session,
            chooseDestination: {
                panelOpened = true
                return nil
            },
            createdAtISO8601: Self.createdAt
        )

        // The reason travels with the outcome: the document IS open, it has
        // just never been scanned, and "add a document" would be wrong advice.
        XCTAssertEqual(outcome, .nothingReady(.scanNotFinished))
        XCTAssertFalse(panelOpened, "no panel when there is nothing to export")
        try assertSessionUntouched(session)
    }

    func testConfirmedDestinationWritesTheFileAndItsSidecar() async throws {
        let session = try await makeReadySession()
        let destination = workDir.appendingPathComponent(ExportForAIFlow.defaultFileName)

        let outcome = ExportForAIFlow.run(
            session: session,
            chooseDestination: { destination },
            createdAtISO8601: Self.createdAt
        )

        guard case .exported(let result) = outcome else {
            return XCTFail("expected an export, got \(outcome)")
        }
        XCTAssertEqual(result.markdownURL, destination)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.mappingURL.path))
        XCTAssertEqual(result.documentCount, 1)
        XCTAssertEqual(result.skippedCount, 0)
        XCTAssertNotNil(session.sessionMapping)
        XCTAssertNotNil(session.currentRecordID)
    }

    func testAFailedWriteIsReportedNotSwallowed() async throws {
        let session = try await makeReadySession()
        let missingFolder = workDir.appendingPathComponent("missing", isDirectory: true)

        let outcome = ExportForAIFlow.run(
            session: session,
            chooseDestination: { missingFolder.appendingPathComponent(ExportForAIFlow.defaultFileName) },
            createdAtISO8601: Self.createdAt
        )

        guard case .failed(let message) = outcome else {
            return XCTFail("expected a failure, got \(outcome)")
        }
        XCTAssertTrue(message.hasPrefix("Could not export the redacted file."), message)
    }
}
