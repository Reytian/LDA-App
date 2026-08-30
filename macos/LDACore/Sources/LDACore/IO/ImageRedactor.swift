//
//  ImageRedactor.swift
//  LDACore
//
//  Renders the redacted IMAGE artifact for standalone image input: a copy of
//  the source raster with opaque boxes painted over every OCR observation
//  that carries a replaced character range. Coverage policy is conservative:
//  when ANY part of a replaced range falls inside an observation line, the
//  WHOLE line box is painted. Over-covering is acceptable; under-covering is
//  a leak. Boxes are destructive by design, so an image artifact is never
//  restorable; restore lives on the paired redacted TEXT artifact.
//
//  CoreGraphics and ImageIO only: no UI frameworks in LDACore.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation
import CoreGraphics
import ImageIO

public enum ImageRedactor {

    // MARK: - Coverage mapping (pure)

    /// The outcome of mapping replaced ranges onto observation lines.
    public struct Coverage: Sendable, Equatable {
        /// The lines whose boxes must be painted, in input order, deduplicated.
        public var coveredLines: [ImageTextLine]
        /// Replaced ranges that intersect NO observation line. Each one is a
        /// value the caller replaced in the text but cannot box in the image;
        /// it must be surfaced as a warning, never dropped.
        public var unlocatedRangeCount: Int

        public init(coveredLines: [ImageTextLine], unlocatedRangeCount: Int) {
            self.coveredLines = coveredLines
            self.unlocatedRangeCount = unlocatedRangeCount
        }
    }

    /// Map replaced UTF-16 ranges (offsets into the extraction's joined text)
    /// onto the observation lines they intersect.
    public static func coverage(
        lines: [ImageTextLine],
        replacedRanges: [Range<Int>]
    ) -> Coverage {
        var coveredIndexes = Set<Int>()
        var unlocated = 0

        for replaced in replacedRanges {
            var found = false
            for (index, line) in lines.enumerated() where intersects(line.range, replaced) {
                coveredIndexes.insert(index)
                found = true
            }
            if !found { unlocated += 1 }
        }

        let covered = coveredIndexes.sorted().map { lines[$0] }
        return Coverage(coveredLines: covered, unlocatedRangeCount: unlocated)
    }

    /// Half-open range intersection with a non-empty overlap.
    private static func intersects(_ a: Range<Int>, _ b: Range<Int>) -> Bool {
        max(a.lowerBound, b.lowerBound) < min(a.upperBound, b.upperBound)
    }

    // MARK: - Painting

    /// Paint opaque boxes over the covered lines and write the result as a
    /// PNG. Returns the number of boxes painted. With an empty cover list the
    /// output is still written (a faithful re-encoded copy), so the artifact
    /// pair promised by anonymize always exists.
    @discardableResult
    public static func renderRedactedPNG(
        originalImageAt url: URL,
        covering lines: [ImageTextLine],
        to outputURL: URL
    ) throws -> Int {
        let image = try ImageTextExtractor.loadImage(at: url)
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else {
            throw DocumentIOError.corrupt("\(url.lastPathComponent) has an empty pixel size.")
        }

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
            throw DocumentIOError.corrupt("Could not create a drawing context for redaction.")
        }

        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.draw(image, in: bounds)

        // Vision normalized boxes share CoreGraphics' bottom-left origin, so
        // the box scales straight into context coordinates. Each box is
        // outset a little before painting: recognizer boxes can sit tight on
        // the glyphs, and clipped ascenders or descenders must not survive.
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        for line in lines {
            let raw = CGRect(
                x: line.normalizedBox.origin.x * CGFloat(width),
                y: line.normalizedBox.origin.y * CGFloat(height),
                width: line.normalizedBox.width * CGFloat(width),
                height: line.normalizedBox.height * CGFloat(height)
            )
            let outset = max(Self.minimumOutsetPixels, raw.height * Self.outsetFraction)
            let padded = raw.insetBy(dx: -outset, dy: -outset).intersection(bounds)
            guard !padded.isNull, !padded.isEmpty else { continue }
            context.fill(padded)
        }

        guard let redacted = context.makeImage() else {
            throw DocumentIOError.corrupt("Could not render the redacted image.")
        }

        guard let destination = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            "public.png" as CFString,
            1,
            nil
        ) else {
            throw DocumentIOError.unreadable(
                "Could not create the redacted image at \(outputURL.path)."
            )
        }
        CGImageDestinationAddImage(destination, redacted, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw DocumentIOError.unreadable(
                "Could not write the redacted image at \(outputURL.path)."
            )
        }

        return lines.count
    }

    // MARK: - Tunables

    /// Boxes grow by this fraction of their own height on every side before
    /// painting, so tight recognizer boxes cannot leave glyph edges visible.
    private static let outsetFraction: CGFloat = 0.10

    /// The outset never drops below this many pixels, so tiny boxes on small
    /// images still get a real margin.
    private static let minimumOutsetPixels: CGFloat = 2
}
