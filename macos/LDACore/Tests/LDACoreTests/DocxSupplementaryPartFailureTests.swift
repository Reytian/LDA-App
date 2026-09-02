//
//  DocxSupplementaryPartFailureTests.swift
//  LDACoreTests
//
//  F1: a supplementary part (header, footer, notes, comments) that cannot be
//  parsed or rewritten used to be skipped silently. DocxZip.rewrite then
//  copied the ORIGINAL part into the "redacted" package with its PII in
//  clear, and anonymize reported success. Redaction must fail instead, name
//  how many supplementary parts failed (never a path, which can itself be
//  PII), and write nothing.
//
//  House rules: all comments and strings in English. Fixture values may be
//  Chinese. No em-dash and no en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class DocxSupplementaryPartFailureTests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lda-part-failure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    private static let footerPhone = "13812345678"

    /// A footer whose w:t never closes cannot be parsed, so its phone number
    /// cannot be redacted. The whole redaction must fail before any output
    /// exists, and the error must count parts rather than name them.
    func testUnparsableFooterMakesRedactionThrowAndWriteNothing() throws {
        let brokenFooter = DocxTestPackage.wordPart(
            rootTag: "ftr",
            body: "<w:p><w:r><w:t>联系电话 \(Self.footerPhone)"
        )
        let original = try DocxTestPackage.write(
            body: DocxTestPackage.paragraph(DocxTestPackage.run("Body email jane.roe@example.com."))
                + DocxTestPackage.sectionWithHeaderAndFooter,
            extraParts: [
                ("word/header1.xml", DocxTestPackage.wordPart(rootTag: "hdr", body: "<w:p><w:r><w:t>Header</w:t></w:r></w:p>")),
                ("word/footer1.xml", brokenFooter)
            ],
            to: workDir.appendingPathComponent("broken-footer.docx")
        )
        let outputDir = workDir.appendingPathComponent("out", isDirectory: true)

        XCTAssertThrowsError(
            try LDAService.anonymize(
                input: original,
                outputDir: outputDir,
                protection: .passphrase("pw"),
                createdAtISO8601: "2026-09-02T00:00:00Z",
                llmModelPath: nil
            )
        ) { error in
            guard case DocumentIOError.corrupt(let detail) = error else {
                return XCTFail("expected DocumentIOError.corrupt, got \(error)")
            }
            XCTAssertTrue(detail.contains("1 supplementary part"), detail)
            XCTAssertFalse(detail.contains("footer1.xml"), "the message must not name a part path: \(detail)")
        }

        let written = (try? FileManager.default.contentsOfDirectory(atPath: outputDir.path)) ?? []
        XCTAssertTrue(
            written.filter { $0.hasSuffix(".docx") || $0.hasSuffix(".ldamap") }.isEmpty,
            "no redacted package or sidecar may exist after a failed redaction: \(written)"
        )
    }
}
