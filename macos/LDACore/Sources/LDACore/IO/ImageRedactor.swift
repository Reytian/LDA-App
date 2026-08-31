//
//  ImageRedactor.swift
//  LDACore
//
//  Renders the redacted IMAGE artifact for standalone image input: a copy of
//  the source raster with opaque boxes painted over every OCR observation
//  that carries a replaced character range, plus any red-region seal
//  CANDIDATE boxes the caller passes in (candidates only, never certain
//  detections). Coverage policy is conservative: when ANY part of a replaced
//  range falls inside an observation line, the WHOLE line box is painted, and
//  a candidate overlapping a line box is merged into it rather than painted
//  twice. Over-covering is acceptable; under-covering is a leak. Boxes are
//  destructive by design, so an image artifact is never restorable; restore
//  lives on the paired redacted TEXT artifact.
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

    /// The outcome of one redacted render: how many boxes were painted in
    /// total, and how many seal CANDIDATE regions were merged into the
    /// covering set (so the UI can report "N seal candidates boxed" later).
    public struct RenderedRedaction: Sendable, Equatable {
        /// Every rect painted, OCR line boxes and standalone candidates alike.
        public var paintedBoxCount: Int
        /// The candidate regions included in the painting, whether merged
        /// into an overlapping line box or painted as their own box.
        public var sealCandidateCount: Int

        public init(paintedBoxCount: Int, sealCandidateCount: Int) {
            self.paintedBoxCount = paintedBoxCount
            self.sealCandidateCount = sealCandidateCount
        }
    }

    /// Paint opaque boxes over the covered lines and write the result as a
    /// PNG. Returns the number of boxes painted. This candidate-free entry
    /// point keeps the historical behavior byte-for-byte for callers that do
    /// not carry seal candidates.
    @discardableResult
    public static func renderRedactedPNG(
        originalImageAt url: URL,
        covering lines: [ImageTextLine],
        to outputURL: URL
    ) throws -> Int {
        try renderRedactedPNG(
            originalImageAt: url,
            covering: lines,
            sealCandidates: [],
            to: outputURL
        ).paintedBoxCount
    }

    /// Paint opaque boxes over the covered lines PLUS the given seal
    /// candidate boxes, and write the result as a PNG. A candidate that
    /// overlaps a line box is merged into it, never double-painted. With an
    /// empty cover list the output is still written (a faithful re-encoded
    /// copy), so the artifact pair promised by anonymize always exists.
    ///
    /// - Parameter sealCandidates: candidate regions as Vision-style
    ///   normalized rects (origin bottom-left), typically from
    ///   SealCandidateDetector. Candidates already carry their own coverage
    ///   outset, so no additional padding is applied here.
    @discardableResult
    public static func renderRedactedPNG(
        originalImageAt url: URL,
        covering lines: [ImageTextLine],
        sealCandidates: [CGRect],
        to outputURL: URL
    ) throws -> RenderedRedaction {
        let image = try ImageTextExtractor.loadImage(at: url)
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else {
            throw DocumentIOError.corrupt("\(url.lastPathComponent) has an empty pixel size.")
        }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)

        let lineRects = paddedLineRects(for: lines, width: width, height: height, bounds: bounds)
        let merged = merge(
            candidates: sealCandidates,
            intoLineRects: lineRects,
            width: width,
            height: height,
            bounds: bounds
        )
        try paint(rects: merged.rects, over: image, bounds: bounds, to: outputURL)
        return RenderedRedaction(
            paintedBoxCount: merged.rects.count,
            sealCandidateCount: merged.candidateCount
        )
    }

    /// Scale each covered line's normalized box into pixel space and outset
    /// it. Vision normalized boxes share CoreGraphics' bottom-left origin, so
    /// the box scales straight into context coordinates. Each box is outset a
    /// little before painting: recognizer boxes can sit tight on the glyphs,
    /// and clipped ascenders or descenders must not survive.
    private static func paddedLineRects(
        for lines: [ImageTextLine],
        width: Int,
        height: Int,
        bounds: CGRect
    ) -> [CGRect] {
        lines.compactMap { line in
            let raw = CGRect(
                x: line.normalizedBox.origin.x * CGFloat(width),
                y: line.normalizedBox.origin.y * CGFloat(height),
                width: line.normalizedBox.width * CGFloat(width),
                height: line.normalizedBox.height * CGFloat(height)
            )
            let outset = max(Self.minimumOutsetPixels, raw.height * Self.outsetFraction)
            let padded = raw.insetBy(dx: -outset, dy: -outset).intersection(bounds)
            guard !padded.isNull, !padded.isEmpty else { return nil }
            return padded
        }
    }

    /// Fold the candidate boxes into the covering set. A candidate that
    /// intersects a line box is unioned into that box (merged, not
    /// double-painted); a disjoint candidate becomes its own box. Returns the
    /// final rects plus how many candidates entered the set.
    private static func merge(
        candidates: [CGRect],
        intoLineRects lineRects: [CGRect],
        width: Int,
        height: Int,
        bounds: CGRect
    ) -> (rects: [CGRect], candidateCount: Int) {
        var rects = lineRects
        var candidateCount = 0
        for normalized in candidates {
            let raw = CGRect(
                x: normalized.origin.x * CGFloat(width),
                y: normalized.origin.y * CGFloat(height),
                width: normalized.width * CGFloat(width),
                height: normalized.height * CGFloat(height)
            )
            let clipped = raw.intersection(bounds)
            guard !clipped.isNull, !clipped.isEmpty else { continue }
            candidateCount += 1
            if let index = rects.firstIndex(where: { $0.intersects(clipped) }) {
                rects[index] = rects[index].union(clipped).intersection(bounds)
            } else {
                rects.append(clipped)
            }
        }
        return (rects, candidateCount)
    }

    /// Draw the source image, fill the given rects in opaque ink, and write
    /// the result as a PNG at the output URL.
    private static func paint(
        rects: [CGRect],
        over image: CGImage,
        bounds: CGRect,
        to outputURL: URL
    ) throws {
        guard let context = CGContext(
            data: nil,
            width: Int(bounds.width),
            height: Int(bounds.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw DocumentIOError.corrupt("Could not create a drawing context for redaction.")
        }
        context.draw(image, in: bounds)
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        for rect in rects {
            context.fill(rect)
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
    }

    // MARK: - Tunables

    /// Boxes grow by this fraction of their own height on every side before
    /// painting, so tight recognizer boxes cannot leave glyph edges visible.
    private static let outsetFraction: CGFloat = 0.10

    /// The outset never drops below this many pixels, so tiny boxes on small
    /// images still get a real margin.
    private static let minimumOutsetPixels: CGFloat = 2
}
