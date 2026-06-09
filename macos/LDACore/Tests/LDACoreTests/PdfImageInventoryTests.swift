// Tests/LDACoreTests/PdfImageInventoryTests.swift
import XCTest
import CoreGraphics
import CoreText
import PDFKit
@testable import LDACore

final class PdfImageInventoryTests: XCTestCase {
    private var created: [URL] = []
    override func tearDownWithError() throws {
        for u in created { try? FileManager.default.removeItem(at: u) }
        created.removeAll()
    }

    func testTextOnlyPdfHasNoImagePages() throws {
        let url = try makePdf(drawImage: false)
        XCTAssertEqual(PdfImageInventory.pagesWithImages(url), [])
    }

    func testImageBearingPdfReportsThePage() throws {
        let url = try makePdf(drawImage: true)
        XCTAssertEqual(PdfImageInventory.pagesWithImages(url), [0])
    }

    /// One-page PDF with a real text layer (CTLineDraw) and, optionally, an
    /// embedded raster image XObject (context.draw(image:)).
    private func makePdf(drawImage: Bool) throws -> URL {
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("inv-\(UUID().uuidString).pdf")
        created.append(url)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw XCTSkip("no PDF context")
        }
        ctx.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, 24, nil)
        let attr = NSAttributedString(string: "TYPED TEXT LAYER",
                                      attributes: [.font: font,
                                                   .foregroundColor: CGColor(gray: 0, alpha: 1)])
        ctx.textPosition = CGPoint(x: 72, y: 700)
        CTLineDraw(CTLineCreateWithAttributedString(attr), ctx)
        if drawImage, let img = Self.solidImage() {
            ctx.draw(img, in: CGRect(x: 72, y: 400, width: 200, height: 80))
        }
        ctx.endPDFPage()
        ctx.closePDF()
        return url
    }

    private static func solidImage() -> CGImage? {
        guard let c = CGContext(data: nil, width: 200, height: 80, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        c.setFillColor(CGColor(red: 0.2, green: 0.2, blue: 0.2, alpha: 1))
        c.fill(CGRect(x: 0, y: 0, width: 200, height: 80))
        return c.makeImage()
    }
}
