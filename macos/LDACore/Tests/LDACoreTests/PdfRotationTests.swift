//
//  PdfRotationTests.swift
//  LDACoreTests
//
//  Rotated scanned pages are extremely common scanner output: the raster is
//  stored sideways and the page carries /Rotate 90 so viewers display it
//  upright. The OCR import path and the redaction path must both compensate,
//  or redaction boxes land in the wrong place and the PII stays visible in
//  the "redacted" output.
//
//  The fixture stores the text image rotated 90 degrees counterclockwise in
//  the content stream and sets PDFPage.rotation = 90, which displays upright.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
import PDFKit
import CoreGraphics
import CoreText
@testable import LDACore

final class PdfRotationTests: XCTestCase {

    private var createdURLs: [URL] = []

    override func tearDown() {
        for url in createdURLs {
            try? FileManager.default.removeItem(at: url)
        }
        createdURLs = []
        super.tearDown()
    }

    // MARK: - Import

    /// OCR import of a /Rotate 90 scanned page must recover the text exactly as
    /// a viewer displays it. A sideways raster fed to Vision returns garbage or
    /// nothing, which upstream looks like "no PII on this page".
    func testImportRecoversTextFromRotatedScannedPage() throws {
        let url = try makeRotatedScannedPdf(lines: [
            "CONFIDENTIAL MEMO FOR",
            "JOHN SMITH ESQUIRE",
            "KEEP THIS LINE SAFE"
        ])

        let imported = try PdfOCRImporter().importDocument(url)
        let upper = imported.text.uppercased()

        XCTAssertTrue(
            upper.contains("JOHN SMITH"),
            "rotated page text not recovered; got: \(imported.text.prefix(200))"
        )
        XCTAssertTrue(upper.contains("SAFE"))
    }

    // MARK: - End-to-end redaction

    /// The full scanned-page redaction loop on a rotated page: locate the PII
    /// via OCR boxes, render the redacted PDF, and verify by re-OCR that the
    /// PII is gone while unrelated content survives. Misplaced boxes fail the
    /// "PII gone" half; an unreadable or blanked page fails the "survives"
    /// half.
    func testRotatedScannedPageRedactionCoversPIIAndKeepsRest() throws {
        let url = try makeRotatedScannedPdf(lines: [
            "CONFIDENTIAL MEMO FOR",
            "JOHN SMITH ESQUIRE",
            "KEEP THIS LINE SAFE"
        ])

        let boxes = PdfOCRImporter.ocrBoxes(
            in: url,
            matching: [(text: "JOHN SMITH ESQUIRE", token: "[PERSON_1]")]
        )
        XCTAssertFalse(boxes.isEmpty, "OCR boxes must locate the PII on a rotated page")

        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("rotated-redacted-\(UUID().uuidString).pdf")
        createdURLs.append(out)

        try PdfRedactor.renderRedactedPDF(original: url, boxes: boxes, to: out)

        let redacted = try PdfOCRImporter().importDocument(out)
        let upper = redacted.text.uppercased()

        XCTAssertFalse(
            upper.contains("JOHN SMITH"),
            "PII still recognizable in redacted output; boxes landed in the wrong place"
        )
        XCTAssertTrue(
            upper.contains("SAFE"),
            "unrelated content must survive redaction; got: \(redacted.text.prefix(200))"
        )
    }

    // MARK: - Fixture synthesis

    /// Builds a single-page image-only PDF whose raster is stored rotated 90
    /// degrees counterclockwise, with the page's /Rotate set to 90 so viewers
    /// display it upright. Verifies the fixture has the rotation flag and no
    /// text layer.
    private func makeRotatedScannedPdf(lines: [String]) throws -> URL {
        let image = try renderTextImage(lines: lines)
        let imageWidth = CGFloat(image.width)
        let imageHeight = CGFloat(image.height)

        // Content space holds the image rotated CCW, so the media box swaps.
        var mediaBox = CGRect(x: 0, y: 0, width: imageHeight, height: imageWidth)

        let rawURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("rotated-fixture-raw-\(UUID().uuidString).pdf")
        createdURLs.append(rawURL)

        guard let consumer = CGDataConsumer(url: rawURL as CFURL),
              let pdfContext = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else {
            throw XCTSkip("Could not create a PDF context for the fixture.")
        }

        pdfContext.beginPDFPage(nil)
        // Rotate the upright image 90 degrees counterclockwise into the page:
        // image point (u, v) lands at (imageHeight - v, u). Applying /Rotate 90
        // (clockwise display rotation) then shows it upright again.
        pdfContext.saveGState()
        pdfContext.translateBy(x: imageHeight, y: 0)
        pdfContext.rotate(by: .pi / 2)
        pdfContext.draw(image, in: CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight))
        pdfContext.restoreGState()
        pdfContext.endPDFPage()
        pdfContext.closePDF()

        // Stamp /Rotate 90 via PDFKit and re-save.
        guard let document = PDFDocument(url: rawURL), let page = document.page(at: 0) else {
            XCTFail("Fixture PDF could not be reopened for rotation stamping.")
            throw DocumentIOError.unreadable("fixture reopen failed")
        }
        page.rotation = 90

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rotated-fixture-\(UUID().uuidString).pdf")
        createdURLs.append(url)
        guard document.write(to: url) else {
            XCTFail("Fixture PDF could not be written with rotation.")
            throw DocumentIOError.unreadable("fixture write failed")
        }

        // Sanity: rotation survived the round-trip and there is no text layer.
        guard let check = PDFDocument(url: url), let checkPage = check.page(at: 0) else {
            XCTFail("Rotated fixture could not be reopened.")
            throw DocumentIOError.unreadable("fixture reopen failed")
        }
        XCTAssertEqual(checkPage.rotation, 90, "fixture must carry /Rotate 90")
        let embedded = (check.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(embedded.isEmpty, "fixture must not carry a text layer")

        return url
    }

    /// Renders text lines into a large black-on-white CGImage (same approach as
    /// PdfOCRImporterTests, kept local so each fixture stays self-contained).
    private func renderTextImage(lines: [String]) throws -> CGImage {
        let width = 1400
        let lineHeight = 160
        let topMargin = 120
        let leftMargin = 100
        let height = topMargin * 2 + lineHeight * max(lines.count, 1)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw XCTSkip("Could not create a bitmap context for the fixture.")
        }

        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let fontSize: CGFloat = 96
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let black = CGColor(red: 0, green: 0, blue: 0, alpha: 1)

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
