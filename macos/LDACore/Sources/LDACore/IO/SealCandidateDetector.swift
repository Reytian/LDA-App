//
//  SealCandidateDetector.swift
//  LDACore
//
//  Finds red-region CANDIDATE boxes in a standalone image raster: connected
//  clusters of red-dominant pixels in the typical PRC seal ink range. These
//  are candidates only, never certain seal detections; the philosophy of the
//  image channel applies (over-covering is acceptable, under-covering is a
//  leak), so a red header rule or red title text becoming a candidate is the
//  accepted failure direction.
//
//  Pure over the decoded bitmap: the image is rasterized once into a known
//  RGBA8 layout (downsampled by a bounded factor so large rasters stay fast),
//  thresholded into a red mask, grouped into connected components, and mapped
//  back to Vision-style normalized rects (origin bottom-left, 0 through 1),
//  the same convention ImageTextLine boxes use, so the redactor can merge
//  candidate and OCR boxes in one space.
//
//  CoreGraphics and ImageIO only: no UI frameworks and no Vision in LDACore
//  beyond the existing OCR extractor.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import Foundation
import CoreGraphics
import ImageIO

public enum SealCandidateDetector {

    // MARK: - Tunables

    /// The scan raster never exceeds this dimension: larger images are
    /// downsampled before thresholding, which bounds the pixel walk and keeps
    /// candidate scanning fast on multi-megapixel scans.
    static let maxScanDimension = 1000

    /// Red channel floor for a candidate pixel. Seal ink is saturated; page
    /// tones and shadows sit below this.
    static let minRedChannel = 130

    /// How far the red channel must lead BOTH green and blue. Faded seal red
    /// keeps a strong lead; pale pink washes and warm paper do not.
    static let minRedLead = 50

    /// Alpha floor before unpremultiplying color channels. Pixels below one
    /// quarter opacity are too faint to treat as visible ink.
    static let minAlpha = 64

    /// Minimum size of a candidate cluster, in ORIGINAL pixels, measured on
    /// the larger bounding-box dimension. Keeps specks and bullet dots out
    /// while a thin red rule (long but short) still qualifies.
    static let minCandidateExtent: CGFloat = 24

    /// Minimum red pixel area of a candidate cluster, in ORIGINAL pixel
    /// terms. A second guard against isolated noise.
    static let minCandidateArea: CGFloat = 64

    /// The candidate bounds grow by this many SCAN pixels on every side
    /// before mapping back, so red edge pixels diluted below the threshold by
    /// downsampling stay covered (over-covering is acceptable).
    static let boundsOutsetScanPixels: CGFloat = 2

    // MARK: - Public API

    /// Scan the image for red-region seal candidates.
    ///
    /// - Parameter image: the decoded source raster.
    /// - Returns: candidate boxes as Vision-style normalized rects (origin
    ///   bottom-left, 0 through 1). Intersecting candidates are merged, so
    ///   the returned rects are pairwise disjoint.
    /// - Throws: DocumentIOError.corrupt when a scan context cannot be
    ///   created, so a failed scan is never silently reported as "no
    ///   candidates".
    public static func candidates(in image: CGImage) throws -> [CGRect] {
        let bitmap = try rasterize(image)
        let mask = redMask(of: bitmap)
        let connectivity = connectivityMask(
            from: mask,
            width: bitmap.width,
            height: bitmap.height
        )
        let clusters = components(
            in: connectivity,
            sourceMask: mask,
            width: bitmap.width,
            height: bitmap.height
        )
        let rects = clusters.compactMap { cluster in
            candidateRect(
                for: cluster,
                bitmap: bitmap,
                originalWidth: image.width,
                originalHeight: image.height
            )
        }
        return mergeIntersecting(rects)
    }

    /// Scan an image FILE for red-region seal candidates.
    ///
    /// The decoding entry point is internal to this module, so callers outside
    /// LDACore (the GUI export path) reach the scan through this convenience
    /// rather than decoding a raster themselves.
    ///
    /// - Throws: DocumentIOError when the file cannot be decoded, and whatever
    ///   candidates(in:) throws, so a failed scan is never silently reported
    ///   as "no candidates".
    public static func candidates(inImageAt url: URL) throws -> [CGRect] {
        try candidates(in: ImageTextExtractor.loadImage(at: url))
    }

