//
//  ComplianceReportUITests.swift
//  LDACoreTests
//
//  The UI wiring for the exportable compliance report (F6): the hand-to-AI
//  build stamps the report fields onto the session record, the export gate
//  follows the session record, and the model API behind the Export Report
//  button writes both deliverables (report.md and report.pdf) whose Markdown
//  is byte-identical to the engine render.
//
//  Deterministic-only sessions (useLLM = false); hermetic stores under
//  FileManager.temporaryDirectory with passphrase protection (no Keychain).
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import PDFKit
import XCTest
@testable import LDACore
@testable import LDAUI

@MainActor
final class ComplianceReportUITests: XCTestCase {

    private static let createdAt = "2026-08-31T00:00:00Z"
    private static let generatedAt = "2026-08-31T01:02:03Z"

    private var workDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ComplianceReportUITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
        try super.tearDownWithError()
    }

    private func write(_ name: String, _ content: String) throws -> URL {
        let url = workDir.appendingPathComponent(name)
        try Data(content.utf8).write(to: url)
        return url
    }

    /// A deterministic-only session over hermetic temp-rooted stores,
    /// mirroring the SessionModelTests fixture.
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
        return session
    }

    /// Load the session's current record through the same store the model uses.
    private func currentRecord(of session: SessionModel) throws -> SessionRecord {
        let id = try XCTUnwrap(session.currentRecordID)
        return try XCTUnwrap(
            session.recordStore().load(id: id, protection: session.recordProtection())
        )
    }

    // MARK: - Record fields

    func testHandoffStampsComplianceFieldsOntoTheRecord() async throws {
        let session = makeSession()
        session.appVersionProvider = { "9.9-test" }
        session.outputStyleProvider = { .token }

        let doc = try write("a.txt", "Mail john@acme.com or call 13812345678 please.")
        await session.addDocuments([doc])
        await session.anonymizeAll()
        // A display-name source for the model column, without running any AI.
        session.entries[0].model.modelPath = "/tmp/models/quick-q4.gguf"

        XCTAssertNotNil(try session.buildHandToAI(createdAtISO8601: Self.createdAt))

        let record = try currentRecord(of: session)
        XCTAssertEqual(record.substitutionStyle, .token)
        XCTAssertEqual(record.appVersion, "9.9-test")
        XCTAssertEqual(record.modelName, "quick-q4.gguf")
        XCTAssertEqual(
            record.scanVerification,
            SessionScanVerification(
                rescanHitCount: 0,
                rescanWarningCount: 0,
                forensicsSuspectCount: 0
            )
        )
        XCTAssertEqual(
            record.documents.first?.entityCountsByType,
            ["EMAIL": 1, "PHONE": 1]
        )
    }

    func testHandoffWithoutAModelRecordsNoModelName() async throws {
        let session = makeSession()
        let doc = try write("a.txt", "Mail john@acme.com please.")
        await session.addDocuments([doc])
        await session.anonymizeAll()

        XCTAssertNotNil(try session.buildHandToAI(createdAtISO8601: Self.createdAt))

        let record = try currentRecord(of: session)
        XCTAssertNil(record.modelName)
    }

    // MARK: - Gate

    func testExportGateFollowsTheSessionRecord() async throws {
        let session = makeSession()
        XCTAssertFalse(session.canExportComplianceReport)

        let doc = try write("a.txt", "Mail john@acme.com please.")
        await session.addDocuments([doc])
        await session.anonymizeAll()
        XCTAssertFalse(session.canExportComplianceReport, "no record before the handoff")

        XCTAssertNotNil(try session.buildHandToAI(createdAtISO8601: Self.createdAt))
        XCTAssertTrue(session.canExportComplianceReport)

        // Crossing the matter boundary clears the round-trip context, and the
        // report gate must close with it.
        XCTAssertTrue(try session.selectMatter("Matter B", discardingDocuments: true))
        XCTAssertFalse(session.canExportComplianceReport)
    }

    func testExportWithoutARecordThrows() throws {
        let session = makeSession()
        XCTAssertThrowsError(
            try session.exportComplianceReport(
                to: workDir,
                generatedAtISO8601: Self.generatedAt
            )
        )
    }

    // MARK: - Written deliverables

    func testExportedMarkdownMatchesTheEngineRenderAndPdfIsWritten() async throws {
        let session = makeSession()
        session.appVersionProvider = { "9.9-test" }
        let doc = try write("a.txt", "Mail john@acme.com please.")
        await session.addDocuments([doc])
        await session.anonymizeAll()
        XCTAssertNotNil(try session.buildHandToAI(createdAtISO8601: Self.createdAt))

        let outDir = workDir.appendingPathComponent("report-out", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let written = try session.exportComplianceReport(
            to: outDir,
            generatedAtISO8601: Self.generatedAt
        )

        let record = try currentRecord(of: session)
        let expected = ComplianceReport.markdown(
            record: record,
            generatedAtISO8601: Self.generatedAt
        )
        XCTAssertEqual(
            try String(contentsOf: written.markdown, encoding: .utf8),
            expected,
            "the written report.md must be the engine render, byte for byte"
        )
        XCTAssertEqual(written.markdown.lastPathComponent, "report.md")
        XCTAssertEqual(written.pdf.lastPathComponent, "report.pdf")

        let pdfData = try Data(contentsOf: written.pdf)
        XCTAssertTrue(pdfData.count > 4, "the PDF twin must not be empty")
        XCTAssertEqual(
            String(decoding: pdfData.prefix(4), as: UTF8.self),
            "%PDF",
            "report.pdf must be a real PDF"
        )
    }

    func testPdfRendererPaginatesLongReports() throws {
        // A record long enough that the monospaced body cannot fit one A4
        // page, so the paginator must emit several pages without looping.
        let documents = (1...220).map {
            SessionRecordDocument(
                name: "exhibit-\($0).txt",
                entityCount: $0,
                entityTypes: ["PERSON"],
                entityCountsByType: ["PERSON": $0]
            )
        }
        let record = SessionRecord(
            createdAtISO8601: Self.createdAt,
            clientLabel: "Long Matter",
            documents: documents,
            protectedValueCount: 220
        )
        let markdown = ComplianceReport.markdown(
            record: record,
            generatedAtISO8601: Self.generatedAt
        )
        let data = ComplianceReportPDF.render(markdown: markdown)
        XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "%PDF")
        let pdf = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertGreaterThan(pdf.pageCount, 1, "a long report must span several pages")
        XCTAssertTrue(
            (pdf.page(at: 0)?.string ?? "").contains("Anonymization Processing Report"),
            "the rendered PDF must carry the report title"
        )
    }
}
