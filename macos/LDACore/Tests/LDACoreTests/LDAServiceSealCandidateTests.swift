//
//  LDAServiceSealCandidateTests.swift
//  LDACoreTests
//
//  End-to-end tests for the includeSealCandidates parameter on the standalone
//  image anonymize route: red seal candidate regions are boxed by default,
//  the flag turns the extra coverage off, and the candidate count is reported
//  on the result for the UI to surface later. Candidates are candidates:
//  nothing here asserts certain seal detection, only red-region coverage.
//
//  Tests whose names start with testOCRRoundTrip_ run live Vision, matching
//  the LDAServiceImageTests sharding convention.
//
//  House rules: all comments and strings in English (fixture content contains
//  Chinese by design). No em-dash and no en-dash-as-separator anywhere.
//

import XCTest
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
@testable import LDACore

final class LDAServiceSealCandidateTests: XCTestCase {

    private var outputDir: URL!
    private var createdURLs: [URL] = []

    override func setUpWithError() throws {
        outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lda-seal-service-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let outputDir {
            try? FileManager.default.removeItem(at: outputDir)
        }
        for url in createdURLs {
            try? FileManager.default.removeItem(at: url)
        }
        createdURLs.removeAll()
    }

    private func track(_ url: URL) -> URL {
        createdURLs.append(url)
        return url
    }

    /// The red circle stamped into the fixture, in CG bottom-left pixels.
    private static let stampCircle = CGRect(x: 1400, y: 80, width: 180, height: 180)
    private static let fixtureWidth = 1800
    private static let fixtureHeight = 500

    /// Render an OCR-able document look: black planted text lines up top and
    /// a red circular stamp shape near the bottom-right, clear of the text.
    private func makeStampedFixturePNG() throws -> URL {
        let width = Self.fixtureWidth
        let height = Self.fixtureHeight
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

        let font = CTFontCreateWithName("PingFangSC-Semibold" as CFString, 64, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        ]
        let lines = ["联系电话 13812345678", "邮箱 user@example.com"]
        for (index, text) in lines.enumerated() {
            let attributed = NSAttributedString(string: text, attributes: attributes)
            let ctLine = CTLineCreateWithAttributedString(attributed as CFAttributedString)
            context.textPosition = CGPoint(x: 80, y: CGFloat(height - 140 - index * 110))
            CTLineDraw(ctLine, context)
        }

        context.setFillColor(CGColor(red: 0.87, green: 0.17, blue: 0.15, alpha: 1))
        context.fillEllipse(in: Self.stampCircle)

        guard let image = context.makeImage() else {
            throw DocumentIOError.corrupt("test could not render the fixture image")
        }
        let url = track(
            FileManager.default.temporaryDirectory
                .appendingPathComponent("seal-service-fixture-\(UUID().uuidString).png")
        )
        try ImageFixtureRenderer.write(image: image, to: url, typeIdentifier: UTType.png.identifier)
        return url
    }

    /// Read one pixel's RGB from a PNG, addressed in CG bottom-left space.
    private func rgbAtBottomLeft(x: Int, y: Int, in url: URL) throws -> (r: Int, g: Int, b: Int) {
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

    /// By default the image route boxes seal candidate regions: the stamp
    /// area is opaque in the redacted PNG and the count is reported.
    func testOCRRoundTrip_sealCandidatesAreBoxedByDefault() throws {
        let input = try makeStampedFixturePNG()

        let result = try LDAService.anonymize(
            input: input,
            outputDir: outputDir,
            protection: .passphrase("test-passphrase"),
            createdAtISO8601: "2026-08-31T12:00:00Z"
        )

        XCTAssertGreaterThanOrEqual(result.sealCandidateCount, 1, "the stamp region must be reported")
        let redactedImageURL = try XCTUnwrap(result.redactedImageURL)
        let stampCenter = try rgbAtBottomLeft(
            x: Int(Self.stampCircle.midX),
            y: Int(Self.stampCircle.midY),
            in: redactedImageURL
        )
        XCTAssertLessThan(stampCenter.r, 60, "the stamp region must be painted opaque by default")
    }

    /// With includeSealCandidates false the stamp region stays red and the
    /// candidate count reports zero, while the OCR text channel still runs.
    func testOCRRoundTrip_sealCandidatesCanBeExcluded() throws {
        let input = try makeStampedFixturePNG()

        let result = try LDAService.anonymize(
            input: input,
            outputDir: outputDir,
            protection: .passphrase("test-passphrase"),
            createdAtISO8601: "2026-08-31T12:00:00Z",
            includeSealCandidates: false
        )

        XCTAssertEqual(result.sealCandidateCount, 0)
        let redactedImageURL = try XCTUnwrap(result.redactedImageURL)
        let stampCenter = try rgbAtBottomLeft(
            x: Int(Self.stampCircle.midX),
            y: Int(Self.stampCircle.midY),
            in: redactedImageURL
        )
        XCTAssertGreaterThan(stampCenter.r, 150, "the stamp region must stay untouched when excluded")
        XCTAssertLessThan(stampCenter.g, 120)

        // The text channel is unaffected: planted values still tokenize.
        let redactedText = try String(contentsOf: result.redactedFileURL, encoding: .utf8)
        XCTAssertFalse(
            ImageFixtureRenderer.digitsOnly(redactedText).contains("13812345678"),
            "phone leaked into redacted text"
        )
    }
}
