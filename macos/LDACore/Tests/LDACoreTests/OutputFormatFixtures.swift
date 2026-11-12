//
//  OutputFormatFixtures.swift
//  LDACoreTests
//
//  Synthetic sources for the output format tests: a PDF with a real text
//  layer, pages of different sizes, an optional /Rotate page and identifying
//  document metadata; a JPEG or PNG carrying EXIF, TIFF, GPS, orientation and
//  resolution metadata; and the byte search the leak assertions use. Built in
//  code, so no binary fixture is committed.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import PDFKit
import XCTest
@testable import LDACore

enum OutputFormatFixtures {

    /// One page of a fixture PDF: its media box size and its text lines.
    struct Page {
        var size: CGSize
        var lines: [String]
    }

    static let letter = CGSize(width: 612, height: 792)
    static let a4 = CGSize(width: 595, height: 842)

    /// Write a PDF whose pages carry `pages` as a real text layer, with a
    /// title and author that name `metadataValue`. `rotatedPageIndex` gets
    /// /Rotate 90, the way scanner output often arrives.
    @discardableResult
    static func writePDF(
        _ pages: [Page],
        metadataValue: String,
        rotatedPageIndex: Int? = nil,
        to url: URL
    ) throws -> URL {
        let auxiliary: [CFString: Any] = [
            kCGPDFContextTitle: "Agreement for \(metadataValue)",
            kCGPDFContextAuthor: metadataValue
        ]
        guard let context = CGContext(url as CFURL, mediaBox: nil, auxiliary as CFDictionary) else {
            throw XCTSkip("no PDF context")
        }
        let font = CTFontCreateWithName("Helvetica" as CFString, 13, nil)
        for page in pages {
            var box = CGRect(origin: .zero, size: page.size)
            context.beginPage(mediaBox: &box)
            var y = page.size.height - 90
            for line in page.lines {
                let attributed = NSAttributedString(
                    string: line,
                    attributes: [.font: font, .foregroundColor: CGColor(gray: 0, alpha: 1)]
                )
                context.textPosition = CGPoint(x: 72, y: y)
                CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
                y -= 26
            }
            context.endPage()
        }
        context.closePDF()

        guard let rotatedPageIndex else { return url }
        guard let document = PDFDocument(url: url), let page = document.page(at: rotatedPageIndex) else {
            throw XCTSkip("PDFKit could not reopen the fixture")
        }
        page.rotation = 90
        // Written beside it and moved over, never onto the file PDFKit read.
        let rotated = url.deletingLastPathComponent().appendingPathComponent("rotated-\(UUID().uuidString).pdf")
        guard document.write(to: rotated) else { throw XCTSkip("PDFKit could not rewrite the fixture") }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: rotated)
        return url
    }

    /// Write a mixed PDF: a first page with `typedLines` as a real text layer,
    /// and a second page that is only a picture of `scannedLines`, the way a
    /// scanned exhibit sits behind a typed letter. The second page has no
    /// text layer, so only OCR can read it.
    @discardableResult
    static func writeHybridPDF(typedLines: [String], scannedLines: [String], to url: URL) throws -> URL {
        guard let context = CGContext(url as CFURL, mediaBox: nil, nil) else {
            throw XCTSkip("no PDF context")
        }
        let font = CTFontCreateWithName("Helvetica" as CFString, 13, nil)
        var box = CGRect(origin: .zero, size: letter)
        context.beginPage(mediaBox: &box)
        var y = letter.height - 90
        for line in typedLines {
            let attributed = NSAttributedString(
                string: line,
                attributes: [.font: font, .foregroundColor: CGColor(gray: 0, alpha: 1)]
            )
            context.textPosition = CGPoint(x: 72, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
            y -= 26
        }
        context.endPage()

        // The scan: large dark text on white, drawn as one image.
        let width = 1700, height = 2200
        guard let bitmap = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw XCTSkip("no bitmap context") }
        bitmap.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let scanFont = CTFontCreateWithName("Helvetica-Bold" as CFString, 56, nil)
        var scanY = CGFloat(height - 220)
        for line in scannedLines {
            let attributed = NSAttributedString(
                string: line,
                attributes: [.font: scanFont, .foregroundColor: CGColor(gray: 0, alpha: 1)]
            )
            bitmap.textPosition = CGPoint(x: 150, y: scanY)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), bitmap)
            scanY -= 110
        }
        guard let scan = bitmap.makeImage() else { throw XCTSkip("could not render the scan") }
        context.beginPage(mediaBox: &box)
        context.draw(scan, in: box)
        context.endPage()
        context.closePDF()
        return url
    }

    /// Metadata a photographed exhibit can carry that must never travel.
    static let identifyingValue = "Jordan Avery Blake"

    /// Write a white image with a black band where a line of text would be,
    /// carrying identifying TIFF, EXIF and GPS metadata plus the layout
    /// properties the original format keeps: orientation and resolution.
    @discardableResult
    static func writeImage(
        typeIdentifier: String,
        width: Int = 800,
        height: Int = 200,
        orientation: Int = 6,
        dpi: Int = 300,
        to url: URL
    ) throws -> URL {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw XCTSkip("no bitmap context") }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, typeIdentifier as CFString, 1, nil) else {
            throw XCTSkip("no image destination")
        }
        let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: orientation,
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi,
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFArtist: identifyingValue,
                kCGImagePropertyTIFFMake: "SynthCam",
                kCGImagePropertyTIFFModel: "Exhibit 1"
            ],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifUserComment: "Owner \(identifyingValue)",
                kCGImagePropertyExifDateTimeOriginal: "2026:11:01 10:00:00"
            ],
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 39.78,
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 89.65,
                kCGImagePropertyGPSLongitudeRef: "W"
            ]
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw XCTSkip("could not write the fixture image") }
        return url
    }

    /// The image properties of the file at `url`.
    static func imageProperties(_ url: URL) throws -> [CFString: Any] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            throw XCTSkip("could not read image properties")
        }
        return properties
    }

    /// The type identifier of the image file at `url`.
    static func imageType(_ url: URL) -> String? {
        CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceGetType($0) as String? }
    }

    /// The luminance (0 to 255) of the stored pixel at (x, y), with y
    /// counted from the bottom as CoreGraphics and Vision count it.
    static func luminance(of url: URL, x: Int, y: Int) throws -> Int {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw XCTSkip("could not decode the image")
        }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw XCTSkip("no pixel context") }
        context.draw(image, in: CGRect(x: -x, y: -y, width: image.width, height: image.height))
        return (Int(pixel[0]) + Int(pixel[1]) + Int(pixel[2])) / 3
    }

    /// True when `data` holds `value` as UTF-8 bytes.
    static func contains(_ data: Data, _ value: String) -> Bool {
        data.range(of: Data(value.utf8)) != nil
    }

    /// A deterministic span over the first occurrence of `surface`.
    static func span(in text: String, _ surface: String, _ type: EntityType) -> Span {
        DocxTestPackage.span(in: text, surface: surface, type: type)
    }
}
