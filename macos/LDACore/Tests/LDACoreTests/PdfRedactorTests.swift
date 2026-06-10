//
//  PdfRedactorTests.swift
//  LDACoreTests
//
//  Tests that PdfRedactor.renderRedactedPDF produces a SAFE redacted artifact:
//  no recoverable text and no embedded source image XObject survives under a
//  redaction box. The fix flattens each page to a raster, so the boxed PII can
//  no longer be extracted via PDFKit .string, findString, or by pulling the
//  source Image XObject back out.
//
//  Every fixture is authored in code (CoreText text layer, a CGImage embedded as
//  an Image XObject) so no binary fixtures are committed and tests are hermetic.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
import PDFKit
import CoreGraphics
import CoreText
@testable import LDACore

final class PdfRedactorTests: XCTestCase {

    private var created: [URL] = []

    override func tearDownWithError() throws {
        for url in created { try? FileManager.default.removeItem(at: url) }
        created.removeAll()
    }

    private func tempURL(_ suffix: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdfredactor-\(UUID().uuidString)-\(suffix)")
        created.append(url)
        return url
    }

    // MARK: - Bug io-pdf-overlay-text-leak

    /// After redaction the boxed PII text must NOT be recoverable from the output
    /// PDF. A born-digital page is authored with a known text layer, the SSN is
    /// boxed exactly where it renders, and the output is checked with both the
    /// PDFKit text layer (.string) and a text search (findString).
    func testRedactedPdfHasNoRecoverableTextUnderBox() throws {
        let pii = "123-45-6789"
        let sentence = "SSN \(pii) John Smith"

        let source = tempURL("text-src.pdf")
        try Self.writeTextPdf(sentence: sentence, to: source)

        // Confirm the source really does carry an extractable text layer, so the
        // test is exercising the leak and not a trivially text-free PDF.
        let sourceDoc = try XCTUnwrap(PDFDocument(url: source))
        XCTAssertTrue((sourceDoc.string ?? "").contains(pii),
                      "source PDF should have an extractable text layer")

        // Box the PII exactly where the text layer reports it, the same way
        // PdfImporter.redactionBoxes computes boxes in production.
        let boxes = PdfImporter.redactionBoxes(
            in: source,
            surfaceTexts: [(text: pii, token: "{NATIONAL_ID_1}"),
                           (text: "John Smith", token: "{PERSON_1}")]
        )
        XCTAssertFalse(boxes.isEmpty, "expected redaction boxes over the PII")

        let out = tempURL("text-out.pdf")
        try PdfRedactor.renderRedactedPDF(original: source, boxes: boxes, to: out)

        let outDoc = try XCTUnwrap(PDFDocument(url: out))
        let extracted = outDoc.string ?? ""
        XCTAssertFalse(extracted.contains(pii),
                       "redacted PDF still yields the SSN via text extraction")
        XCTAssertFalse(extracted.contains("John Smith"),
                       "redacted PDF still yields the name via text extraction")
        XCTAssertEqual(outDoc.findString(pii, withOptions: .caseInsensitive).count, 0,
                       "redacted PDF still locates the SSN via findString")
    }

    // MARK: - Bug io-pdf-overlay-image-leak

    /// After redaction the embedded source Image XObject (a signature/stamp) must
    /// be gone: the output page content is a single flattened full-page raster, so
    /// the original signature raster can no longer be pulled back out.
    ///
    /// The flatten approach inherently emits one full-page raster per page, so the
    /// right safety check is that NO surviving Image XObject has the source
    /// signature's pixel dimensions (the original 320x160 raster is gone), and the
    /// only image present is the larger full-page flatten.
    func testRedactedPdfHasNoSourceImageXObjectUnderBox() throws {
        let signatureWidthPx = 320
        let signatureHeightPx = 160
        let signatureRect = CGRect(x: 120, y: 60, width: 160, height: 80)
        let source = tempURL("image-src.pdf")
        try Self.writeImagePdf(
            signatureRect: signatureRect,
            signaturePixels: (signatureWidthPx, signatureHeightPx),
            to: source
        )

        // The source must embed exactly the one signature Image XObject, otherwise
        // the test is not exercising the image leak.
        let sourceImages = Self.imageXObjectDimensions(source)
        XCTAssertEqual(sourceImages, [Dimension(width: signatureWidthPx, height: signatureHeightPx)],
                       "source PDF should embed exactly the signature Image XObject")

        let boxes = [RedactionBox(pageIndex: 0, rect: signatureRect, token: "{SIGNATURE_1}")]
        let out = tempURL("image-out.pdf")
        try PdfRedactor.renderRedactedPDF(original: source, boxes: boxes, to: out)

        let outImages = Self.imageXObjectDimensions(out)
        // The original signature raster must no longer be present anywhere.
        XCTAssertFalse(
            outImages.contains(Dimension(width: signatureWidthPx, height: signatureHeightPx)),
            "redacted PDF still embeds the source signature Image XObject under the box"
        )
        // The page is now a single flattened raster: exactly one image, and it is
        // bigger than the source signature (a full-page render).
        XCTAssertEqual(outImages.count, 1, "redacted page should be a single flattened raster")
        if let only = outImages.first {
            XCTAssertGreaterThan(only.width, signatureWidthPx,
                                 "the surviving image should be the full-page flatten, not the signature")
            XCTAssertGreaterThan(only.height, signatureHeightPx,
                                 "the surviving image should be the full-page flatten, not the signature")
        }
    }

