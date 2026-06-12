//
//  PdfImporterTests.swift
//  LDACoreTests
//
//  Hermetic tests for PdfImporter and PdfRedactor. Each test synthesizes its own
//  born-digital PDF in a temporary directory by drawing known text with CoreText
//  into a CGContext-backed PDF, so no binary fixtures are committed.
//
//  Assertions tolerate minor text-extraction whitespace differences: extracted
//  text is normalized before comparison.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
import CoreGraphics
import CoreText
import PDFKit
@testable import LDACore

final class PdfImporterTests: XCTestCase {

    // MARK: - Temp directory management

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PdfImporterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        try super.tearDownWithError()
    }

    // MARK: - PDF synthesis helper

    /// A US Letter media box used for every synthesized page.
    private static let pageBounds = CGRect(x: 0, y: 0, width: 612, height: 792)

    /// Draws each supplied line of text onto its own page of a born-digital PDF
    /// and writes it to url. Text is rendered with CoreText so PDFKit recovers a
    /// real text layer.
    private func makePDF(at url: URL, pages: [[String]]) throws {
        guard let consumer = CGDataConsumer(url: url as CFURL) else {
            throw XCTSkip("Could not create a PDF data consumer for the test fixture")
        }
        var mediaBox = Self.pageBounds
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw XCTSkip("Could not create a PDF graphics context for the test fixture")
        }

        let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let black = CGColor(colorSpace: space, components: [0, 0, 0, 1])!

        for lines in pages {
            context.beginPage(mediaBox: &mediaBox)

            var y: CGFloat = Self.pageBounds.height - 72
            for line in lines {
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: black
                ]
                let attributed = NSAttributedString(string: line, attributes: attributes)
                let ctLine = CTLineCreateWithAttributedString(attributed)
                context.textPosition = CGPoint(x: 72, y: y)
                CTLineDraw(ctLine, context)
                y -= 28
            }

            context.endPage()
        }

        context.closePDF()
    }

    /// Collapses runs of whitespace to a single space and trims so extraction
    /// whitespace quirks do not break substring checks.
    private func normalize(_ s: String) -> String {
        let collapsed = s.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        )
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - canImport

    func testCanImportAcceptsPdfExtensionCaseInsensitive() {
        let importer = PdfImporter()
        XCTAssertTrue(importer.canImport(URL(fileURLWithPath: "/tmp/a.pdf")))
        XCTAssertTrue(importer.canImport(URL(fileURLWithPath: "/tmp/a.PDF")))
        XCTAssertFalse(importer.canImport(URL(fileURLWithPath: "/tmp/a.txt")))
        XCTAssertFalse(importer.canImport(URL(fileURLWithPath: "/tmp/a.docx")))
    }

    // MARK: - Import recovers text

    func testImportRecoversKnownTextFromBornDigitalPDF() throws {
        let url = tempDir.appendingPathComponent("single.pdf")
        let line = "Jane Doe signed the agreement on January 1, 2026."
        try makePDF(at: url, pages: [[line]])

        let importer = PdfImporter()
        let imported = try importer.importDocument(url)

        XCTAssertEqual(imported.format, .pdf)
        XCTAssertEqual(imported.pageCount, 1)
        XCTAssertFalse(imported.isScanned)
        XCTAssertTrue(
            normalize(imported.text).contains(normalize(line)),
            "Expected extracted text to contain the known line. Got: \(imported.text)"
        )
    }

    func testImportConcatenatesMultiplePagesWithSeparator() throws {
        let url = tempDir.appendingPathComponent("multi.pdf")
        let pageOne = "First page secret: Alice."
        let pageTwo = "Second page secret: Bob."
        try makePDF(at: url, pages: [[pageOne], [pageTwo]])

        let importer = PdfImporter()
        let imported = try importer.importDocument(url)

        XCTAssertEqual(imported.pageCount, 2)
        XCTAssertFalse(imported.isScanned)
        let norm = normalize(imported.text)
        XCTAssertTrue(norm.contains(normalize(pageOne)), "Missing page one text. Got: \(imported.text)")
        XCTAssertTrue(norm.contains(normalize(pageTwo)), "Missing page two text. Got: \(imported.text)")
    }

    // MARK: - Scanned detection

    func testImportFlagsEmptyTextAsScanned() throws {
        let url = tempDir.appendingPathComponent("blank.pdf")
        // A page with no drawn text simulates a scanned PDF with no text layer.
        try makePDF(at: url, pages: [[]])

        let importer = PdfImporter()
        let imported = try importer.importDocument(url)

        XCTAssertEqual(imported.pageCount, 1)
        XCTAssertTrue(
            imported.isScanned,
            "A PDF with no text layer should be flagged isScanned. Text was: \(imported.text)"
        )
    }

    // MARK: - Error handling

    func testImportThrowsUnreadableForMissingFile() {
        let url = tempDir.appendingPathComponent("does-not-exist.pdf")
        let importer = PdfImporter()
        XCTAssertThrowsError(try importer.importDocument(url)) { error in
            guard case DocumentIOError.unreadable = error else {
                return XCTFail("Expected DocumentIOError.unreadable, got \(error)")
            }
        }
    }

    func testImportThrowsCorruptForNonPDFContent() throws {
        let url = tempDir.appendingPathComponent("garbage.pdf")
        try Data("this is not a pdf".utf8).write(to: url)
        let importer = PdfImporter()
        XCTAssertThrowsError(try importer.importDocument(url)) { error in
            guard case DocumentIOError.corrupt = error else {
                return XCTFail("Expected DocumentIOError.corrupt, got \(error)")
            }
        }
    }

    // MARK: - redactionBoxes

    func testRedactionBoxesProducesNonEmptyRectOnRightPage() throws {
        let url = tempDir.appendingPathComponent("boxes.pdf")
        let surface = "Confidential"
        try makePDF(at: url, pages: [["Header line"], ["The \(surface) section."]])

        let boxes = PdfImporter.redactionBoxes(
            in: url,
            surfaceTexts: [(text: surface, token: "{PERSON_1}")]
        )

        XCTAssertFalse(boxes.isEmpty, "Expected at least one redaction box for the known surface text")

        let matching = boxes.filter { $0.token == "{PERSON_1}" }
        XCTAssertFalse(matching.isEmpty, "Expected a box carrying the supplied token")

        // The surface text was drawn on page index 1.
        let onSecondPage = matching.contains { $0.pageIndex == 1 }
        XCTAssertTrue(onSecondPage, "Expected a box on the page where the text appears (index 1)")

        for box in matching {
            XCTAssertFalse(box.rect.isNull, "Box rect should not be null")
            XCTAssertGreaterThan(box.rect.width, 0, "Box rect should have positive width")
            XCTAssertGreaterThan(box.rect.height, 0, "Box rect should have positive height")
        }
    }

    func testRedactionBoxesSkipsEmptySurfaceText() throws {
        let url = tempDir.appendingPathComponent("empty-surface.pdf")
        try makePDF(at: url, pages: [["Some content here."]])

        let boxes = PdfImporter.redactionBoxes(
            in: url,
            surfaceTexts: [(text: "   ", token: "{PERSON_1}")]
        )
        XCTAssertTrue(boxes.isEmpty, "Whitespace-only surface text should yield no boxes")
    }

    func testRedactionBoxesReturnsEmptyForUnopenablePDF() {
        let url = tempDir.appendingPathComponent("missing.pdf")
        let boxes = PdfImporter.redactionBoxes(
            in: url,
            surfaceTexts: [(text: "anything", token: "{PERSON_1}")]
        )
        XCTAssertTrue(boxes.isEmpty, "An unopenable PDF should yield no boxes rather than crash")
    }

    // MARK: - PdfRedactor

    func testRenderRedactedPDFWritesAndReopensWithSamePageCount() throws {
        let url = tempDir.appendingPathComponent("source.pdf")
        let surface = "TopSecret"
        try makePDF(at: url, pages: [["Page one \(surface) marker."], ["Page two ordinary text."]])

        let boxes = PdfImporter.redactionBoxes(
            in: url,
            surfaceTexts: [(text: surface, token: "{COMPANY_1}")]
        )
        XCTAssertFalse(boxes.isEmpty, "Precondition: expected boxes to redact")

        let out = tempDir.appendingPathComponent("redacted.pdf")
        try PdfRedactor.renderRedactedPDF(original: url, boxes: boxes, to: out)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: out.path),
            "Redacted PDF should be written to disk"
        )

        guard let original = PDFDocument(url: url),
              let redacted = PDFDocument(url: out) else {
            return XCTFail("Both source and redacted PDFs should re-open")
        }
        XCTAssertEqual(
            redacted.pageCount,
            original.pageCount,
            "Redacted PDF should preserve the page count"
        )
    }

    func testRenderRedactedPDFThrowsCorruptForMissingSource() {
        let missing = tempDir.appendingPathComponent("nope.pdf")
        let out = tempDir.appendingPathComponent("out.pdf")
        XCTAssertThrowsError(
            try PdfRedactor.renderRedactedPDF(original: missing, boxes: [], to: out)
        ) { error in
            guard case DocumentIOError.corrupt = error else {
                return XCTFail("Expected DocumentIOError.corrupt, got \(error)")
            }
        }
    }

    func testRenderRedactedPDFWithNoBoxesStillWritesValidPDF() throws {
        let url = tempDir.appendingPathComponent("plain.pdf")
        try makePDF(at: url, pages: [["Nothing to redact here."]])

        let out = tempDir.appendingPathComponent("plain-redacted.pdf")
        try PdfRedactor.renderRedactedPDF(original: url, boxes: [], to: out)

        guard let redacted = PDFDocument(url: out) else {
            return XCTFail("Redacted PDF with no boxes should still be a valid PDF")
        }
        XCTAssertEqual(redacted.pageCount, 1)
    }
}
