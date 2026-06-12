// Tests/LDACoreTests/PdfImageInventoryTests.swift
import XCTest
import CoreGraphics
import CoreText
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

    /// Bug io-pdf-image-inventory-misses-form-xobjects: a page whose only XObject
    /// is a Form XObject that itself nests an Image XObject must still be reported
    /// as image-bearing, so the image-PII channel OCRs it.
    func testFormNestedImagePdfReportsThePage() throws {
        let url = try makeFormNestedImagePdf()
        XCTAssertEqual(PdfImageInventory.pagesWithImages(url), [0])
    }

    /// Authors a minimal valid PDF where the page's only XObject is a FORM
    /// XObject, and that Form's own Resources/XObject holds the actual IMAGE
    /// XObject. Mirrors /tmp/make_form_xobject_pdf.py so the structure matches the
    /// exact case PdfImageInventory.pageHasImage used to miss.
    private func makeFormNestedImagePdf() throws -> URL {
        // A tiny 2x2 RGB image, raw (no filter) to keep it trivial.
        let imgW = 2, imgH = 2
        let imgData = Data([255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 0])

        // Object bodies, keyed by object number.
        var objs: [Int: Data] = [:]
        objs[1] = Data("<< /Type /Catalog /Pages 2 0 R >>".utf8)
        objs[2] = Data("<< /Type /Pages /Kids [3 0 R] /Count 1 >>".utf8)
        objs[3] = Data((
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] " +
            "/Resources << /XObject << /Fm0 5 0 R >> >> " +
            "/Contents 4 0 R >>"
        ).utf8)

        let content = Data("q 100 0 0 100 50 50 cm /Fm0 Do Q".utf8)
        var obj4 = Data("<< /Length \(content.count) >>\nstream\n".utf8)
        obj4.append(content)
        obj4.append(Data("\nendstream".utf8))
        objs[4] = obj4

        let formContent = Data("q 1 0 0 1 0 0 cm /Im0 Do Q".utf8)
        var obj5 = Data((
            "<< /Type /XObject /Subtype /Form /FormType 1 /BBox [0 0 1 1] " +
            "/Resources << /XObject << /Im0 6 0 R >> >> " +
            "/Length \(formContent.count) >>\nstream\n"
        ).utf8)
        obj5.append(formContent)
        obj5.append(Data("\nendstream".utf8))
        objs[5] = obj5

        var obj6 = Data((
            "<< /Type /XObject /Subtype /Image /Width \(imgW) /Height \(imgH) " +
            "/ColorSpace /DeviceRGB /BitsPerComponent 8 /Length \(imgData.count) >>\nstream\n"
        ).utf8)
        obj6.append(imgData)
        obj6.append(Data("\nendstream".utf8))
        objs[6] = obj6

        // Header plus a binary comment line (the four high bytes mark the file as
        // binary). Written as raw bytes so they are not UTF-8 re-encoded.
        var out = Data("%PDF-1.5\n".utf8)
        out.append(Data([0x25, 0xe2, 0xe3, 0xcf, 0xd3, 0x0a]))
        var offsets: [Int: Int] = [:]
        for n in objs.keys.sorted() {
            offsets[n] = out.count
            out.append(Data("\(n) 0 obj\n".utf8))
            out.append(objs[n]!)
            out.append(Data("\nendobj\n".utf8))
        }

        let xrefPos = out.count
        let nObjs = (objs.keys.max() ?? 0) + 1
        out.append(Data("xref\n0 \(nObjs)\n".utf8))
        out.append(Data("0000000000 65535 f \n".utf8))
        for n in 1..<nObjs {
            let off = String(format: "%010d", offsets[n] ?? 0)
            out.append(Data("\(off) 00000 n \n".utf8))
        }
        out.append(Data((
            "trailer\n<< /Size \(nObjs) /Root 1 0 R >>\nstartxref\n\(xrefPos)\n%%EOF\n"
        ).utf8))

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("inv-form-\(UUID().uuidString).pdf")
        created.append(url)
        try out.write(to: url)
        return url
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
