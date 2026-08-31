//
//  SealCandidateDetectorTests.swift
//  LDACoreTests
//
//  Tests for the red-region seal candidate detector and its merge into the
//  image redactor's covering boxes. Fixtures are generated in code with
//  CoreGraphics, so no image files are checked into the repository. The
//  detector emits CANDIDATES only: over-covering is acceptable, and nothing
//  here claims certain seal detection.
//
//  House rules: all comments and strings in English (fixture CONTENT may be
//  Chinese). No em-dash and no en-dash-as-separator anywhere.
//

import XCTest
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
@testable import LDACore

final class SealCandidateDetectorTests: XCTestCase {

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

    // MARK: - Fixture builders (CoreGraphics, in code)

    /// A typical PRC seal ink red.
    private static let sealRed = CGColor(red: 0.87, green: 0.17, blue: 0.15, alpha: 1)

    private func makeContext(width: Int, height: Int) throws -> CGContext {
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
            throw DocumentIOError.corrupt("test could not create a fixture context")
        }
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context
    }

    private func image(from context: CGContext) throws -> CGImage {
        guard let image = context.makeImage() else {
            throw DocumentIOError.corrupt("test could not render a fixture image")
        }
        return image
    }

    /// White background with one red filled circle, in CG bottom-left space.
    private func redCircleImage(
        width: Int,
        height: Int,
        circle: CGRect
    ) throws -> CGImage {
        let context = try makeContext(width: width, height: height)
        context.setFillColor(Self.sealRed)
        context.fillEllipse(in: circle)
        return try image(from: context)
    }

    /// A red-header document look: a red horizontal rule plus a red title
    /// line, with NO seal anywhere.
    private func redHeaderImage(width: Int, height: Int) throws -> (CGImage, CGRect) {
        let context = try makeContext(width: width, height: height)
        context.setFillColor(Self.sealRed)
        let rule = CGRect(x: 80, y: CGFloat(height) - 140, width: CGFloat(width) - 160, height: 10)
        context.fill(rule)

        let font = CTFontCreateWithName("PingFangSC-Semibold" as CFString, 56, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: Self.sealRed
        ]
        let attributed = NSAttributedString(string: "红头文件标题", attributes: attributes)
        let line = CTLineCreateWithAttributedString(attributed as CFAttributedString)
        context.textPosition = CGPoint(x: 80, y: CGFloat(height) - 100)
        CTLineDraw(line, context)
        return (try image(from: context), rule)
    }

    private func writePNG(_ image: CGImage) throws -> URL {
        let url = track(
            FileManager.default.temporaryDirectory
                .appendingPathComponent("seal-candidate-\(UUID().uuidString).png")
        )
        try ImageFixtureRenderer.write(image: image, to: url, typeIdentifier: UTType.png.identifier)
        return url
    }

    /// Convert a normalized (bottom-left) rect to a pixel rect in the same
    /// bottom-left space.
    private func pixelRect(_ normalized: CGRect, width: Int, height: Int) -> CGRect {
        CGRect(
            x: normalized.origin.x * CGFloat(width),
            y: normalized.origin.y * CGFloat(height),
            width: normalized.width * CGFloat(width),
            height: normalized.height * CGFloat(height)
        )
    }

    /// Read one pixel's RGB from a written PNG. Buffer row 0 is the image top,
    /// so a CG bottom-left y is flipped here.
    private func rgbAtBottomLeft(
        x: Int,
        y: Int,
        in url: URL
    ) throws -> (r: Int, g: Int, b: Int) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw DocumentIOError.unreadable("test could not reopen \(url.path)")
        }
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
            throw DocumentIOError.unreadable("test could not create a sampling context")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let row = min(max(height - 1 - y, 0), height - 1)
        let column = min(max(x, 0), width - 1)
        let offset = (row * width + column) * 4
        return (Int(pixels[offset]), Int(pixels[offset + 1]), Int(pixels[offset + 2]))
    }

    // MARK: - Red predicate

    /// The red-dominance predicate accepts seal reds and rejects page tones.
    func testSealRedPredicate() {
        XCTAssertTrue(SealCandidateDetector.isSealRed(r: 222, g: 43, b: 38, a: 255), "seal red")
        XCTAssertTrue(SealCandidateDetector.isSealRed(r: 200, g: 130, b: 125, a: 255), "faded seal red")
        XCTAssertFalse(SealCandidateDetector.isSealRed(r: 255, g: 255, b: 255, a: 255), "white paper")
        XCTAssertFalse(SealCandidateDetector.isSealRed(r: 40, g: 40, b: 40, a: 255), "black ink")
        XCTAssertFalse(SealCandidateDetector.isSealRed(r: 255, g: 215, b: 210, a: 255), "pale pink wash")
        XCTAssertFalse(SealCandidateDetector.isSealRed(r: 222, g: 43, b: 38, a: 40), "transparent red")
    }

    // MARK: - Fixture (a): red circle

    /// A white background with one red filled circle yields exactly one
    /// candidate whose box covers every red pixel, and exporting with that
    /// candidate paints the region opaque.
    func testRedCircleYieldsOneCoveringCandidate() throws {
        let width = 900
        let height = 600
        let circle = CGRect(x: 370, y: 220, width: 160, height: 160)
        let fixture = try redCircleImage(width: width, height: height, circle: circle)

        let candidates = try SealCandidateDetector.candidates(in: fixture)
        XCTAssertEqual(candidates.count, 1, "one red cluster must yield one candidate")

        let box = pixelRect(candidates[0], width: width, height: height)
        XCTAssertTrue(
            box.contains(circle),
            "candidate \(box) must cover every red pixel of \(circle)"
        )

        // Export through the box redactor: the candidate region turns opaque.
        let source = try writePNG(fixture)
        let output = track(
            FileManager.default.temporaryDirectory
                .appendingPathComponent("seal-redacted-\(UUID().uuidString).png")
        )
        let render = try ImageRedactor.renderRedactedPNG(
            originalImageAt: source,
            covering: [],
            sealCandidates: candidates,
            to: output
        )
        XCTAssertEqual(render.paintedBoxCount, 1)
        XCTAssertEqual(render.sealCandidateCount, 1)

        let center = try rgbAtBottomLeft(x: 450, y: 300, in: output)
        XCTAssertLessThan(center.r, 60, "candidate region must be painted opaque")
        XCTAssertLessThan(center.g, 60)
        XCTAssertLessThan(center.b, 60)

        let corner = try rgbAtBottomLeft(x: 20, y: 20, in: output)
        XCTAssertGreaterThan(corner.r, 200, "untouched area must stay white")
    }

    // MARK: - Fixture (b): red header, no seal

    /// A red rule and red title text ARE candidates (over-covering is
    /// acceptable), and leaving candidates out of the render, which is what
    /// includeSealCandidates=false does at the entry point, leaves the red
    /// header unpainted.
    func testRedHeaderCandidatesAreSkippableAtRender() throws {
        let width = 1200
        let height = 800
        let (fixture, rule) = try redHeaderImage(width: width, height: height)

        let candidates = try SealCandidateDetector.candidates(in: fixture)
        XCTAssertFalse(candidates.isEmpty, "red header regions must surface as candidates")

        let source = try writePNG(fixture)
        let ruleCenterX = Int(rule.midX)
        let ruleCenterY = Int(rule.midY)

        // Candidates omitted: the header stays red in the export.
        let untouchedOutput = track(
            FileManager.default.temporaryDirectory
                .appendingPathComponent("seal-off-\(UUID().uuidString).png")
        )
        let offRender = try ImageRedactor.renderRedactedPNG(
            originalImageAt: source,
            covering: [],
            sealCandidates: [],
            to: untouchedOutput
        )
        XCTAssertEqual(offRender.paintedBoxCount, 0)
        XCTAssertEqual(offRender.sealCandidateCount, 0)
        let untouched = try rgbAtBottomLeft(x: ruleCenterX, y: ruleCenterY, in: untouchedOutput)
        XCTAssertGreaterThan(untouched.r, 150, "the rule must stay red when candidates are omitted")
        XCTAssertLessThan(untouched.g, 120)

        // Candidates included: the same pixel is painted opaque.
        let paintedOutput = track(
            FileManager.default.temporaryDirectory
                .appendingPathComponent("seal-on-\(UUID().uuidString).png")
        )
        let onRender = try ImageRedactor.renderRedactedPNG(
            originalImageAt: source,
            covering: [],
            sealCandidates: candidates,
            to: paintedOutput
        )
        XCTAssertEqual(onRender.sealCandidateCount, candidates.count)
        let painted = try rgbAtBottomLeft(x: ruleCenterX, y: ruleCenterY, in: paintedOutput)
        XCTAssertLessThan(painted.r, 60)
    }

    // MARK: - Fixture (c): large image with no red

    /// A plain 3000x2000 bitmap with zero red pixels yields zero candidates
    /// and completes in under a second.
    func testLargePlainImageYieldsNothingFast() throws {
        let context = try makeContext(width: 3000, height: 2000)
        let fixture = try image(from: context)

        let started = Date()
        let candidates = try SealCandidateDetector.candidates(in: fixture)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertTrue(candidates.isEmpty)
        XCTAssertLessThan(elapsed, 1.0, "the scan must stay fast on large red-free images")
    }

    // MARK: - Size threshold

    /// Specks below the minimum size threshold are noise, not candidates.
    func testTinyRedSpeckIsFiltered() throws {
        let context = try makeContext(width: 800, height: 600)
        context.setFillColor(Self.sealRed)
        context.fill(CGRect(x: 400, y: 300, width: 6, height: 6))
        let fixture = try image(from: context)

        let candidates = try SealCandidateDetector.candidates(in: fixture)
        XCTAssertTrue(candidates.isEmpty, "a 6 pixel speck must not become a candidate")
    }

    // MARK: - Merge with OCR boxes

    /// A candidate overlapping an OCR line box is merged into it, never
    /// double-painted: one box paints, and it covers the union.
    func testOverlappingCandidateAndLineBoxMergeIntoOne() throws {
        let width = 900
        let height = 600
        let circle = CGRect(x: 370, y: 220, width: 160, height: 160)
        let fixture = try redCircleImage(width: width, height: height, circle: circle)
        let source = try writePNG(fixture)
        let candidates = try SealCandidateDetector.candidates(in: fixture)
        XCTAssertEqual(candidates.count, 1)

        // A line box overlapping the circle's left half.
        let line = ImageTextLine(
            text: "盖章处",
            normalizedBox: CGRect(x: 0.30, y: 0.40, width: 0.15, height: 0.15),
            range: 0..<3
        )
        let output = track(
            FileManager.default.temporaryDirectory
                .appendingPathComponent("seal-merge-\(UUID().uuidString).png")
        )
        let render = try ImageRedactor.renderRedactedPNG(
            originalImageAt: source,
            covering: [line],
            sealCandidates: candidates,
            to: output
        )
        XCTAssertEqual(render.paintedBoxCount, 1, "overlapping boxes must merge, not double-paint")
        XCTAssertEqual(render.sealCandidateCount, 1)

        // Both the line region and the candidate region are painted.
        let lineCenter = try rgbAtBottomLeft(x: Int(0.375 * Double(width)), y: Int(0.475 * Double(height)), in: output)
        XCTAssertLessThan(lineCenter.r, 60)
        let circleCenter = try rgbAtBottomLeft(x: 450, y: 300, in: output)
        XCTAssertLessThan(circleCenter.r, 60)
    }

    /// A candidate clear of every line box paints as its own box.
    func testDisjointCandidatePaintsAsOwnBox() throws {
        let width = 900
        let height = 600
        let circle = CGRect(x: 640, y: 60, width: 120, height: 120)
        let fixture = try redCircleImage(width: width, height: height, circle: circle)
        let source = try writePNG(fixture)
        let candidates = try SealCandidateDetector.candidates(in: fixture)
        XCTAssertEqual(candidates.count, 1)

        let line = ImageTextLine(
            text: "标题",
            normalizedBox: CGRect(x: 0.05, y: 0.85, width: 0.3, height: 0.08),
            range: 0..<2
        )
        let output = track(
            FileManager.default.temporaryDirectory
                .appendingPathComponent("seal-disjoint-\(UUID().uuidString).png")
        )
        let render = try ImageRedactor.renderRedactedPNG(
            originalImageAt: source,
            covering: [line],
            sealCandidates: candidates,
            to: output
        )
        XCTAssertEqual(render.paintedBoxCount, 2)
        XCTAssertEqual(render.sealCandidateCount, 1)
    }

    /// The single-return legacy entry point stays candidate-free, so existing
    /// callers keep byte-for-byte behavior.
    func testLegacyRenderSignatureIsCandidateFree() throws {
        let width = 900
        let height = 600
        let circle = CGRect(x: 370, y: 220, width: 160, height: 160)
        let fixture = try redCircleImage(width: width, height: height, circle: circle)
        let source = try writePNG(fixture)
        let output = track(
            FileManager.default.temporaryDirectory
                .appendingPathComponent("seal-legacy-\(UUID().uuidString).png")
        )

        let painted = try ImageRedactor.renderRedactedPNG(
            originalImageAt: source,
            covering: [],
            to: output
        )
        XCTAssertEqual(painted, 0)
        let center = try rgbAtBottomLeft(x: 450, y: 300, in: output)
        XCTAssertGreaterThan(center.r, 150, "legacy path must not paint candidates")
    }
}
