//
//  ReviewModelExportBreakSplitTests.swift
//  LDACoreTests
//
//  The GUI export (ReviewModel.performExport) writes a .docx run by run, and
//  the paragraph newline, w:br, w:cr, and w:tab characters exist in no run.
//  LDAService.anonymize splits accepted spans at those breaks before it
//  tokenizes; the GUI path must do the same, or a span that crosses a break
//  (a model detection bridging a soft line break, or a hand-protected value)
//  is written into the wrong run and the restored text moves across the break.
//
//  The split is NOT docx-only: a .txt or .md edit surface loses a whole line
//  when a replacement swallows the newline, so every format splits, and each
//  part is typed from its own text rather than inheriting the parent's.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore
@testable import LDAUI

final class ReviewModelExportBreakSplitTests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-break-split-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    /// An accepted span that crosses a soft line break is tokenized per run,
    /// the break stays where it was, and restore reproduces the original text.
    func testDocxExportSplitsAnAcceptedSpanThatCrossesASoftLineBreak() throws {
        let phone = "13700001111"
        let date = "2026-04-01"
        let original = try DocxTestPackage.write(
            body: DocxTestPackage.paragraph(
                DocxTestPackage.run("Mobile \(phone)", trailing: "<w:br/>"),
                DocxTestPackage.run("\(date) effective", preserve: true)
            ),
            to: workDir.appendingPathComponent("Contract.docx")
        )
        let importer = DocxImporter()
        let text = try importer.importDocument(original).text
        XCTAssertEqual(text, "Mobile \(phone)\n\(date) effective")

        // The bridging span the merger produced in the probe: one PHONE
        // surface spanning the phone, the break, and the date.
        let bridging = DocxTestPackage.span(in: text, surface: "\(phone)\n\(date)", type: .phone)
        let outputDir = workDir.appendingPathComponent("out", isDirectory: true)

        let outcome = try ReviewModel.performExport(
            text: text,
            acceptedSpans: [bridging],
            source: original,
            custom: [],
            useLLM: false,
            modelPath: nil,
            outputDir: outputDir,
            passphrase: "pw",
            createdAtISO8601: "2026-09-02T00:00:00Z"
        )

        let redactedXML = try DocxTestPackage.readPart(
            docxMainPartPath,
            from: outcome.export.redactedURL
        )
        XCTAssertTrue(
            redactedXML.contains("<w:t>Mobile {PHONE_1}</w:t><w:br/></w:r>"),
            "the first part is tokenized inside its own run: \(redactedXML)"
        )
        XCTAssertTrue(
            redactedXML.contains("{DATE_1} effective</w:t>"),
            "the second part is tokenized inside the run after the break, "
                + "under its OWN type: \(redactedXML)"
        )
        XCTAssertEqual(
            try importer.importDocument(outcome.export.redactedURL).text,
            "Mobile {PHONE_1}\n{DATE_1} effective"
        )

        let restored = workDir.appendingPathComponent("restored.docx")
        let report = try LDAService.restore(
            editedRedacted: outcome.export.redactedURL,
            mapping: try XCTUnwrap(outcome.export.mappingURL),
            protection: .passphrase("pw"),
            output: restored
        )
        XCTAssertEqual(report.restoredCount, 2)
        XCTAssertEqual(try importer.importDocument(restored).text, text)
    }

    /// A text source has no runs, but it does have lines: the same bridging
    /// span is split so the newline survives the replacement, and each half
    /// carries its own type.
    func testTextExportSplitsABreakCrossingSpan() throws {
        let text = "Mobile 13700001111\n2026-04-01 effective"
        let bridging = DocxTestPackage.span(in: text, surface: "13700001111\n2026-04-01", type: .phone)
        let outputDir = workDir.appendingPathComponent("out-text", isDirectory: true)

        let outcome = try ReviewModel.performExport(
            text: text,
            acceptedSpans: [bridging],
            source: nil,
            custom: [],
            useLLM: false,
            modelPath: nil,
            outputDir: outputDir,
            passphrase: "pw",
            createdAtISO8601: "2026-09-02T00:00:00Z"
        )

        let redacted = try String(contentsOf: outcome.export.redactedURL, encoding: .utf8)
        XCTAssertEqual(redacted, "Mobile {PHONE_1}\n{DATE_1} effective")
        XCTAssertEqual(outcome.tokenBySurface.count, 2)

        // The chip lookup for the value the user reviewed (the crossing
        // surface) resolves to the first part's token, not to nothing.
        XCTAssertEqual(
            ReviewModel.chipToken(for: bridging.text, in: outcome.tokenBySurface),
            "{PHONE_1}"
        )
    }
}
