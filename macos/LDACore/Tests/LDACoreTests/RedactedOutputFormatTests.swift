//
//  RedactedOutputFormatTests.swift
//  LDACoreTests
//
//  The format a redacted document is written in (RedactedOutputFormat),
//  through RedactedOutputWriter and LDAService.anonymize:
//  - Markdown renders the redacted text as Export for AI does, for every
//    source type, and restores.
//  - The original format keeps a Word document's paragraph, run-property,
//    table and section structure with every replaced value gone from every
//    package part; keeps a text file's extension and lines; re-renders a PDF
//    with the same pages and sizes and no text left to extract; boxes an
//    image in its own type with no metadata but its layout; and refuses a
//    PDF or image it cannot fully cover.
//  - The edit surfaces `lda anonymize` and MCP read back stay as they were.
//
//  Deterministic detection only, except one image test that runs Vision OCR
//  on a planted fixture. No model, no Keychain.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import CoreGraphics
import ImageIO
import PDFKit
import XCTest
@testable import LDACore

final class RedactedOutputFormatTests: XCTestCase {

    private var workDir: URL!

    private static let createdAt = "2026-11-11T00:00:00Z"
    private static let passphrase = "format-test-passphrase"

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RedactedOutputFormatTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
        workDir = nil
        try super.tearDownWithError()
    }

    // MARK: - Values the deterministic engine finds

    private static let phoneA = "13812345678"
    private static let phoneB = "13912345678"
    private static let email = "zhangsan@example.com"
    private static let nationalID = "33010619900101123X"
    private static let isoDate = "2026-04-30"
    private static let values = [phoneA, phoneB, email, nationalID, isoDate]

    private func anonymize(_ input: URL, format: RedactedOutputFormat?, into folder: String = "out") throws -> AnonymizeResult {
        try LDAService.anonymize(
            input: input,
            outputDir: workDir.appendingPathComponent(folder, isDirectory: true),
            protection: .passphrase(Self.passphrase),
            createdAtISO8601: Self.createdAt,
            format: format
        )
    }

    private func restore(_ redacted: URL, mapping: URL, to name: String) throws -> URL {
        let output = workDir.appendingPathComponent(name)
        _ = try LDAService.restore(
            editedRedacted: redacted,
            mapping: mapping,
            protection: .passphrase(Self.passphrase),
            output: output
        )
        return output
    }

    private func token(for value: String, in mappingURL: URL) throws -> String {
        let mapping = try MappingStore.load(from: mappingURL, protection: .passphrase(Self.passphrase))
        return try XCTUnwrap(mapping.entries.values.first { $0.value == value }?.token, "no token for \(value)")
    }

    // MARK: - Word fixture

    private static let fontRun =
        "<w:rFonts w:ascii=\"Georgia\" w:hAnsi=\"Georgia\"/><w:color w:val=\"1F3864\"/><w:sz w:val=\"28\"/>"
    private static let listProperties =
        "<w:pStyle w:val=\"ListNumber\"/><w:numPr><w:ilvl w:val=\"0\"/><w:numId w:val=\"1\"/></w:numPr>"

    private static func cell(_ runs: String...) -> String {
        "<w:tc><w:tcPr><w:tcW w:w=\"4500\" w:type=\"dxa\"/></w:tcPr>" + DocxTestPackage.paragraph(runs: runs) + "</w:tc>"
    }

    private static let table = "<w:tbl><w:tblPr><w:tblStyle w:val=\"TableGrid\"/><w:tblW w:w=\"0\" w:type=\"auto\"/></w:tblPr>"
        + "<w:tblGrid><w:gridCol w:w=\"4500\"/><w:gridCol w:w=\"4500\"/></w:tblGrid>"
        + "<w:tr>" + cell(DocxTestPackage.run("Contact", rPr: "<w:b/>"))
        + cell(DocxTestPackage.run("Phone \(phoneA)")) + "</w:tr>"
        + "<w:tr>" + cell(DocxTestPackage.run("Identity card"))
        + cell(DocxTestPackage.run(nationalID, rPr: "<w:i/>")) + "</w:tr>"
        + "</w:tbl>"

    private static let wordBody = DocxTestPackage.paragraph(
            DocxTestPackage.run("Services Agreement"),
            pPr: "<w:pStyle w:val=\"Heading1\"/>"
        )
        + DocxTestPackage.paragraph(
            DocxTestPackage.run("Contractor phone ", preserve: true),
            DocxTestPackage.run(phoneA, rPr: fontRun),
            DocxTestPackage.run(", email ", preserve: true),
            DocxTestPackage.run("zhang", rPr: "<w:b/>"),
            DocxTestPackage.run("san@example.com and post.", rPr: "<w:i/>"),
            "<w:r><w:rPr><w:rStyle w:val=\"FootnoteReference\"/></w:rPr><w:footnoteReference w:id=\"1\"/></w:r>"
        )
        + DocxTestPackage.paragraph(DocxTestPackage.run("Payment is due by \(isoDate)."), pPr: listProperties)
        + DocxTestPackage.paragraph(DocxTestPackage.run("Either party may end this agreement on notice."), pPr: listProperties)
        + table
        + DocxTestPackage.sectionWithHeaderAndFooter

    private static let headerXML = DocxTestPackage.wordPart(
        rootTag: "hdr",
        body: DocxTestPackage.paragraph(
            DocxTestPackage.run("Confidential", rPr: "<w:b/>"),
            DocxTestPackage.run(" contact \(phoneB)", preserve: true),
            pPr: "<w:jc w:val=\"right\"/>"
        )
    )

    private static let footerXML = DocxTestPackage.wordPart(
        rootTag: "ftr",
        body: DocxTestPackage.paragraph(
            DocxTestPackage.run("Page 1. Write to \(email)"),
            pPr: "<w:jc w:val=\"center\"/>"
        )
    )

    private static let footnotesXML = DocxTestPackage.wordPart(
        rootTag: "footnotes",
        body: "<w:footnote w:type=\"separator\" w:id=\"-1\"><w:p><w:r><w:separator/></w:r></w:p></w:footnote>"
            + "<w:footnote w:type=\"continuationSeparator\" w:id=\"0\"><w:p><w:r><w:continuationSeparator/></w:r></w:p></w:footnote>"
            + "<w:footnote w:id=\"1\">"
            + DocxTestPackage.paragraph(
                "<w:r><w:rPr><w:rStyle w:val=\"FootnoteReference\"/></w:rPr><w:footnoteRef/></w:r>",
                DocxTestPackage.run(" The contractor also answers on \(phoneB).", preserve: true),
                pPr: "<w:pStyle w:val=\"FootnoteText\"/>"
            )
            + "</w:footnote>"
    )

    private static let stylesXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:styles xmlns:w="\(DocxTestPackage.wordNamespace)">
    <w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Times New Roman" w:hAnsi="Times New Roman"/><w:sz w:val="24"/></w:rPr></w:rPrDefault></w:docDefaults>
    <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/></w:style>
    <w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/><w:rPr><w:b/><w:sz w:val="32"/></w:rPr></w:style>
    <w:style w:type="paragraph" w:styleId="ListNumber"><w:name w:val="List Number"/><w:basedOn w:val="Normal"/></w:style>
    <w:style w:type="paragraph" w:styleId="FootnoteText"><w:name w:val="footnote text"/><w:rPr><w:sz w:val="18"/></w:rPr></w:style>
    <w:style w:type="character" w:styleId="FootnoteReference"><w:name w:val="footnote reference"/><w:rPr><w:vertAlign w:val="superscript"/></w:rPr></w:style>
    <w:style w:type="table" w:styleId="TableGrid"><w:name w:val="Table Grid"/></w:style>
    </w:styles>
    """

    private static let numberingXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:numbering xmlns:w="\(DocxTestPackage.wordNamespace)">
    <w:abstractNum w:abstractNumId="0"><w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="decimal"/><w:lvlText w:val="%1."/></w:lvl></w:abstractNum>
    <w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>
    </w:numbering>
    """

    private func writeAgreement() throws -> URL {
        try DocxTestPackage.write(
            body: Self.wordBody,
            extraParts: [
                ("word/styles.xml", Self.stylesXML),
                ("word/numbering.xml", Self.numberingXML),
                ("word/header1.xml", Self.headerXML),
                ("word/footer1.xml", Self.footerXML),
                ("word/footnotes.xml", Self.footnotesXML)
            ],
            to: workDir.appendingPathComponent("agreement.docx")
        )
    }

    // MARK: - Markup helpers

    /// Every match of `pattern` in `xml`, in document order.
    private func matches(_ pattern: String, in xml: String) throws -> [String] {
        let regex = try NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
        let ns = xml as NSString
        return regex.matches(in: xml, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }

    /// The structure a redaction must not change: element counts, every
    /// paragraph, run, table and cell property in order, and the sections.
    private func structure(of xml: String) throws -> [String: [String]] {
        [
            "paragraphs": [String(try matches("<w:p[ >]", in: xml).count)],
            "runs": [String(try matches("<w:r[ >]", in: xml).count)],
            "tables": [String(try matches("<w:tbl>", in: xml).count)],
            "rows": [String(try matches("<w:tr[ >]", in: xml).count)],
            "cells": [String(try matches("<w:tc[ >]", in: xml).count)],
            "paragraphProperties": try matches("<w:pPr>.*?</w:pPr>", in: xml),
            "runProperties": try matches("<w:rPr>.*?</w:rPr>", in: xml),
            "tableProperties": try matches("<w:(tblPr|tblGrid|tcPr)>.*?</w:\\1>", in: xml),
            "sections": try matches("<w:sectPr>.*?</w:sectPr>", in: xml),
            "notes": try matches("<w:(footnoteReference|footnoteRef|separator|continuationSeparator)[^>]*/>", in: xml)
        ]
    }

    // MARK: - Word, original format

    func testWordInTheOriginalFormatKeepsItsStructureAndNoValueSurvivesAnywhere() throws {
        let original = try writeAgreement()

        // The probes below must see a real document, or equal shapes and
        // absent values would prove nothing.
        let sourceMembers = try DocxTestPackage.allMembers(in: original)
        for value in Self.values {
            XCTAssertTrue(
                sourceMembers.contains { OutputFormatFixtures.contains($0.data, value) },
                "the fixture must carry \(value)"
            )
        }
        let sourceShape = try structure(of: try DocxTestPackage.readPart("word/document.xml", from: original))
        XCTAssertEqual(sourceShape["tables"], ["1"])
        XCTAssertEqual(sourceShape["rows"], ["2"])
        XCTAssertEqual(sourceShape["cells"], ["4"])
        XCTAssertEqual(sourceShape["sections"]?.count, 1)
        XCTAssertGreaterThanOrEqual(sourceShape["runProperties"]?.count ?? 0, 6)
        XCTAssertEqual(sourceShape["notes"]?.count, 1, "the body references its footnote")
        let notesShape = try structure(of: try DocxTestPackage.readPart("word/footnotes.xml", from: original))
        XCTAssertEqual(notesShape["notes"]?.count, 3, "separator, continuation separator and the note's mark")

        let result = try anonymize(original, format: .original)

        XCTAssertEqual(result.redactedFileURL.lastPathComponent, "agreement_redacted.docx")
        XCTAssertEqual(result.mappingFileURL.lastPathComponent, "agreement_redacted.ldamap")
        XCTAssertGreaterThan(result.supplementaryEntityCount, 0, "the header, footer and footnote are redacted too")

        // No replaced value in any package member, whatever it is called.
        for member in try DocxTestPackage.allMembers(in: result.redactedFileURL) {
            for value in Self.values {
                XCTAssertFalse(OutputFormatFixtures.contains(member.data, value), "\(member.path) still holds \(value)")
            }
        }

        // The same paragraphs, runs, tables, sections and notes in every part.
        for part in ["word/document.xml", "word/header1.xml", "word/footer1.xml", "word/footnotes.xml"] {
            let before = try DocxTestPackage.readPart(part, from: original)
            let after = try DocxTestPackage.readPart(part, from: result.redactedFileURL)
            XCTAssertEqual(try structure(of: after), try structure(of: before), "\(part) changed shape")
        }
        XCTAssertEqual(try DocxTestPackage.readPart("word/styles.xml", from: result.redactedFileURL), Self.stylesXML)
        XCTAssertEqual(try DocxTestPackage.readPart("word/numbering.xml", from: result.redactedFileURL), Self.numberingXML)

        // Each placeholder takes the formatting of the text it replaced; a
        // value split across runs takes its first run's.
        let body = try DocxTestPackage.readPart("word/document.xml", from: result.redactedFileURL)
        let phoneToken = try token(for: Self.phoneA, in: result.mappingFileURL)
        let emailToken = try token(for: Self.email, in: result.mappingFileURL)
        let idToken = try token(for: Self.nationalID, in: result.mappingFileURL)
        XCTAssertTrue(body.contains("<w:rPr>\(Self.fontRun)</w:rPr><w:t>\(phoneToken)</w:t>"), body)
        XCTAssertTrue(body.contains("<w:rPr><w:b/></w:rPr><w:t>\(emailToken)</w:t>"), body)
        XCTAssertTrue(body.contains("<w:rPr><w:i/></w:rPr><w:t xml:space=\"preserve\"> and post.</w:t>")
            || body.contains("<w:rPr><w:i/></w:rPr><w:t> and post.</w:t>"), body)
        XCTAssertTrue(body.contains("<w:rPr><w:i/></w:rPr><w:t>\(idToken)</w:t>"), body)

        // And it restores to the original text in every part.
        let restored = try restore(result.redactedFileURL, mapping: result.mappingFileURL, to: "restored.docx")
        XCTAssertEqual(try DocxParts.restoreReportText(from: restored), try DocxParts.restoreReportText(from: original))
    }

    // MARK: - Word, Markdown

    func testWordAsMarkdownIsTheBodyAsExportForAIRendersItAndRestores() throws {
        let original = try writeAgreement()
        let result = try anonymize(original, format: .markdown)

        XCTAssertEqual(result.redactedFileURL.lastPathComponent, "agreement_redacted.md")
        XCTAssertEqual(result.mappingFileURL.lastPathComponent, "agreement_redacted.ldamap")
        XCTAssertNil(result.visualPdfURL)
        XCTAssertNil(result.redactedImageURL)
        XCTAssertEqual(result.embeddedMediaCount, 0)
        XCTAssertEqual(result.supplementaryEntityCount, 0, "Markdown carries the body only")

        let markdown = try String(contentsOf: result.redactedFileURL, encoding: .utf8)
        XCTAssertTrue(markdown.hasPrefix(MarkdownHandoffWriter.tokenStylePreamble + "\n\n"), markdown)
        for value in Self.values {
            XCTAssertFalse(markdown.contains(value), "the Markdown still holds \(value)")
        }
        XCTAssertFalse(markdown.contains("Confidential"), "headers are not part of the body")

        let body = try DocxImporter().importDocument(original).text
        let restored = try restore(result.redactedFileURL, mapping: result.mappingFileURL, to: "restored.md")
        XCTAssertEqual(
            try String(contentsOf: restored, encoding: .utf8),
            MarkdownHandoffWriter.tokenStylePreamble + "\n\n" + body
        )
    }

    func testMarkdownInAnotherStyleCarriesNoPreamble() throws {
        let note = workDir.appendingPathComponent("note.txt")
        try Data("Call \(Self.phoneA) today.".utf8).write(to: note)
        let result = try LDAService.anonymize(
            input: note,
            outputDir: workDir.appendingPathComponent("out", isDirectory: true),
            protection: .passphrase(Self.passphrase),
            createdAtISO8601: Self.createdAt,
            style: .asterisk,
            format: .markdown
        )
        let markdown = try String(contentsOf: result.redactedFileURL, encoding: .utf8)
        XCTAssertFalse(markdown.contains(MarkdownHandoffWriter.tokenStylePreamble), markdown)
        XCTAssertFalse(markdown.contains(Self.phoneA), markdown)
    }

    // MARK: - PDF

    private func writeLeasePDF(rotated: Bool = false) throws -> URL {
        try OutputFormatFixtures.writePDF(
            [
                .init(size: OutputFormatFixtures.letter, lines: [
                    "RESIDENTIAL LEASE",
                    "Tenant phone: \(Self.phoneA)",
                    "Tenant email: \(Self.email)",
                    "Identity card: \(Self.nationalID)"
                ]),
                .init(size: OutputFormatFixtures.a4, lines: [
                    "Rent is due on \(Self.isoDate).",
                    "Questions go to \(Self.email)."
                ]),
                .init(size: OutputFormatFixtures.letter, lines: ["Signed for the tenant, phone \(Self.phoneA)."])
            ],
            metadataValue: Self.email,
            rotatedPageIndex: rotated ? 2 : nil,
            to: workDir.appendingPathComponent("lease.pdf")
        )
    }

    func testPDFInTheOriginalFormatYieldsNoValueAndKeepsEveryPage() throws {
        let source = try writeLeasePDF(rotated: true)
        let sourceDocument = try XCTUnwrap(PDFDocument(url: source))
        let sourceText = try XCTUnwrap(sourceDocument.string)
        for value in [Self.phoneA, Self.email, Self.nationalID, Self.isoDate] {
            XCTAssertTrue(sourceText.contains(value), "the fixture must carry \(value)")
        }

        let result = try anonymize(source, format: .original)
        // The restorable text is the redacted file, the boxed PDF beside it.
        XCTAssertEqual(result.redactedFileURL.lastPathComponent, "lease_redacted.txt")
        let boxed = try XCTUnwrap(result.visualPdfURL)
        XCTAssertEqual(boxed.lastPathComponent, "lease_redacted.pdf")
        XCTAssertEqual(result.unboxedTokenCount, 0)
        let companion = result.redactedFileURL

        let output = try XCTUnwrap(PDFDocument(url: boxed))
        XCTAssertEqual(output.pageCount, sourceDocument.pageCount)
        for index in 0..<sourceDocument.pageCount {
            let sourcePage = try XCTUnwrap(sourceDocument.page(at: index))
            let outputPage = try XCTUnwrap(output.page(at: index))
            XCTAssertEqual(
                PdfPageGeometry.displaySize(of: outputPage),
                PdfPageGeometry.displaySize(of: sourcePage),
                "page \(index + 1) keeps its size as it is seen"
            )
            XCTAssertEqual(outputPage.string ?? "", "", "page \(index + 1) has no text layer left to extract")
        }

        // Nothing replaced can be extracted, searched or read from the bytes
        // or the document information.
        let extracted = output.string ?? ""
        for value in Self.values {
            XCTAssertFalse(extracted.contains(value), "extraction yields \(value)")
            XCTAssertTrue(output.findString(value, withOptions: [.caseInsensitive]).isEmpty, "findString finds \(value)")
            XCTAssertFalse(
                OutputFormatFixtures.contains(try Data(contentsOf: boxed), value),
                "the file's bytes hold \(value)"
            )
        }
        for (key, attribute) in output.documentAttributes ?? [:] {
            XCTAssertFalse(String(describing: attribute).contains(Self.email), "document attribute \(key) leaks")
        }

        // The mapping restores the text an AI would answer from.
        let restored = try restore(companion, mapping: result.mappingFileURL, to: "restored.txt")
        let importedSource = try LDAService.localReviewText(input: source)
        XCTAssertEqual(try String(contentsOf: restored, encoding: .utf8), importedSource)
    }

    func testPDFAsMarkdownIsItsRedactedTextAndRestores() throws {
        let source = try writeLeasePDF()
        let result = try anonymize(source, format: .markdown)

        XCTAssertEqual(result.redactedFileURL.lastPathComponent, "lease_redacted.md")
        XCTAssertNil(result.visualPdfURL, "Markdown writes no review copy")
        let folder = result.redactedFileURL.deletingLastPathComponent()
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted(),
            ["lease_redacted.ldamap", "lease_redacted.md"]
        )
        let markdown = try String(contentsOf: result.redactedFileURL, encoding: .utf8)
        for value in Self.values {
            XCTAssertFalse(markdown.contains(value), "the Markdown still holds \(value)")
        }
        let restored = try restore(result.redactedFileURL, mapping: result.mappingFileURL, to: "restored.md")
        XCTAssertEqual(
            try String(contentsOf: restored, encoding: .utf8),
            MarkdownHandoffWriter.tokenStylePreamble + "\n\n" + (try LDAService.localReviewText(input: source))
        )
    }

    func testThePDFEditSurfacesStayAsTheyWere() throws {
        let source = try writeLeasePDF()
        let result = try anonymize(source, format: nil)

        XCTAssertEqual(result.redactedFileURL.lastPathComponent, "lease_redacted.txt")
        XCTAssertEqual(result.visualPdfURL?.lastPathComponent, "lease_review.pdf")
        XCTAssertEqual(result.mappingFileURL.lastPathComponent, "lease_redacted.ldamap")
    }

    /// A value the page geometry cannot place: the text replaced it once, and
    /// the PDF does not show it anywhere its text layer can be searched, so
    /// that site has no box (counted per site since review F6).
    private func uncoverableDocument(source: URL) -> RedactedOutputWriter.Document {
        let text = "Reach Zelda at zelda.quux@example.org today."
        let span = OutputFormatFixtures.span(in: text, "zelda.quux@example.org", .email)
        let tokenized = Tokenizer.tokenize(
            text: text,
            spans: [span],
            sourceFile: source.lastPathComponent,
            createdAtISO8601: Self.createdAt
        )
        let replacements = tokenized.mapping.entries.values.map { Replacement(span: span, token: $0.token) }
        return RedactedOutputWriter.Document(
            source: source,
            imported: nil,
            tokenizedText: tokenized.tokenizedText,
            mapping: tokenized.mapping,
            spans: [span],
            replacements: replacements,
            style: .token,
            imageLines: [],
            includeSealCandidates: false,
            detectWordParts: { _ in [] },
            detectImageText: { _ in [] }
        )
    }

    func testAPDFThatWouldStillShowAValueIsRefusedInTheOriginalFormatOnly() throws {
        let source = try writeLeasePDF()
        let folder = workDir.appendingPathComponent("refused", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        XCTAssertThrowsError(
            try RedactedOutputWriter.write(
                uncoverableDocument(source: source),
                layout: .chosen(.original),
                to: folder,
                baseName: "lease_redacted"
            )
        ) { error in
            XCTAssertEqual(error as? RedactedOutputError, .valuesNotCovered(count: 1))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [], "nothing is written")

        // The edit surfaces count it instead: there the .txt is what travels.
        let written = try RedactedOutputWriter.write(
            uncoverableDocument(source: source),
            layout: .editSurfaces,
            to: folder,
            baseName: "lease_redacted"
        )
        XCTAssertEqual(written.unboxedOccurrenceCount, 1)
        XCTAssertEqual(written.boxedPDFURL?.lastPathComponent, "lease_review.pdf")
    }

    /// A PDF is reprinted whole, so one that reads differently from the text
    /// its caller reviewed (a page that review never read) is refused before
    /// anything is written, in every layout.
    func testAPDFThatReadsDifferentlyFromItsReviewIsNotReprinted() throws {
        let source = try writeLeasePDF()
        let folder = workDir.appendingPathComponent("refused", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let reviewed = try LDAService.localReviewText(input: source)

        var document = uncoverableDocument(source: source)
        document.reviewedText = reviewed + "\n\nA page this review never read."
        XCTAssertThrowsError(
            try RedactedOutputWriter.write(document, layout: .chosen(.original), to: folder, baseName: "lease_redacted")
        ) { error in
            XCTAssertEqual(error as? RedactedOutputError, .sourceNotReviewed)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [], "nothing is written")
    }

    /// The batch reads a mixed PDF's scanned page with OCR, so its values are
    /// detected and boxed there too. This runs Vision OCR on a planted page.
    func testTheBatchBoxesTheScannedPageOfAMixedPDF() throws {
        let scannedEmail = "quill.mere@example.org"
        let source = try OutputFormatFixtures.writeHybridPDF(
            typedLines: ["Tenant email \(Self.email)"],
            scannedLines: ["Contact \(scannedEmail)"],
            to: workDir.appendingPathComponent("mixed.pdf")
        )
        try XCTSkipUnless(
            (try LDAService.localReviewText(input: source)).contains(scannedEmail),
            "fixture: OCR must read the scanned page"
        )

        let result = try anonymize(source, format: .original)
        let boxed = try XCTUnwrap(result.visualPdfURL)
        let readBack = try PdfOCRImporter().importDocument(boxed).text
        XCTAssertFalse(readBack.contains(scannedEmail), "the scanned page's value is boxed: \(readBack)")
        XCTAssertFalse(readBack.contains(Self.email), "the typed page's value is boxed: \(readBack)")
    }

    /// A seeded session mapping holds other documents' values. A PDF boxes
    /// only the values this document replaced: boxing one it left in clear
    /// would label it with a placeholder its redacted text never wrote.
    func testAPDFBoxesOnlyTheValuesThisDocumentReplaced() throws {
        let source = try writeLeasePDF()
        let imported = try LDAService.importDocument(source, extension: "pdf")
        let seedText = "Seed: \(Self.phoneA) and \(Self.email)."
        let tokenized = Tokenizer.tokenize(
            text: seedText,
            spans: [
                OutputFormatFixtures.span(in: seedText, Self.phoneA, .phone),
                OutputFormatFixtures.span(in: seedText, Self.email, .email)
            ],
            sourceFile: "another.txt",
            createdAtISO8601: Self.createdAt
        )
        let emailToken = try XCTUnwrap(tokenized.mapping.entries.values.first { $0.value == Self.email }?.token)
        let phoneToken = try XCTUnwrap(tokenized.mapping.entries.values.first { $0.value == Self.phoneA }?.token)

        // This document replaced the email only; the phone stays in clear.
        let surface = PdfReviewSurface.locate(
            in: source,
            imported: imported,
            mapping: tokenized.mapping,
            sitesByToken: [emailToken: 2],
            detect: { _ in [] }
        )
        let tokens = Set(surface.boxes.map(\.token))
        XCTAssertTrue(tokens.contains(emailToken))
        XCTAssertFalse(tokens.contains(phoneToken), "a value this document left in clear gets no placeholder box")
        XCTAssertEqual(surface.unboxedOccurrenceCount, 0)
    }

    // MARK: - Text

    func testTextInTheOriginalFormatKeepsItsExtensionAndLines() throws {
        let lines = [
            "# Call notes",
            "",
            "- Phone: \(Self.phoneA)",
            "- Email: \(Self.email)",
            "",
            "Next call on \(Self.isoDate)."
        ]
        let source = workDir.appendingPathComponent("notes.md")
        try Data(lines.joined(separator: "\n").utf8).write(to: source)

        let result = try anonymize(source, format: .original)
        XCTAssertEqual(result.redactedFileURL.lastPathComponent, "notes_redacted.md")
        let redactedLines = try String(contentsOf: result.redactedFileURL, encoding: .utf8)
            .components(separatedBy: "\n")
        XCTAssertEqual(redactedLines.count, lines.count)
        XCTAssertEqual(redactedLines[0], lines[0])
        XCTAssertEqual(redactedLines[1], "")
        XCTAssertTrue(redactedLines[2].hasPrefix("- Phone: {"), redactedLines[2])
        for value in Self.values {
            XCTAssertFalse(redactedLines.joined().contains(value))
        }
        let restored = try restore(result.redactedFileURL, mapping: result.mappingFileURL, to: "restored.md")
        XCTAssertEqual(try String(contentsOf: restored, encoding: .utf8), lines.joined(separator: "\n"))

        // The edit surfaces keep writing .txt for it, as they always did.
        let legacy = try anonymize(source, format: nil, into: "legacy")
        XCTAssertEqual(legacy.redactedFileURL.lastPathComponent, "notes_redacted.txt")
    }

    func testPlainTextAsMarkdownGetsTheMarkdownExtension() throws {
        let source = workDir.appendingPathComponent("memo.txt")
        try Data("To: \(Self.email)\nCall \(Self.phoneA).".utf8).write(to: source)
        let result = try anonymize(source, format: .markdown)
        XCTAssertEqual(result.redactedFileURL.lastPathComponent, "memo_redacted.md")
        let restored = try restore(result.redactedFileURL, mapping: result.mappingFileURL, to: "restored.md")
        XCTAssertEqual(
            try String(contentsOf: restored, encoding: .utf8),
            MarkdownHandoffWriter.tokenStylePreamble + "\n\nTo: \(Self.email)\nCall \(Self.phoneA)."
        )
    }

    // MARK: - Images

    /// One OCR line over the band the fixture leaves for text, holding the
    /// phone number at offsets 6..<17 of "Phone 13812345678".
    private static let imageText = "Phone \(phoneA)"
    private static let imageLine = ImageTextLine(
        text: imageText,
        normalizedBox: CGRect(x: 0.10, y: 0.40, width: 0.60, height: 0.20),
        range: 0..<17
    )

    private func imageDocument(source: URL, lines: [ImageTextLine]) -> RedactedOutputWriter.Document {
        let span = OutputFormatFixtures.span(in: Self.imageText, Self.phoneA, .phone)
        let tokenized = Tokenizer.tokenize(
            text: Self.imageText,
            spans: [span],
            sourceFile: source.lastPathComponent,
            createdAtISO8601: Self.createdAt
        )
        return RedactedOutputWriter.Document(
            source: source,
            imported: nil,
            tokenizedText: tokenized.tokenizedText,
            mapping: tokenized.mapping,
            spans: [span],
            replacements: [],
            style: .token,
            imageLines: lines,
            includeSealCandidates: false,
            detectWordParts: { _ in [] },
            detectImageText: { _ in [] }
        )
    }

    func testAJPEGInTheOriginalFormatStaysAJPEGWithItsLayoutAndNoOtherMetadata() throws {
        let source = try OutputFormatFixtures.writeImage(
            typeIdentifier: "public.jpeg",
            to: workDir.appendingPathComponent("exhibit.jpg")
        )
        let folder = workDir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let written = try RedactedOutputWriter.write(
            imageDocument(source: source, lines: [Self.imageLine]),
            layout: .chosen(.original),
            to: folder,
            baseName: "exhibit_redacted"
        )

        let image = try XCTUnwrap(written.boxedImageURL)
        XCTAssertEqual(image.lastPathComponent, "exhibit_redacted.jpg")
        XCTAssertEqual(written.redactedURL.lastPathComponent, "exhibit_redacted.txt", "the text is what restores")
        XCTAssertEqual(OutputFormatFixtures.imageType(image), "public.jpeg")

        let properties = try OutputFormatFixtures.imageProperties(image)
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 800)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 200)
        XCTAssertEqual(properties[kCGImagePropertyOrientation] as? Int, 6, "it displays turned as the source does")
        XCTAssertEqual((properties[kCGImagePropertyDPIWidth] as? NSNumber)?.intValue, 300, "it prints at the source's size")
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        XCTAssertNil(tiff[kCGImagePropertyTIFFArtist])
        XCTAssertNil(tiff[kCGImagePropertyTIFFMake])
        XCTAssertNil(tiff[kCGImagePropertyTIFFModel])
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        XCTAssertNil(exif[kCGImagePropertyExifUserComment])
        XCTAssertNil(exif[kCGImagePropertyExifDateTimeOriginal])
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary], "no location travels")
        XCTAssertFalse(
            OutputFormatFixtures.contains(try Data(contentsOf: image), OutputFormatFixtures.identifyingValue)
        )

        // The line's box is painted over, in the source's pixel space.
        XCTAssertLessThan(try OutputFormatFixtures.luminance(of: image, x: 400, y: 100), 40)
        XCTAssertGreaterThan(try OutputFormatFixtures.luminance(of: image, x: 400, y: 10), 200)
    }

    func testAPNGStaysAPNGAndAJPEGNamedJpegKeepsItsName() throws {
        let png = try OutputFormatFixtures.writeImage(
            typeIdentifier: "public.png",
            to: workDir.appendingPathComponent("scan.png")
        )
        let jpeg = try OutputFormatFixtures.writeImage(
            typeIdentifier: "public.jpeg",
            to: workDir.appendingPathComponent("photo.jpeg")
        )
        let folder = workDir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let writtenPNG = try RedactedOutputWriter.write(
            imageDocument(source: png, lines: [Self.imageLine]),
            layout: .chosen(.original),
            to: folder,
            baseName: "scan_redacted"
        )
        let boxedPNG = try XCTUnwrap(writtenPNG.boxedImageURL)
        XCTAssertEqual(boxedPNG.lastPathComponent, "scan_redacted.png")
        XCTAssertEqual(OutputFormatFixtures.imageType(boxedPNG), "public.png")
        XCTAssertNil(try OutputFormatFixtures.imageProperties(boxedPNG)[kCGImagePropertyGPSDictionary])

        let writtenJPEG = try RedactedOutputWriter.write(
            imageDocument(source: jpeg, lines: [Self.imageLine]),
            layout: .chosen(.original),
            to: folder,
            baseName: "photo_redacted"
        )
        XCTAssertEqual(writtenJPEG.boxedImageURL?.lastPathComponent, "photo_redacted.jpeg")
    }

    func testAnImageThatWouldStillShowAValueIsRefusedBeforeAnythingIsWritten() throws {
        let source = try OutputFormatFixtures.writeImage(
            typeIdentifier: "public.png",
            to: workDir.appendingPathComponent("scan.png")
        )
        let folder = workDir.appendingPathComponent("refused", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        XCTAssertThrowsError(
            try RedactedOutputWriter.write(
                imageDocument(source: source, lines: []),
                layout: .chosen(.original),
                to: folder,
                baseName: "scan_redacted"
            )
        ) { error in
            XCTAssertEqual(error as? RedactedOutputError, .valuesNotCovered(count: 1))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
    }

    /// Ranges the image geometry cannot box are counted, never dropped, in
    /// the edit surfaces: there the .txt is what travels and the PNG warns.
    func testTheImageEditSurfacesCountAValueNoLineHolds() throws {
        let source = try OutputFormatFixtures.writeImage(
            typeIdentifier: "public.png",
            to: workDir.appendingPathComponent("scan.png")
        )
        let folder = workDir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let written = try RedactedOutputWriter.write(
            imageDocument(source: source, lines: []),
            layout: .editSurfaces,
            to: folder,
            baseName: "scan_redacted"
        )
        XCTAssertEqual(written.unboxedOccurrenceCount, 1)
        XCTAssertEqual(written.boxedImageURL?.lastPathComponent, "scan_redacted.png")
    }

    func testTheImageEditSurfacesStayATextAndAPNGWithNoProperties() throws {
        let source = try OutputFormatFixtures.writeImage(
            typeIdentifier: "public.jpeg",
            to: workDir.appendingPathComponent("exhibit.jpg")
        )
        let folder = workDir.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let written = try RedactedOutputWriter.write(
            imageDocument(source: source, lines: [Self.imageLine]),
            layout: .editSurfaces,
            to: folder,
            baseName: "exhibit_redacted"
        )
        XCTAssertEqual(written.redactedURL.lastPathComponent, "exhibit_redacted.txt")
        XCTAssertEqual(written.boxedImageURL?.lastPathComponent, "exhibit_redacted.png")
        let properties = try OutputFormatFixtures.imageProperties(try XCTUnwrap(written.boxedImageURL))
        XCTAssertNil(properties[kCGImagePropertyOrientation])
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
    }

    /// The service reads the image once and hands the writer its lines; this
    /// runs real Vision OCR on a planted line to prove that wiring.
    func testTheServiceWritesAnImageInItsOwnTypeFromItsOwnOCR() throws {
        let fixture = try ImageFixtureRenderer.writeJPEG(lines: ["Phone \(Self.phoneA)"])
        defer { try? FileManager.default.removeItem(at: fixture) }

        let result = try anonymize(fixture, format: .original)

        let image = try XCTUnwrap(result.redactedImageURL)
        XCTAssertEqual(image.pathExtension, "jpg")
        XCTAssertEqual(OutputFormatFixtures.imageType(image), "public.jpeg")
        let companion = result.redactedFileURL
        XCTAssertEqual(companion.pathExtension, "txt", "the text is what restores")
        let text = try String(contentsOf: companion, encoding: .utf8)
        XCTAssertFalse(text.contains(Self.phoneA), text)
        XCTAssertTrue(text.contains("{PHONE_1}"), text)
        XCTAssertGreaterThan(result.imageRedactionCount, 0)
    }

    // MARK: - Names a caller probes

    func testArtifactExtensionsNameEveryFileUnderTheBaseName() {
        func url(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/\(name)") }
        let original = RedactedOutputWriter.Layout.chosen(.original)
        let markdown = RedactedOutputWriter.Layout.chosen(.markdown)
        XCTAssertEqual(RedactedOutputWriter.artifactExtensions(for: url("a.docx"), layout: original), ["docx"])
        XCTAssertEqual(RedactedOutputWriter.artifactExtensions(for: url("a.pdf"), layout: original), ["pdf", "txt"])
        XCTAssertEqual(RedactedOutputWriter.artifactExtensions(for: url("a.jpg"), layout: original), ["jpg", "txt"])
        XCTAssertEqual(RedactedOutputWriter.artifactExtensions(for: url("a.md"), layout: original), ["md"])
        XCTAssertEqual(RedactedOutputWriter.artifactExtensions(for: url("a.txt"), layout: original), ["txt"])
        XCTAssertEqual(
            RedactedOutputWriter.artifactExtensions(for: url("a.pdf"), layout: .format(.original, textCompanion: false)),
            ["pdf"]
        )
        for name in ["a.docx", "a.pdf", "a.png", "a.txt", "a.md"] {
            XCTAssertEqual(RedactedOutputWriter.artifactExtensions(for: url(name), layout: markdown), ["md"])
        }
        XCTAssertEqual(RedactedOutputWriter.artifactExtensions(for: url("a.jpg"), layout: .editSurfaces), ["txt", "png"])
        XCTAssertEqual(RedactedOutputWriter.artifactExtensions(for: url("a.md"), layout: .editSurfaces), ["txt"])

        // Whole names, with the review copy's counter following the base's.
        XCTAssertEqual(
            RedactedOutputWriter.artifactNames(for: url("a.pdf"), layout: .editSurfaces, baseName: "a_redacted_2"),
            ["a_redacted_2.txt", "a_review_2.pdf"]
        )
        XCTAssertEqual(
            RedactedOutputWriter.artifactNames(for: url("a.pdf"), layout: original, baseName: "a_redacted"),
            ["a_redacted.pdf", "a_redacted.txt"]
        )
    }

    func testTheDefaultFormatIsMarkdown() {
        XCTAssertEqual(RedactedOutputFormat.default, .markdown)
        XCTAssertEqual(RedactedOutputFormat(rawValue: "original"), .original)
    }
}
