//
//  HybridPdfTests.swift
//  LDACoreTests
//
//  A hybrid PDF mixes born-digital pages (text layer) with scanned pages
//  (raster only). Real contract packages do this constantly: a digital
//  agreement plus a scanned signature page or exhibit. Detection used to be
//  per-document: any usable text layer anywhere meant the scanned pages were
//  never OCR'd, so their PII reached neither the mapping nor the review-PDF
//  boxes. These tests pin the per-page behavior.
//
//  The fixtures use EMAIL values because the deterministic engine owns that
//  type, so the pipeline runs without the GGUF model.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
import PDFKit
import CoreGraphics
import CoreText
@testable import LDACore

final class HybridPdfTests: XCTestCase {

    private var createdURLs: [URL] = []

    override func tearDown() {
        for url in createdURLs {
            try? FileManager.default.removeItem(at: url)
        }
        createdURLs = []
        super.tearDown()
    }

    // MARK: - Import

    /// The importer must flag exactly the text-free pages of a hybrid PDF.
    func testImportFlagsScannedPagesOfHybridPdf() throws {
        let url = try makeHybridPdf(
            digitalText: "Agreement with alice@acme.example for services.",
            scannedLines: ["SIGNED COPY SENT TO", "smith@example.com", "KEEP THIS SAFE"]
        )

        let imported = try PdfImporter().importDocument(url)

        XCTAssertFalse(imported.isScanned, "a hybrid PDF is not fully scanned")
        XCTAssertEqual(imported.pageCount, 2)
        XCTAssertEqual(
            imported.scannedPageIndexes, [1],
            "page 2 has no text layer and must be flagged for OCR"
        )
    }

    /// The service-level import must splice OCR text from the scanned pages
    /// into the document text, so detection sees the whole document.
    func testDetectFindsPIIOnScannedPageOfHybridPdf() throws {
        let url = try makeHybridPdf(
            digitalText: "Agreement with alice@acme.example for services.",
            scannedLines: ["SIGNED COPY SENT TO", "smith@example.com", "KEEP THIS SAFE"]
        )

        let spans = try LDAService.detect(input: url)
        let values = Set(spans.map { $0.text.lowercased() })

        XCTAssertTrue(values.contains("alice@acme.example"), "text-layer PII must be found")
        XCTAssertTrue(
            values.contains("smith@example.com"),
            "scanned-page PII must be found via per-page OCR; got: \(values)"
        )
    }

    // MARK: - End-to-end anonymize

    /// Full anonymize on a hybrid PDF: the scanned page's PII must be in the
    /// mapping (tokenized in the companion) and covered in the review PDF,
    /// while unrelated scanned content survives.
    func testAnonymizeCoversScannedPagePIIInReviewPdf() throws {
        let url = try makeHybridPdf(
            digitalText: "Agreement with alice@acme.example for services.",
            scannedLines: ["SIGNED COPY SENT TO", "smith@example.com", "KEEP THIS SAFE"]
        )
        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hybrid-out-\(UUID().uuidString)", isDirectory: true)
        createdURLs.append(outputDir)

        let result = try LDAService.anonymize(
            input: url,
            outputDir: outputDir,
            protection: .passphrase("test-passphrase"),
            createdAtISO8601: "2026-01-01T00:00:00Z"
        )

        // The companion edit surface must carry tokens for BOTH emails.
        let companion = try String(contentsOf: result.redactedFileURL, encoding: .utf8)
        XCTAssertFalse(companion.contains("alice@acme.example"))
        XCTAssertFalse(
            companion.contains("smith@example.com"),
            "scanned-page PII must be tokenized in the companion"
        )

        // The review PDF must cover the scanned page's PII but keep the rest.
        let reviewURL = try XCTUnwrap(result.visualPdfURL)
        let review = try PdfOCRImporter().importDocument(reviewURL)
        let upper = review.text.uppercased()
        XCTAssertFalse(
            upper.contains("SMITH@EXAMPLE.COM"),
            "scanned-page PII still visible in the review PDF"
        )
        XCTAssertTrue(
            upper.contains("SAFE"),
            "unrelated scanned content must survive; got: \(review.text.prefix(300))"
        )
    }

    // MARK: - Fixture synthesis

    /// Builds a two-page PDF: page 1 born-digital (real text layer), page 2
    /// image-only (raster, no text layer).
    private func makeHybridPdf(digitalText: String, scannedLines: [String]) throws -> URL {
        let image = try renderTextImage(lines: scannedLines)
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hybrid-fixture-\(UUID().uuidString).pdf")
        createdURLs.append(url)

        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else {
            throw XCTSkip("Could not create a PDF context for the fixture.")
        }

        // Page 1: born-digital text.
        context.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
        let attributed = NSAttributedString(
            string: digitalText,
            attributes: [.font: font, .foregroundColor: CGColor(red: 0, green: 0, blue: 0, alpha: 1)]
        )
        context.textPosition = CGPoint(x: 72, y: 700)
        CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        context.endPDFPage()

        // Page 2: raster only, scaled into the page.
        context.beginPDFPage(nil)
        context.draw(image, in: CGRect(x: 0, y: 200, width: 612, height: 320))
        context.endPDFPage()
        context.closePDF()

        // Sanity: page 1 has text, page 2 does not.
        guard let check = PDFDocument(url: url),
              let page1 = check.page(at: 0), let page2 = check.page(at: 1) else {
            XCTFail("Hybrid fixture could not be reopened.")
            throw DocumentIOError.unreadable("fixture reopen failed")
        }
        XCTAssertFalse((page1.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertTrue((page2.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        return url
    }

    /// Renders text lines into a large black-on-white CGImage for the scanned
    /// page.
    private func renderTextImage(lines: [String]) throws -> CGImage {
        let width = 1400
        let lineHeight = 160
        let topMargin = 120
        let leftMargin = 100
        let height = topMargin * 2 + lineHeight * max(lines.count, 1)

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw XCTSkip("Could not create a bitmap context for the fixture.")
        }

        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let fontSize: CGFloat = 96
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        for (index, line) in lines.enumerated() {
            let baselineFromTop = topMargin + lineHeight * index + Int(fontSize)
            let y = CGFloat(height - baselineFromTop)
            let attributed = NSAttributedString(
                string: line,
                attributes: [.font: font, .foregroundColor: CGColor(red: 0, green: 0, blue: 0, alpha: 1)]
            )
            context.textPosition = CGPoint(x: CGFloat(leftMargin), y: y)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        }

        guard let image = context.makeImage() else {
            throw XCTSkip("Could not render the fixture text image.")
        }
        return image
    }
}
