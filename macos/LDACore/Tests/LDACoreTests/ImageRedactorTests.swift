//
//  ImageRedactorTests.swift
//  LDACoreTests
//
//  Tests for the redacted-image renderer: range-to-observation coverage is
//  pure logic (no Vision), and the painting is verified by sampling pixels of
//  the produced PNG. Coverage policy: when ANY part of a replaced range falls
//  inside an observation line, the WHOLE line box is painted. Over-covering
//  is acceptable; under-covering is a leak.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
import CoreGraphics
import ImageIO
@testable import LDACore

final class ImageRedactorTests: XCTestCase {

    private var createdURLs: [URL] = []

    override func tearDownWithError() throws {
        for url in createdURLs {
            try? FileManager.default.removeItem(at: url)
        }
        createdURLs.removeAll()
    }

    private func track(_ url: URL) -> URL {
        createdURLs.append(url)
        return url
    }

    // MARK: - Coverage mapping (pure)

    /// Joined text "top\nphone 13812345678\nbottom": a replaced range inside
    /// the middle line covers exactly the middle line.
    func testCoverageSelectsLineIntersectingReplacedRange() {
        let lines = [
            ImageTextLine(
                text: "top",
                normalizedBox: CGRect(x: 0.1, y: 0.7, width: 0.3, height: 0.1),
                range: 0..<3
            ),
            ImageTextLine(
                text: "phone 13812345678",
                normalizedBox: CGRect(x: 0.1, y: 0.4, width: 0.6, height: 0.1),
                range: 4..<21
            ),
            ImageTextLine(
                text: "bottom",
                normalizedBox: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.1),
                range: 22..<28
            )
        ]
        // Replace just the number (10..<21): the whole middle line is covered.
        let coverage = ImageRedactor.coverage(lines: lines, replacedRanges: [10..<21])

