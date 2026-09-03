//
//  CLICoverageReportingTests.swift
//  LDACoreTests
//
//  The command line's half of the supplementary coverage fix: the detect
//  subcommand must report what a run would redact in the DOCX parts outside
//  the body, and the anonymize summary must carry the same split. An older
//  summary written before the field existed must still decode.
//
//  Deterministic detection only (no GGUF model on this machine).
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACLI
@testable import LDACore

final class CLICoverageReportingTests: XCTestCase {

    private var workDir: URL!

    private static let bodyEmail = "alice@example.com"
    private static let bodyDate = "2024-01-15"
    private static let headerPhone = "13800138000"

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lda-cli-coverage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
        try super.tearDownWithError()
    }

    /// Body: an email and a date. Header: a phone the body never carries.
    private func writeAgreement() throws -> URL {
        try DocxTestPackage.write(
            body: DocxTestPackage.paragraph(
                DocxTestPackage.run("Contact \(Self.bodyEmail) on \(Self.bodyDate).")
            ) + DocxTestPackage.sectionWithHeaderAndFooter,
            extraParts: [
                (
                    "word/header1.xml",
                    DocxTestPackage.wordPart(
                        rootTag: "hdr",
                        body: DocxTestPackage.paragraph(
                            DocxTestPackage.run("Reception \(Self.headerPhone)")
                        )
                    )
                ),
                (
                    "word/footer1.xml",
                    DocxTestPackage.wordPart(
                        rootTag: "ftr",
                        body: DocxTestPackage.paragraph(DocxTestPackage.run("Page 1"))
                    )
                )
            ],
            to: workDir.appendingPathComponent("agreement.docx")
        )
    }

    // MARK: - detect

    func testDetectSummaryJSONReportsSupplementaryCoverage() throws {
        let input = try writeAgreement()

        let summary = try LDACLI.runDetectSummary(input: input)
        let json = try CLIJSON.encode(DetectSummaryJSON(summary: summary))
        let decoded = try JSONDecoder().decode(DetectSummaryJSON.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.entities.count, 2, "body: email and date")
        XCTAssertEqual(decoded.supplementaryEntityCount, 1, "header phone")
        XCTAssertEqual(decoded.supplementaryCountsByType, ["PHONE": 1])
        XCTAssertEqual(decoded.entityCount, 3, "the headline number covers both")
        // The header value itself must never reach the detect output: the
        // entities list is body only, by offsets and by content.
        XCTAssertFalse(json.contains(Self.headerPhone))
    }

    func testDetectSummaryOnPlainTextReportsNoSupplementaryCoverage() throws {
        let input = workDir.appendingPathComponent("note.txt")
        try Data("Contact \(Self.bodyEmail) on \(Self.bodyDate).".utf8).write(to: input)

        let summary = try LDACLI.runDetectSummary(input: input)
        let decoded = DetectSummaryJSON(summary: summary)

        XCTAssertEqual(decoded.supplementaryEntityCount, 0)
        XCTAssertTrue(decoded.supplementaryCountsByType.isEmpty)
        XCTAssertEqual(decoded.entityCount, decoded.entities.count)
    }

    // MARK: - anonymize summary

    func testAnonymizeSummaryJSONRoundTripsTheSupplementaryCount() throws {
        let input = try writeAgreement()

        let result = try LDAService.anonymize(
            input: input,
            outputDir: workDir.appendingPathComponent("out", isDirectory: true),
            protection: .passphrase("pw"),
            createdAtISO8601: "2026-09-03T00:00:00Z"
        )
        let summary = AnonymizeSummaryJSON(result: result)
        XCTAssertEqual(summary.entityCount, 3)
        XCTAssertEqual(summary.supplementaryEntityCount, 1)

        let json = try CLIJSON.encode(summary)
        let decoded = try JSONDecoder().decode(AnonymizeSummaryJSON.self, from: Data(json.utf8))
        XCTAssertEqual(decoded, summary)
    }

    func testAnOlderAnonymizeSummaryWithoutTheFieldStillDecodes() throws {
        let legacy = """
        {
          "redactedFileURL": "/tmp/a_redacted.docx",
          "mappingFileURL": "/tmp/a_redacted.ldamap",
          "entityCount": 19,
          "imageRedactionCount": 0,
          "embeddedMediaCount": 0,
          "unboxedTokenCount": 0
        }
        """

        let decoded = try JSONDecoder().decode(
            AnonymizeSummaryJSON.self,
            from: Data(legacy.utf8)
        )

        XCTAssertEqual(decoded.entityCount, 19)
        XCTAssertEqual(decoded.supplementaryEntityCount, 0, "absent means unknown, reported as none")
        XCTAssertEqual(decoded.trackedChangeCount, 0)
    }
}
