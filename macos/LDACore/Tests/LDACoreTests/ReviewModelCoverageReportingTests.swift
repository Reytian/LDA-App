//
//  ReviewModelCoverageReportingTests.swift
//  LDACoreTests
//
//  The window's half of the supplementary coverage fix. A .docx export
//  redacts the headers, footers, notes, and comments as well as the body, but
//  those hits never enter the review list, so a window that shows only the
//  review list's count under-reports its own output.
//
//  Deterministic detection only (useLLM stays false, so no GGUF model is
//  needed) and every fixture is built at runtime.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore
@testable import LDAUI

@MainActor
final class ReviewModelCoverageReportingTests: XCTestCase {

    private var workDir: URL!

    private static let bodyEmail = "body.party@example.com"
    private static let headerEmail = "header.party@example.com"
    private static let footerPhone = "13800138000"
    private static let createdAt = "2026-09-03T00:00:00Z"

    /// Body: one email. Header: another email. Footer: a phone.
    private static let bodySiteCount = 1
    private static let supplementarySiteCount = 2

    override func setUpWithError() throws {
        try super.setUpWithError()
        assertNoTestSeamsInstalled()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lda-ui-coverage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
        try super.tearDownWithError()
    }

    private func writeAgreement() throws -> URL {
        try DocxTestPackage.write(
            body: DocxTestPackage.paragraph(
                DocxTestPackage.run("Contact \(Self.bodyEmail) for details.")
            ) + DocxTestPackage.sectionWithHeaderAndFooter,
            extraParts: [
                (
                    "word/header1.xml",
                    DocxTestPackage.wordPart(
                        rootTag: "hdr",
                        body: DocxTestPackage.paragraph(
                            DocxTestPackage.run("Counsel \(Self.headerEmail)")
                        )
                    )
                ),
                (
                    "word/footer1.xml",
                    DocxTestPackage.wordPart(
                        rootTag: "ftr",
                        body: DocxTestPackage.paragraph(
                            DocxTestPackage.run("Reception \(Self.footerPhone)")
                        )
                    )
                )
            ],
            to: workDir.appendingPathComponent("agreement.docx")
        )
    }

    // MARK: - Scan time

    func testScanCountsWhatTheHeaderAndFooterWillContribute() async throws {
        let model = ReviewModel(modelPath: nil)

        await model.open(try writeAgreement())
        await model.anonymize()

        XCTAssertEqual(model.status, .ready)
        XCTAssertEqual(model.redactedCount, Self.bodySiteCount, "the review list stays body only")
        XCTAssertEqual(model.supplementaryRedactedCount, Self.supplementarySiteCount)
        XCTAssertEqual(
            model.totalRedactedCount,
            Self.bodySiteCount + Self.supplementarySiteCount,
            "the number the window shows must be the number the export writes"
        )
    }

    func testAPlainTextDocumentHasNoSupplementaryCount() async throws {
        let input = workDir.appendingPathComponent("note.txt")
        try Data("Contact \(Self.bodyEmail) for details.".utf8).write(to: input)
        let model = ReviewModel(modelPath: nil)

        await model.open(input)
        await model.anonymize()

        XCTAssertEqual(model.supplementaryRedactedCount, 0)
        XCTAssertEqual(model.totalRedactedCount, model.redactedCount)
    }

    func testOpeningANewDocumentClearsTheSupplementaryCount() async throws {
        let model = ReviewModel(modelPath: nil)
        await model.open(try writeAgreement())
        await model.anonymize()
        XCTAssertEqual(model.supplementaryRedactedCount, Self.supplementarySiteCount)

        let plain = workDir.appendingPathComponent("plain.txt")
        try Data("Nothing here.".utf8).write(to: plain)
        await model.open(plain)

        XCTAssertEqual(
            model.supplementaryRedactedCount, 0,
            "a stale count from the previous document would mis-state this one"
        )
    }

    // MARK: - Export time

    func testExportReportsTheSameTotalItWrote() async throws {
        let model = ReviewModel(modelPath: nil)
        await model.open(try writeAgreement())
        await model.anonymize()

        let result = try await model.export(
            to: workDir.appendingPathComponent("out", isDirectory: true),
            passphrase: "pw",
            createdAtISO8601: Self.createdAt
        )

        XCTAssertEqual(result.supplementaryEntityCount, Self.supplementarySiteCount)
        XCTAssertEqual(result.entityCount, model.totalRedactedCount)

        // And the total is what a restore of that file puts back.
        let report = try LDAService.restore(
            editedRedacted: result.redactedURL,
            mapping: result.mappingURL,
            protection: .passphrase("pw"),
            output: workDir.appendingPathComponent("restored.docx")
        )
        XCTAssertEqual(report.restoredCount, result.entityCount)
    }

    // MARK: - Presentation

    func testTheSupplementaryNoteExplainsWhyTheCountExceedsTheList() throws {
        XCTAssertNil(
            AnonymizeWorkflowPresentation.supplementaryCoverageNote(count: 0),
            "nothing to explain when nothing sits outside the body"
        )
        let one = try XCTUnwrap(
            AnonymizeWorkflowPresentation.supplementaryCoverageNote(count: 1, language: .english)
        )
        XCTAssertTrue(one.contains("1"), one)
        XCTAssertTrue(one.contains("header"), one)
        let many = try XCTUnwrap(
            AnonymizeWorkflowPresentation.supplementaryCoverageNote(count: 4, language: .english)
        )
        XCTAssertTrue(many.contains("4"), many)
    }
}