    /// The red-dominance predicate on premultiplied RGBA8 channel values.
    /// Color is normalized before applying the seal-ink thresholds so visible
    /// alpha-blended seals are judged by their ink color, not their opacity.
    /// Internal so the threshold is testable directly.
    static func isSealRed(r: Int, g: Int, b: Int, a: Int) -> Bool {
        guard a >= minAlpha else { return false }
        let halfAlpha = a / 2
        let normalizedRed = min(255, (r * 255 + halfAlpha) / a)
        let normalizedGreen = min(255, (g * 255 + halfAlpha) / a)
        let normalizedBlue = min(255, (b * 255 + halfAlpha) / a)
        return normalizedRed >= minRedChannel
            && normalizedRed - normalizedGreen >= minRedLead
            && normalizedRed - normalizedBlue >= minRedLead
    }

    // MARK: - Rasterization

    /// The scan raster: RGBA8 bytes plus the geometry needed to map scan
    /// coordinates back to original pixels.
    private struct ScanBitmap {
        var pixels: [UInt8]
        var width: Int
        var height: Int
        var bytesPerRow: Int
    }

    /// Draw the image into a known RGBA8 layout, downsampled so the larger
    /// dimension never exceeds maxScanDimension. Buffer row 0 is the image
    /// top, the CGBitmapContext memory convention.
    private static func rasterize(_ image: CGImage) throws -> ScanBitmap {
        let originalWidth = image.width
        let originalHeight = image.height
        guard originalWidth > 0, originalHeight > 0 else {
            throw DocumentIOError.corrupt("The image has an empty pixel size.")
        }

        let largest = max(originalWidth, originalHeight)
        let downscale = largest > maxScanDimension
            ? CGFloat(largest) / CGFloat(maxScanDimension)
            : 1
        let width = max(1, Int((CGFloat(originalWidth) / downscale).rounded()))
        let height = max(1, Int((CGFloat(originalHeight) / downscale).rounded()))
        let bytesPerRow = width * 4

        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return false
            }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else {
            throw DocumentIOError.corrupt(
                "Could not create a scan context for seal candidate detection."
            )
        }
        return ScanBitmap(pixels: pixels, width: width, height: height, bytesPerRow: bytesPerRow)
    }

    // MARK: - Threshold and components

    /// Threshold the bitmap into a red mask, indexed [y * width + x].
    private static func redMask(of bitmap: ScanBitmap) -> [Bool] {
        var mask = [Bool](repeating: false, count: bitmap.width * bitmap.height)
        bitmap.pixels.withUnsafeBufferPointer { buffer in
            for y in 0..<bitmap.height {
                let rowStart = y * bitmap.bytesPerRow
                for x in 0..<bitmap.width {
                    let offset = rowStart + x * 4
                    let accepted = isSealRed(
                        r: Int(buffer[offset]),
                        g: Int(buffer[offset + 1]),
                        b: Int(buffer[offset + 2]),
                        a: Int(buffer[offset + 3])
                    )
                    if accepted {
                        mask[y * bitmap.width + x] = true
                    }
                }
            }
        }
        return mask
    }

    /// Grow each accepted pixel by one scan pixel in every direction. Printed
    /// halftones often contain a clear pixel between adjacent ink cells, so
    /// connectivity uses this mask while candidate area still counts only the
    /// accepted red pixels in the source mask.
    private static func connectivityMask(
        from sourceMask: [Bool],
        width: Int,
        height: Int
    ) -> [Bool] {
        var connected = sourceMask
        for index in sourceMask.indices where sourceMask[index] {
            let x = index % width
            let y = index / width
            let minX = max(0, x - 1)
            let maxX = min(width - 1, x + 1)
            let minY = max(0, y - 1)
            let maxY = min(height - 1, y + 1)
            for neighborY in minY...maxY {
                for neighborX in minX...maxX {
                    connected[neighborY * width + neighborX] = true
                }
            }
        }
        return connected
    }

    /// One connected red cluster, in scan coordinates (row 0 is the top).
    private struct Cluster {
        var minX: Int
        var maxX: Int
        var minY: Int
        var maxY: Int
        var pixelCount: Int
    }

    /// Group the connectivity mask into 8-connected components with an
    /// iterative flood fill. Only source-mask pixels contribute to area, so
    /// the one-pixel bridge cannot promote an isolated speck by itself.
    private static func components(
        in connectivityMask: [Bool],
        sourceMask: [Bool],
        width: Int,
        height: Int
    ) -> [Cluster] {
        var visited = [Bool](repeating: false, count: connectivityMask.count)
        var clusters: [Cluster] = []
        var stack: [Int] = []

        for start in 0..<connectivityMask.count
        where connectivityMask[start] && !visited[start] {
            var cluster = Cluster(
                minX: start % width, maxX: start % width,
                minY: start / width, maxY: start / width,
                pixelCount: 0
            )
            visited[start] = true
            stack.removeAll(keepingCapacity: true)
            stack.append(start)

            while let index = stack.popLast() {
                let x = index % width
                let y = index / width
                if sourceMask[index] {
                    cluster.pixelCount += 1
                }
                cluster.minX = min(cluster.minX, x)
                cluster.maxX = max(cluster.maxX, x)
                cluster.minY = min(cluster.minY, y)
                cluster.maxY = max(cluster.maxY, y)

                if x > 0, connectivityMask[index - 1], !visited[index - 1] {
                    visited[index - 1] = true
                    stack.append(index - 1)
                }
                if x < width - 1,
                   connectivityMask[index + 1],
                   !visited[index + 1] {
                    visited[index + 1] = true
                    stack.append(index + 1)
                }
                if y > 0,
                   connectivityMask[index - width],
                   !visited[index - width] {
                    visited[index - width] = true
                    stack.append(index - width)
                }
                if y < height - 1,
                   connectivityMask[index + width],
                   !visited[index + width] {
                    visited[index + width] = true
                    stack.append(index + width)
                }
                if x > 0, y > 0,
                   connectivityMask[index - width - 1],
                   !visited[index - width - 1] {
                    visited[index - width - 1] = true
                    stack.append(index - width - 1)
                }
                if x < width - 1, y > 0,
                   connectivityMask[index - width + 1],
                   !visited[index - width + 1] {
                    visited[index - width + 1] = true
                    stack.append(index - width + 1)
                }
                if x > 0, y < height - 1,
                   connectivityMask[index + width - 1],
                   !visited[index + width - 1] {
                    visited[index + width - 1] = true
                    stack.append(index + width - 1)
                }
                if x < width - 1, y < height - 1,
                   connectivityMask[index + width + 1],
                   !visited[index + width + 1] {
                    visited[index + width + 1] = true
                    stack.append(index + width + 1)
                }
            }
            clusters.append(cluster)
        }
        return clusters
    }

    // MARK: - Mapping back

    /// Turn one cluster into a normalized candidate rect, or nil when it is
    /// below the minimum size thresholds. Bounds are outset in scan space and
    /// clamped to the unit square.
    private static func candidateRect(
        for cluster: Cluster,
        bitmap: ScanBitmap,
        originalWidth: Int,
        originalHeight: Int
    ) -> CGRect? {
        let scaleX = CGFloat(originalWidth) / CGFloat(bitmap.width)
        let scaleY = CGFloat(originalHeight) / CGFloat(bitmap.height)

        let boxWidth = CGFloat(cluster.maxX - cluster.minX + 1) * scaleX
        let boxHeight = CGFloat(cluster.maxY - cluster.minY + 1) * scaleY
        let area = CGFloat(cluster.pixelCount) * scaleX * scaleY
        guard max(boxWidth, boxHeight) >= minCandidateExtent, area >= minCandidateArea else {
            return nil
        }

        let outset = boundsOutsetScanPixels
        let left = (CGFloat(cluster.minX) - outset) * scaleX
        let right = (CGFloat(cluster.maxX + 1) + outset) * scaleX
        let top = (CGFloat(cluster.minY) - outset) * scaleY
        let bottom = (CGFloat(cluster.maxY + 1) + outset) * scaleY

        // Scan rows count from the top; normalized boxes originate bottom-left.
        let normMinX = max(0, left / CGFloat(originalWidth))
        let normMaxX = min(1, right / CGFloat(originalWidth))
        let normTop = max(0, top / CGFloat(originalHeight))
        let normBottom = min(1, bottom / CGFloat(originalHeight))
        return CGRect(
            x: normMinX,
            y: 1 - normBottom,
            width: normMaxX - normMinX,
            height: normBottom - normTop
        )
    }

    /// Union intersecting rects until the set is pairwise disjoint, so a
    /// hollow ring and its inner emblem report as one candidate.
    static func mergeIntersecting(_ rects: [CGRect]) -> [CGRect] {
        var merged = rects
        var didMerge = true
        while didMerge {
            didMerge = false
            outer: for i in 0..<merged.count {
                for j in (i + 1)..<merged.count where merged[i].intersects(merged[j]) {
                    merged[i] = merged[i].union(merged[j])
                    merged.remove(at: j)
                    didMerge = true
                    break outer
                }
            }
        }
        return merged
    }
}