    // MARK: - Page count preserved

    /// The flatten path must still emit one output page per source page.
    func testRedactedPdfPreservesPageCount() throws {
        let source = tempURL("count-src.pdf")
        try Self.writeTextPdf(sentence: "Confidential party John Smith", to: source)

        let out = tempURL("count-out.pdf")
        try PdfRedactor.renderRedactedPDF(original: source, boxes: [], to: out)

        let outDoc = try XCTUnwrap(PDFDocument(url: out))
        XCTAssertEqual(outDoc.pageCount, 1)
    }

    // MARK: - Fixture authoring

    /// Writes a one-page born-digital PDF carrying the given sentence as a real
    /// CoreText text layer.
    private static func writeTextPdf(sentence: String, to url: URL) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw XCTSkip("could not create a PDF context")
        }
        context.beginPage(mediaBox: &mediaBox)
        let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: CGColor(gray: 0, alpha: 1)
        ]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: sentence, attributes: attributes))
        context.textPosition = CGPoint(x: 72, y: 700)
        CTLineDraw(line, context)
        context.endPage()
        context.closePDF()
    }

    /// Writes a one-page PDF that embeds a single raster image (a fake signature)
    /// at the given rect. CoreGraphics records a drawn CGImage as an Image XObject.
    private static func writeImagePdf(
        signatureRect: CGRect,
        signaturePixels: (width: Int, height: Int),
        to url: URL
    ) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: 400, height: 300)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw XCTSkip("could not create a PDF context")
        }
        context.beginPage(mediaBox: &mediaBox)

        // A bit of text so the page is born-digital, like a real signature page.
        let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: CGColor(gray: 0, alpha: 1)
        ]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: "Signed by the parties below:", attributes: attributes))
        context.textPosition = CGPoint(x: 40, y: 200)
        CTLineDraw(line, context)

        if let signature = makeSignatureImage(width: signaturePixels.width,
                                              height: signaturePixels.height) {
            context.draw(signature, in: signatureRect)
        }

        context.endPage()
        context.closePDF()
    }

    /// A recognizable raster signature: white background with a diagonal stroke.
    private static func makeSignatureImage(width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.setLineWidth(3)
        context.move(to: CGPoint(x: 5, y: 5))
        context.addLine(to: CGPoint(x: CGFloat(width) - 5, y: CGFloat(height) - 5))
        context.strokePath()
        return context.makeImage()
    }

    /// The pixel dimensions of one Image XObject.
    private struct Dimension: Equatable {
        var width: Int
        var height: Int
    }

    /// A mutable collector so the C ApplyFunction callback can record dimensions
    /// without capturing Swift context (a C function pointer cannot capture).
    private final class DimensionCollector {
        var dimensions: [Dimension] = []
    }

    /// Returns the pixel dimensions of every Image XObject across all pages, using
    /// the same CGPDF walk the production PdfImageInventory uses.
    private static func imageXObjectDimensions(_ url: URL) -> [Dimension] {
        guard let doc = CGPDFDocument(url as CFURL) else { return [] }
        let total = doc.numberOfPages
        guard total > 0 else { return [] }

        let collector = DimensionCollector()
        let info = Unmanaged.passUnretained(collector).toOpaque()

        for i in 1...total {
            guard let page = doc.page(at: i), let dict = page.dictionary else { continue }
            var resources: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(dict, "Resources", &resources),
                  let resources else { continue }
            var xobjects: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects),
                  let xobjects else { continue }
            CGPDFDictionaryApplyFunction(xobjects, { (_, object, info) in
                let collector = Unmanaged<DimensionCollector>.fromOpaque(info!).takeUnretainedValue()
                var stream: CGPDFStreamRef?
                guard CGPDFObjectGetValue(object, .stream, &stream), let stream,
                      let streamDict = CGPDFStreamGetDictionary(stream) else { return }
                var subtype: UnsafePointer<Int8>?
                guard CGPDFDictionaryGetName(streamDict, "Subtype", &subtype), let subtype,
                      String(cString: subtype) == "Image" else { return }
                var width: CGPDFInteger = 0
                var height: CGPDFInteger = 0
                CGPDFDictionaryGetInteger(streamDict, "Width", &width)
                CGPDFDictionaryGetInteger(streamDict, "Height", &height)
                collector.dimensions.append(Dimension(width: Int(width), height: Int(height)))
            }, info)
        }
        return collector.dimensions
    }
}
