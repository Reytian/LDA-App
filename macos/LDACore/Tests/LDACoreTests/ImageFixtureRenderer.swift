//
//  ImageFixtureRenderer.swift
//  LDACoreTests
//
//  Shared test helper: renders known text lines into a high-contrast raster
//  image and writes it as a PNG (or JPEG) fixture in the temporary directory,
//  so image-input tests can run REAL Vision OCR against text they planted
//  themselves. No fixture files are checked into the repository.
//
//  The rendering conventions mirror PdfOCRImporterTests: generous canvas,
//  large bold glyphs, black on white. PingFang SC is requested so mixed
//  Chinese and Latin fixture lines render crisply; CoreText falls back
//  through the cascade list when it is unavailable.
//
//  House rules: all comments and strings in English (fixture CONTENT provided
//  by tests may contain Chinese). No em-dash and no en-dash-as-separator.
//

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ImageFixtureRenderer {

    enum FixtureError: Error {
        case contextUnavailable
        case renderFailed
        case writeFailed(String)
    }

    /// Render the given lines black-on-white and write a PNG into the
    /// temporary directory. The caller owns deletion of the returned URL.
    static func writePNG(
        lines: [String],
        width: Int = 1800,
        fontSize: CGFloat = 64,
        lineHeight: Int = 110
    ) throws -> URL {
        let image = try render(
            lines: lines,
            width: width,
            fontSize: fontSize,
            lineHeight: lineHeight
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("image-fixture-\(UUID().uuidString).png")
        try write(image: image, to: url, typeIdentifier: UTType.png.identifier)
        return url
    }

    /// Render the given lines and write a JPEG, for exercising the jpg path.
    static func writeJPEG(
        lines: [String],
        width: Int = 1800,
        fontSize: CGFloat = 64,
        lineHeight: Int = 110
    ) throws -> URL {
        let image = try render(
            lines: lines,
            width: width,
            fontSize: fontSize,
            lineHeight: lineHeight
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("image-fixture-\(UUID().uuidString).jpg")
        try write(image: image, to: url, typeIdentifier: UTType.jpeg.identifier)
        return url
    }

    /// Write a blank white PNG with no glyphs at all: the import-refusal
    /// fixture. Vision must find no readable text in it.
    static func writeBlankPNG(width: Int = 600, height: Int = 400) throws -> URL {
        let context = try makeContext(width: width, height: height)
        guard let image = context.makeImage() else {
            throw FixtureError.renderFailed
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("image-fixture-blank-\(UUID().uuidString).png")
        try write(image: image, to: url, typeIdentifier: UTType.png.identifier)
        return url
    }

    /// Render the given lines PLUS a solid red ellipse: the stamped-document
    /// fixture the seal candidate channel is exercised against. The stamp rect
    /// is in CG bottom-left pixel space, so keep it clear of the text lines.
    static func writeStampedPNG(
        lines: [String],
        stamp: CGRect,
        width: Int = 1800,
        fontSize: CGFloat = 64,
        lineHeight: Int = 110
    ) throws -> URL {
        let image = try render(
            lines: lines,
            width: width,
            fontSize: fontSize,
            lineHeight: lineHeight,
            stamp: stamp
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("image-fixture-stamped-\(UUID().uuidString).png")
        try write(image: image, to: url, typeIdentifier: UTType.png.identifier)
        return url
    }

    /// Render text lines into a white-background CGImage, top to bottom, with
    /// an optional red stamp ellipse painted over the page.
    static func render(
        lines: [String],
        width: Int = 1800,
        fontSize: CGFloat = 64,
        lineHeight: Int = 110,
        stamp: CGRect? = nil
    ) throws -> CGImage {
        let topMargin = 80
        let leftMargin = 80
        let height = topMargin * 2 + lineHeight * max(lines.count, 1)
        let context = try makeContext(width: width, height: height)

        // PingFang SC Semibold covers both CJK and Latin glyphs crisply.
        // CTFontCreateWithName never returns nil; unknown names fall back.
        let font = CTFontCreateWithName("PingFangSC-Semibold" as CFString, fontSize, nil)
        let black = CGColor(red: 0, green: 0, blue: 0, alpha: 1)

        // CoreGraphics text origin is bottom-left; compute baselines from the top.
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

        // Seal ink red, well inside SealCandidateDetector's threshold.
        if let stamp {
            context.setFillColor(CGColor(red: 0.87, green: 0.17, blue: 0.15, alpha: 1))
            context.fillEllipse(in: stamp)
        }

        guard let image = context.makeImage() else {
            throw FixtureError.renderFailed
        }
        return image
    }

    /// Write a CGImage to disk with ImageIO.
    static func write(image: CGImage, to url: URL, typeIdentifier: String) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            typeIdentifier as CFString,
            1,
            nil
        ) else {
            throw FixtureError.writeFailed("could not create destination at \(url.path)")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw FixtureError.writeFailed("could not finalize image at \(url.path)")
        }
    }

    /// The digits of a string, in order, with everything else stripped. OCR can
    /// vary punctuation and spacing, so leak assertions compare digit runs.
    static func digitsOnly(_ text: String) -> String {
        String(text.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) })
    }

    // MARK: - Private

    private static func makeContext(width: Int, height: Int) throws -> CGContext {
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
            throw FixtureError.contextUnavailable
        }
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context
    }
}