        XCTAssertEqual(coverage.coveredLines.map { $0.text }, ["phone 13812345678"])
        XCTAssertEqual(coverage.unlocatedRangeCount, 0)
    }

    /// A range spanning a newline touches BOTH neighbouring lines: both boxes
    /// are covered, because covering only one would leak the other half.
    func testCoverageSpanningLineBreakCoversBothLines() {
        let lines = [
            ImageTextLine(
                text: "浙江杭州市西湖区",
                normalizedBox: CGRect(x: 0.1, y: 0.6, width: 0.5, height: 0.1),
                range: 0..<8
            ),
            ImageTextLine(
                text: "文一西路98号",
                normalizedBox: CGRect(x: 0.1, y: 0.4, width: 0.5, height: 0.1),
                range: 9..<16
            )
        ]
        let coverage = ImageRedactor.coverage(lines: lines, replacedRanges: [4..<12])

        XCTAssertEqual(coverage.coveredLines.count, 2)
        XCTAssertEqual(coverage.unlocatedRangeCount, 0)
    }

    /// A replaced range that intersects no observation is REPORTED, never
    /// silently dropped: the caller must surface it as an unboxed value.
    func testCoverageReportsUnlocatedRanges() {
        let lines = [
            ImageTextLine(
                text: "only line",
                normalizedBox: CGRect(x: 0.1, y: 0.4, width: 0.5, height: 0.1),
                range: 0..<9
            )
        ]
        let coverage = ImageRedactor.coverage(lines: lines, replacedRanges: [50..<60])

        XCTAssertTrue(coverage.coveredLines.isEmpty)
        XCTAssertEqual(coverage.unlocatedRangeCount, 1)
    }

    /// One line hit by several ranges is covered once, not painted twice.
    func testCoverageDeduplicatesLines() {
        let lines = [
            ImageTextLine(
                text: "a 138 b 139 c",
                normalizedBox: CGRect(x: 0.1, y: 0.4, width: 0.5, height: 0.1),
                range: 0..<13
            )
        ]
        let coverage = ImageRedactor.coverage(lines: lines, replacedRanges: [2..<5, 8..<11])

        XCTAssertEqual(coverage.coveredLines.count, 1)
    }

    // MARK: - Painting (pixel-sampled, no Vision)

    /// Painting covers the WHOLE observation box in opaque ink: pixels inside
    /// the covered box turn dark, pixels of an uncovered line stay untouched,
    /// and the output is a valid PNG of the same pixel size.
    func testRenderRedactedPNGPaintsWholeObservationBox() throws {
        // Two rendered text lines on a known canvas.
        let source = track(try ImageFixtureRenderer.writePNG(
            lines: ["SECRET TOP LINE", "SAFE BOTTOM LINE"],
            width: 800,
            fontSize: 48,
            lineHeight: 80
        ))
        let (width, height) = try Self.pixelSize(of: source)

        // Hand-crafted geometry: cover the top half band; leave the bottom.
        let coveredLine = ImageTextLine(
            text: "SECRET TOP LINE",
            normalizedBox: CGRect(x: 0.05, y: 0.55, width: 0.9, height: 0.3),
            range: 0..<15
        )

        let output = track(
            FileManager.default.temporaryDirectory
                .appendingPathComponent("redacted-\(UUID().uuidString).png")
        )
        let boxCount = try ImageRedactor.renderRedactedPNG(
            originalImageAt: source,
            covering: [coveredLine],
            to: output
        )

        XCTAssertEqual(boxCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))

        let (outWidth, outHeight) = try Self.pixelSize(of: output)
        XCTAssertEqual(outWidth, width)
        XCTAssertEqual(outHeight, height)

        // Sample the center of the covered box: must be painted (dark).
        // Normalized origin is bottom-left; pixel rows count from the top.
        let coveredCenterX = Int((0.05 + 0.9 / 2) * Double(width))
        let coveredCenterY = height - Int((0.55 + 0.3 / 2) * Double(height))
        let painted = try Self.rgb(at: coveredCenterX, coveredCenterY, in: output)
        XCTAssertLessThan(painted.r, 60, "covered box center must be painted dark")
        XCTAssertLessThan(painted.g, 60)
        XCTAssertLessThan(painted.b, 60)

        // Sample a point well below the covered band: must stay white.
        let safeY = height - Int(0.1 * Double(height))
        let untouched = try Self.rgb(at: width / 2, safeY, in: output)
        XCTAssertGreaterThan(untouched.r, 200, "uncovered area must stay untouched")
        XCTAssertGreaterThan(untouched.g, 200)
        XCTAssertGreaterThan(untouched.b, 200)

        // The redacted file must differ from the source bytes.
        XCTAssertNotEqual(try Data(contentsOf: source), try Data(contentsOf: output))
    }

    /// With nothing to cover the renderer still writes a faithful copy, so the
    /// caller always gets the promised artifact pair.
    func testRenderRedactedPNGWithNoBoxesWritesCopy() throws {
        let source = track(try ImageFixtureRenderer.writePNG(
            lines: ["NOTHING TO HIDE"],
            width: 600,
            fontSize: 40,
            lineHeight: 70
        ))
        let output = track(
            FileManager.default.temporaryDirectory
                .appendingPathComponent("redacted-\(UUID().uuidString).png")
        )

        let boxCount = try ImageRedactor.renderRedactedPNG(
            originalImageAt: source,
            covering: [],
            to: output
        )

        XCTAssertEqual(boxCount, 0)
        let (sw, sh) = try Self.pixelSize(of: source)
        let (ow, oh) = try Self.pixelSize(of: output)
        XCTAssertEqual(sw, ow)
        XCTAssertEqual(sh, oh)
    }

    // MARK: - Pixel helpers

    private static func loadImage(_ url: URL) throws -> CGImage {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            throw DocumentIOError.unreadable("test could not reopen \(url.path)")
        }
        return image
    }

    private static func pixelSize(of url: URL) throws -> (Int, Int) {
        let image = try loadImage(url)
        return (image.width, image.height)
    }

    /// Read one pixel's RGB by drawing the image into a known-format context.
    private static func rgb(at x: Int, _ y: Int, in url: URL) throws -> (r: Int, g: Int, b: Int) {
        let image = try loadImage(url)
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw DocumentIOError.unreadable("test could not create sampling context")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        // The buffer's row 0 is the TOP row of the image.
        let clampedX = min(max(x, 0), width - 1)
        let clampedY = min(max(y, 0), height - 1)
        let offset = (clampedY * width + clampedX) * 4
        return (Int(pixels[offset]), Int(pixels[offset + 1]), Int(pixels[offset + 2]))
    }
}
