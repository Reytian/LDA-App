//
//  SupplementaryCoverageReportingTests.swift
//  LDACoreTests
//
//  Reporting fidelity for the DOCX parts outside word/document.xml. Redaction
//  has always covered headers, footers, notes, and comments, but the reported
//  entityCount was the BODY span count alone, so a lawyer auditing coverage
//  saw a number smaller than the number of values actually replaced and could
//  conclude the header names had leaked.
//
//  What is pinned here:
//   - AnonymizeResult.entityCount is body sites PLUS supplementary sites,
//   - AnonymizeResult.supplementaryEntityCount isolates the supplementary half,
//   - AnonymizeResult.entities stays BODY ONLY (supplementary entities have no
//     offsets into the body text and must never be given invented ones),
//   - a clean round trip restores exactly entityCount sites, and
//   - LDAService.detectSummary predicts, before anything is written, the same
//     total the run reports.
//
//  Deterministic detection only: this Mac has no GGUF model, and every value
//  below is a type the deterministic engine recognizes.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class SupplementaryCoverageReportingTests: XCTestCase {

    private var workDir: URL!

    // MARK: - Fixture values

    /// In the body once, and again in the footer, so the footer site reuses
    /// the body token and mints NO new mapping entry. It is still a
    /// replacement that happened, so it must be counted.
    private static let sharedEmail = "alice@example.com"
    private static let bodyPhone = "13912345678"
    private static let bodyDate = "2024-01-15"
    /// Header and footer only: values the body never carries.
    private static let headerDate = "2023-12-31"
    private static let headerEmail = "bob@example.com"
    private static let footerPhone = "13800138000"

    /// Body sites: shared email, phone, date.
    private static let bodySiteCount = 3
    /// Supplementary sites: header date, header email, footer phone, footer
    /// email. Four replacements, but only THREE new values (the footer email
    /// is the body's).
    private static let supplementarySiteCount = 4
    private static let totalSiteCount = bodySiteCount + supplementarySiteCount

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lda-supplementary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    private func writeAgreement() throws -> URL {
        let body = DocxTestPackage.paragraph(
            DocxTestPackage.run("Contact \(Self.sharedEmail) for details.")
        )
            + DocxTestPackage.paragraph(
                DocxTestPackage.run("Phone \(Self.bodyPhone) is on file until \(Self.bodyDate).")
            )
            + DocxTestPackage.sectionWithHeaderAndFooter

        let header = DocxTestPackage.wordPart(
            rootTag: "hdr",
            body: DocxTestPackage.paragraph(
                DocxTestPackage.run("Dated \(Self.headerDate), prepared by \(Self.headerEmail)")
            )
        )
        let footer = DocxTestPackage.wordPart(
            rootTag: "ftr",
            body: DocxTestPackage.paragraph(
                DocxTestPackage.run("Enquiries \(Self.footerPhone) or \(Self.sharedEmail)")
            )
        )
        return try DocxTestPackage.write(
            body: body,
            extraParts: [("word/header1.xml", header), ("word/footer1.xml", footer)],
            to: workDir.appendingPathComponent("agreement.docx")
        )
    }

    private func anonymize(_ input: URL) throws -> AnonymizeResult {
        try LDAService.anonymize(
            input: input,
            outputDir: workDir.appendingPathComponent("out", isDirectory: true),
            protection: .passphrase("pw"),
            createdAtISO8601: "2026-09-03T00:00:00Z"
        )
    }

    // MARK: - The headline number

    func testEntityCountCountsBodyAndSupplementaryReplacements() throws {
        let result = try anonymize(try writeAgreement())

        XCTAssertEqual(
            result.entities.count, Self.bodySiteCount,
            "entities stays body only: supplementary entities carry no body offsets"
        )
        XCTAssertEqual(
            result.supplementaryEntityCount, Self.supplementarySiteCount,
            "header date, header email, footer phone, and the footer's reuse of the body email"
        )
        XCTAssertEqual(
            result.entityCount, Self.totalSiteCount,
            "the headline number must be everything that was replaced"
        )
        XCTAssertEqual(
            result.supplementaryCountsByType,
            [.date: 1, .email: 2, .phone: 1],
            "per-type breakdown of the supplementary half"
        )
    }

    func testACleanRoundTripRestoresExactlyEntityCountSites() throws {
        let result = try anonymize(try writeAgreement())

        let restored = workDir.appendingPathComponent("restored.docx")
        let report = try LDAService.restore(
            editedRedacted: result.redactedFileURL,
            mapping: result.mappingFileURL,
            protection: .passphrase("pw"),
            output: restored
        )
        XCTAssertTrue(report.orphanTokens.isEmpty)
        XCTAssertEqual(
            report.restoredCount, result.entityCount,
            "the reported coverage and the restored coverage must be the same number"
        )
        // And the redaction really did cover both supplementary parts.
        for part in try DocxTestPackage.allTextParts(in: result.redactedFileURL) {
            for value in [Self.headerEmail, Self.footerPhone, Self.headerDate] {
                XCTAssertFalse(part.xml.contains(value), "\(part.path) still shows \(value)")
            }
        }
    }

    // MARK: - The preview

    func testDetectSummaryPredictsWhatTheRunRedacts() throws {
        let input = try writeAgreement()

        let preview = try LDAService.detectSummary(input: input)
        let result = try anonymize(input)

        XCTAssertEqual(preview.bodySpans.count, result.entities.count)
        XCTAssertEqual(preview.supplementaryEntityCount, result.supplementaryEntityCount)
        XCTAssertEqual(preview.supplementaryCountsByType, result.supplementaryCountsByType)
        XCTAssertEqual(preview.entityCount, result.entityCount)
    }

    func testDetectStillReturnsBodySpansOnly() throws {
        let input = try writeAgreement()

        let spans = try LDAService.detect(input: input)

        XCTAssertEqual(spans.count, Self.bodySiteCount)
        let texts = spans.map(\.text)
        XCTAssertFalse(texts.contains(Self.headerEmail), "detect must keep its body offsets honest")
    }

    // MARK: - Non-DOCX input

    func testPlainTextInputReportsNoSupplementaryCoverage() throws {
        let input = workDir.appendingPathComponent("note.txt")
        try Data("Contact \(Self.sharedEmail) on \(Self.bodyDate).".utf8).write(to: input)

        let result = try anonymize(input)

        XCTAssertEqual(result.supplementaryEntityCount, 0)
        XCTAssertTrue(result.supplementaryCountsByType.isEmpty)
        XCTAssertEqual(result.entityCount, result.entities.count, "nothing changed for text input")

        let preview = try LDAService.detectSummary(input: input)
        XCTAssertEqual(preview.supplementaryEntityCount, 0)
        XCTAssertTrue(preview.supplementaryCountsByType.isEmpty)
        XCTAssertEqual(preview.entityCount, preview.bodySpans.count)
    }

    func testADocxWithNoSupplementaryPartsReportsZero() throws {
        let input = try DocxTestPackage.write(
            body: DocxTestPackage.paragraph(
                DocxTestPackage.run("Contact \(Self.sharedEmail) on \(Self.bodyDate).")
            ),
            to: workDir.appendingPathComponent("plain.docx")
        )

        let result = try anonymize(input)

        XCTAssertEqual(result.supplementaryEntityCount, 0)
        XCTAssertEqual(result.entityCount, result.entities.count)
    }
}
