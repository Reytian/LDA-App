import XCTest
import CoreGraphics
import CoreText
import PDFKit
@testable import LDACore

final class PdfOCRImporterImageOriginTests: XCTestCase {
    private var created: [URL] = []
    override func tearDownWithError() throws {
        for u in created { try? FileManager.default.removeItem(at: u) }
        created.removeAll()
    }

    /// A PDF with a real text layer ("TYPED CONTRACT BODY") plus an image-only word
    /// ("ZZSIGNATUREZZ"). The image-origin pass must return the image word and must
    /// NOT return the typed words.
    func testReturnsImageWordAndFiltersTextLayer() throws {
        let url = try makeHybridPdf(typed: "TYPED CONTRACT BODY",
                                    imageWord: "ZZSIGNATUREZZ")
        let pages = PdfImageInventory.pagesWithImages(url)
        XCTAssertEqual(pages, [0], "fixture must have an image page")

        let obs = PdfOCRImporter().imageOriginObservations(in: url, pages: pages)

        let joined = obs.map { $0.text }.joined(separator: " ").lowercased()
        XCTAssertFalse(obs.isEmpty,
            "OCR returned no image-origin observations; Vision may be unavailable here.")
        XCTAssertTrue(joined.contains("signature"),
            "image-only word was not recovered. Observations: \(joined)")
        XCTAssertFalse(joined.contains("typed"),
            "text-layer word leaked into image-origin observations: \(joined)")
        for o in obs {
            XCTAssertEqual(o.pageIndex, 0)
            XCTAssertGreaterThan(o.rect.width, 0)
            XCTAssertGreaterThan(o.rect.height, 0)
        }
    }

    private func makeHybridPdf(typed: String, imageWord: String) throws -> URL {
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hybrid-\(UUID().uuidString).pdf")
        created.append(url)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw XCTSkip("no PDF context")
        }
        ctx.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 28, nil)
        let attr = NSAttributedString(string: typed,
                                      attributes: [.font: font,
                                                   .foregroundColor: CGColor(gray: 0, alpha: 1)])
        ctx.textPosition = CGPoint(x: 72, y: 700)
        CTLineDraw(CTLineCreateWithAttributedString(attr), ctx)
        if let img = Self.wordImage(imageWord) {
            ctx.draw(img, in: CGRect(x: 72, y: 300, width: 360, height: 90))
        }
        ctx.endPDFPage()
        ctx.closePDF()
        return url
    }

    private static func wordImage(_ word: String) -> CGImage? {
        let w = 720, h = 180
        guard let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        c.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        c.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 96, nil)
        let attr = NSAttributedString(string: word,
                                      attributes: [.font: font,
                                                   .foregroundColor: CGColor(gray: 0, alpha: 1)])
        c.textPosition = CGPoint(x: 20, y: 50)
        CTLineDraw(CTLineCreateWithAttributedString(attr), c)
        return c.makeImage()
    }
}
