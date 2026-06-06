//
//  PdfOCRImporterTests.swift
//  LDACoreTests
//
//  Hermetic tests for PdfOCRImporter. Each test synthesizes its OWN fixtures in
//  FileManager.temporaryDirectory: it renders known high-contrast text into a
//  CGImage and writes that image into a PDF page WITHOUT any text layer, so the
//  only way to recover the words is real OCR.
//
//  Assertions are tolerant of OCR noise: we use case-insensitive substring
//  checks, never exact equality. If Vision returns no results at all in this
//  environment, the test fails LOUDLY with a clear message rather than silently
//  passing.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
import CoreGraphics
import CoreText
import ImageIO
import PDFKit
import UniformTypeIdentifiers
@testable import LDACore

final class PdfOCRImporterTests: XCTestCase {

    // The known words we render and expect to recover (case-insensitive).
    private let knownWords = ["John", "Smith", "ACME", "CORP", "2026"]

    // Files created per test, cleaned up in tearDown.
    private var createdURLs: [URL] = []

    override func tearDownWithError() throws {
        let manager = FileManager.default
        for url in createdURLs {
            try? manager.removeItem(at: url)
        }
        createdURLs.removeAll()
    }

    // MARK: - Tests

    /// The core test: an image-only PDF must round-trip through Vision OCR and
    /// yield text that contains the rendered words.
    func testImportRecoversTextFromImageOnlyPdf() throws {
        let pdfURL = try makeImageOnlyPdf(
            lines: ["John Smith ACME CORP", "2026-01-15"]
        )

        let importer = PdfOCRImporter()
        XCTAssertTrue(importer.canImport(pdfURL))

        let imported = try importer.importDocument(pdfURL)

        XCTAssertEqual(imported.format, .pdf)
        XCTAssertTrue(imported.isScanned, "Scanned PDF import must set isScanned")
        XCTAssertEqual(imported.pageCount, 1)

        let recovered = imported.text

        // Fail loudly if Vision produced nothing at all in this environment.
        XCTAssertFalse(
            recovered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "OCR returned NO text for the synthetic image-only PDF. Vision may be "
                + "unavailable in this environment, or rendering failed. This test "
                + "cannot pass without working OCR."
        )

        let haystack = recovered.lowercased()
        for word in knownWords {
            XCTAssertTrue(
                haystack.contains(word.lowercased()),
                "Recovered OCR text is missing the expected word '\(word)'. "
                    + "Recovered text was: \(recovered)"
            )
        }
    }

    /// ocrBoxes must return at least one box for a surface text that appears on
    /// the page, tagged with the caller-supplied token and a non-empty rect.
    func testOcrBoxesLocatesKnownSurfaceText() throws {
        let pdfURL = try makeImageOnlyPdf(
            lines: ["John Smith ACME CORP", "2026-01-15"]
        )

        let boxes = PdfOCRImporter.ocrBoxes(
            in: pdfURL,
            matching: [(text: "ACME", token: "{COMPANY_1}")]
        )

        XCTAssertFalse(
            boxes.isEmpty,
            "ocrBoxes returned no boxes for surface text 'ACME'. Either OCR is "
                + "unavailable here or box matching is broken."
        )

        for box in boxes {
            XCTAssertEqual(box.token, "{COMPANY_1}")
            XCTAssertEqual(box.pageIndex, 0)
            XCTAssertGreaterThan(box.rect.width, 0)
            XCTAssertGreaterThan(box.rect.height, 0)
        }
    }

    /// ocrBoxes must return an empty array when no surface text matches.
    func testOcrBoxesReturnsEmptyWhenNoMatch() throws {
        let pdfURL = try makeImageOnlyPdf(lines: ["John Smith ACME CORP"])

        let boxes = PdfOCRImporter.ocrBoxes(
            in: pdfURL,
            matching: [(text: "ZZZZNONEXISTENTZZZZ", token: "{PERSON_9}")]
        )

        XCTAssertTrue(
            boxes.isEmpty,
            "ocrBoxes should return no boxes for a string that is not on the page."
        )
    }

    /// A non-PDF path must be rejected by canImport.
    func testCanImportRejectsNonPdf() {
        let importer = PdfOCRImporter()
        let txtURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("not-a-pdf.txt")
        XCTAssertFalse(importer.canImport(txtURL))
    }

    /// An unreadable / missing file must throw, not crash.
    func testImportThrowsForMissingFile() {
        let importer = PdfOCRImporter()
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).pdf")

        XCTAssertThrowsError(try importer.importDocument(missing)) { error in
            XCTAssertTrue(
                error is DocumentIOError,
                "Expected DocumentIOError, got \(error)"
            )
        }
    }

    // MARK: - Fixture synthesis

    /// Renders the given text lines into a high-contrast CGImage and embeds that
    /// image as the sole content of a single-page PDF (no text layer). Returns the
    /// URL of the written PDF in the temporary directory.
    private func makeImageOnlyPdf(lines: [String]) throws -> URL {
        let image = try renderTextImage(lines: lines)

        let pageWidth = CGFloat(image.width)
        let pageHeight = CGFloat(image.height)
        var mediaBox = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)

        let pdfURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocr-fixture-\(UUID().uuidString).pdf")
        createdURLs.append(pdfURL)

        guard let consumer = CGDataConsumer(url: pdfURL as CFURL),
              let pdfContext = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else {
            throw XCTSkip("Could not create a PDF context for the fixture.")
        }

        pdfContext.beginPDFPage(nil)
        // Draw ONLY the rasterized image. No text is drawn into the PDF, so there
        // is no text layer and OCR is the only path to the words.
        pdfContext.draw(image, in: mediaBox)
        pdfContext.endPDFPage()
        pdfContext.closePDF()

        // Sanity guard: the fixture must be openable and must NOT already carry a
        // usable text layer, otherwise the test would not exercise OCR.
        guard let check = PDFDocument(url: pdfURL) else {
            XCTFail("Synthesized fixture PDF could not be reopened.")
            throw DocumentIOError.unreadable("fixture reopen failed")
        }
        let embeddedText = (check.string ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(
            embeddedText.isEmpty,
            "Fixture PDF unexpectedly has a text layer (\(embeddedText)); the OCR "
                + "test would be invalid."
        )

        return pdfURL
    }

    /// Renders text lines into a large, clean, black-on-white CGImage to maximize
    /// OCR reliability.
    private func renderTextImage(lines: [String]) throws -> CGImage {
        // Generous canvas and large font keep glyphs crisp for the recognizer.
        let width = 1400
        let lineHeight = 160
        let topMargin = 120
        let leftMargin = 100
        let height = topMargin * 2 + lineHeight * max(lines.count, 1)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw XCTSkip("Could not create a bitmap context for the fixture.")
        }

        // White background.
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let fontSize: CGFloat = 96
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let black = CGColor(red: 0, green: 0, blue: 0, alpha: 1)

        // CoreGraphics text origin is bottom-left, so draw from the top down by
        // computing each baseline from the top margin.
        for (index, line) in lines.enumerated() {
            let baselineFromTop = topMargin + lineHeight * index + Int(fontSize)
            let y = CGFloat(height - baselineFromTop)

            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: black
            ]
            let attributed = NSAttributedString(string: line, attributes: attributes)
            let ctLine = CTLineCreateWithAttributedString(attributed as CFAttributedString)

            context.textPosition = CGPoint(x: CGFloat(leftMargin), y: y)
            CTLineDraw(ctLine, context)
        }

        guard let image = context.makeImage() else {
            throw XCTSkip("Could not render the fixture text image.")
        }
        return image
    }
}
