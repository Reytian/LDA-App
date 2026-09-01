//
//  ImageTextExtractorTests.swift
//  LDACoreTests
//
//  Tests for the standalone image import path (png / jpg / jpeg). Fixtures are
//  synthesized per test by ImageFixtureRenderer and run through REAL Vision
//  OCR; assertions tolerate OCR noise by comparing digit runs rather than
//  exact strings. Tests whose names start with testOCRRoundTrip_ run live
//  Vision and are the slow ones, so a future CI split can shard on the name.
//
//  House rules: all comments and strings in English (fixture content contains
//  Chinese by design). No em-dash and no en-dash-as-separator anywhere.
//

import XCTest
import CoreGraphics
@testable import LDACore

final class ImageTextExtractorTests: XCTestCase {

    // The planted values the OCR round trip must recover. The ID number is
    // ISO-7064 checksum valid so the deterministic engine will accept it.
    static let plantedPhone = "13812345678"
    static let plantedID = "110101199003074514"
    static let plantedEmail = "zhangwei@example.com"
    // Halfwidth parentheses are legal input to the detector and avoid a
    // known Vision ambiguity between fullwidth parentheses and CJK glyphs.
    static let plantedCaseNumber = "(2026)粤03民初12345号"

    static let fixtureLines = [
        "民事起诉状",
        "原告：张伟，电话\(plantedPhone)",
        "身份证号码\(plantedID)",
        "邮箱 \(plantedEmail)",
        "案号: \(plantedCaseNumber)"
    ]

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

    // MARK: - Recognition (live Vision)

    /// The core extraction test: a synthesized PNG with mixed Chinese legal
    /// text must OCR into text carrying the planted values (digit-run
    /// comparison for the numeric ones), with per-line geometry that maps
    /// every line back into the joined text.
    func testOCRRoundTrip_extractRecoversPlantedValuesFromPNG() throws {
        let url = track(try ImageFixtureRenderer.writePNG(lines: Self.fixtureLines))

        let extraction = try ImageTextExtractor().extract(url)

        XCTAssertFalse(
            extraction.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "OCR returned no text for the synthetic image. Vision may be "
                + "unavailable in this environment; this test cannot pass without it."
        )

        // Numeric values: compare digit runs so OCR punctuation drift cannot
        // produce a false failure.
        let digits = ImageFixtureRenderer.digitsOnly(extraction.text)
        XCTAssertTrue(digits.contains(Self.plantedPhone), "phone missing from OCR text: \(extraction.text)")
        XCTAssertTrue(digits.contains(Self.plantedID), "ID missing from OCR text: \(extraction.text)")

        // The email should survive verbatim (Latin glyphs, no ambiguity).
        XCTAssertTrue(
            extraction.text.lowercased().contains("zhangwei@example.com"),
            "email missing from OCR text: \(extraction.text)"
        )

        // Case number: the serial digits must be present.
        XCTAssertTrue(digits.contains("202603"), "case number year and court missing: \(extraction.text)")
        XCTAssertTrue(digits.contains("12345"), "case number serial missing: \(extraction.text)")

        // Geometry contract: every line's range must slice the joined text to
        // exactly the line's own string, and every normalized box must be
        // inside the unit square.
        let ns = extraction.text as NSString
        for line in extraction.lines {
            let sliced = ns.substring(
                with: NSRange(
                    location: line.range.lowerBound,
                    length: line.range.upperBound - line.range.lowerBound
                )
            )
            XCTAssertEqual(sliced, line.text, "line range must locate the line text")
            XCTAssertTrue(
                CGRect(x: 0, y: 0, width: 1, height: 1).contains(line.normalizedBox),
                "normalized box out of unit square: \(line.normalizedBox)"
            )
        }
        XCTAssertGreaterThan(extraction.pixelWidth, 0)
        XCTAssertGreaterThan(extraction.pixelHeight, 0)
    }

    /// The jpg path must extract exactly like the png path.
    func testOCRRoundTrip_extractRecoversPlantedValuesFromJPEG() throws {
        let url = track(try ImageFixtureRenderer.writeJPEG(lines: [
            "原告：张伟，电话\(Self.plantedPhone)"
        ]))

        let extraction = try ImageTextExtractor().extract(url)
        let digits = ImageFixtureRenderer.digitsOnly(extraction.text)
        XCTAssertTrue(digits.contains(Self.plantedPhone), "phone missing from JPEG OCR text: \(extraction.text)")
    }

    /// DocumentImporter conformance: an image imports as the image format with
    /// isScanned set (the text came from OCR, not a text layer).
    func testOCRRoundTrip_importDocumentReportsImageFormat() throws {
        let url = track(try ImageFixtureRenderer.writePNG(lines: ["ACME CORP 2026"]))

        let extractor = ImageTextExtractor()
        XCTAssertTrue(extractor.canImport(url))
        let imported = try extractor.importDocument(url)

        XCTAssertEqual(imported.format, .image)
        XCTAssertTrue(imported.isScanned)
        XCTAssertEqual(imported.pageCount, 1)
        XCTAssertTrue(imported.text.lowercased().contains("acme"))
    }

    // MARK: - Refusal (live Vision on a blank canvas)

    /// A blank image must fail the import with a clear "no readable text"
    /// error, never succeed with empty text.
    func testOCRRoundTrip_blankImageFailsWithNoReadableTextError() throws {
        let url = track(try ImageFixtureRenderer.writeBlankPNG())

        XCTAssertThrowsError(try ImageTextExtractor().importDocument(url)) { error in
            guard case DocumentIOError.unreadable(let detail) = error else {
                return XCTFail("expected DocumentIOError.unreadable, got \(error)")
            }
            XCTAssertTrue(
                detail.lowercased().contains("no readable text found in the image"),
                "error must say no readable text was found; got: \(detail)"
            )
        }
    }

    /// A file that is not an image at all fails as unreadable, not as a crash.
    func testExtractRefusesNonImageBytes() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("not-an-image-\(UUID().uuidString).png")
        try Data("just text pretending".utf8).write(to: url)
        _ = track(url)

        XCTAssertThrowsError(try ImageTextExtractor().extract(url)) { error in
            guard case DocumentIOError.unreadable = error else {
                return XCTFail("expected DocumentIOError.unreadable, got \(error)")
            }
        }
    }

    // MARK: - File type recognition (no Vision)

    func testSupportedExtensionsCoverPngJpgJpeg() {
        XCTAssertEqual(ImageTextExtractor.supportedExtensions, ["png", "jpg", "jpeg"])
    }

    func testIsImageFileByExtension() {
        XCTAssertTrue(ImageTextExtractor.isImageFile(URL(fileURLWithPath: "/tmp/a.PNG")))
        XCTAssertTrue(ImageTextExtractor.isImageFile(URL(fileURLWithPath: "/tmp/a.jpg")))
        XCTAssertTrue(ImageTextExtractor.isImageFile(URL(fileURLWithPath: "/tmp/a.JPEG")))
        XCTAssertFalse(ImageTextExtractor.isImageFile(URL(fileURLWithPath: "/tmp/a.txt")))
        XCTAssertFalse(ImageTextExtractor.isImageFile(URL(fileURLWithPath: "/tmp/a.pdf")))
    }

    /// A PNG or JPEG misnamed as .txt is still recognized by its magic bytes,
    /// so the vault and misnamed-file paths cannot fall through to the text
    /// importer and silently anonymize mojibake.
    func testIsImageFileByMagicBytesDespiteTxtExtension() throws {
        let image = try ImageFixtureRenderer.render(lines: ["X"], width: 200, fontSize: 24, lineHeight: 40)

        let pngURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("magic-\(UUID().uuidString).txt")
        try ImageFixtureRenderer.write(image: image, to: pngURL, typeIdentifier: "public.png")
        _ = track(pngURL)
        XCTAssertTrue(ImageTextExtractor.isImageFile(pngURL))

        let jpegURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("magic-\(UUID().uuidString).txt")
        try ImageFixtureRenderer.write(image: image, to: jpegURL, typeIdentifier: "public.jpeg")
        _ = track(jpegURL)
        XCTAssertTrue(ImageTextExtractor.isImageFile(jpegURL))

        let textURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("magic-\(UUID().uuidString).txt")
        try Data("plain text".utf8).write(to: textURL)
        _ = track(textURL)
        XCTAssertFalse(ImageTextExtractor.isImageFile(textURL))
    }

    // MARK: - Geometry building (injected recognizer, no Vision)

    /// Reading order and range building are pure logic over recognized lines,
    /// so they are pinned with an injected recognizer: lines sort top to
    /// bottom (Vision normalized origin is bottom-left, so DESCENDING midY),
    /// join with one newline, and carry UTF-16 ranges into the joined text.
    func testExtractOrdersLinesTopToBottomAndBuildsRanges() throws {
        let fixture = FixtureRecognizer(lines: [
            // Deliberately out of reading order: the middle line first.
            RecognizedTextLine(
                text: "middle 中文",
                normalizedBox: CGRect(x: 0.1, y: 0.4, width: 0.5, height: 0.1)
            ),
            RecognizedTextLine(
                text: "bottom",
                normalizedBox: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.1)
            ),
            RecognizedTextLine(
                text: "top",
                normalizedBox: CGRect(x: 0.1, y: 0.8, width: 0.5, height: 0.1)
            )
        ])
        let url = track(try ImageFixtureRenderer.writePNG(lines: ["irrelevant"]))

        let extraction = try ImageTextExtractor(recognizer: fixture).extract(url)

        XCTAssertEqual(extraction.text, "top\nmiddle 中文\nbottom")
        XCTAssertEqual(extraction.lines.map { $0.text }, ["top", "middle 中文", "bottom"])
        // "top" is 3 UTF-16 units; then newline at 3; "middle 中文" spans 4..<13.
        XCTAssertEqual(extraction.lines[0].range, 0..<3)
        XCTAssertEqual(extraction.lines[1].range, 4..<13)
        XCTAssertEqual(extraction.lines[2].range, 14..<20)
    }

    /// Whitespace-only observations are dropped; if nothing remains the
    /// extraction fails with the no-readable-text error.
    func testExtractDropsWhitespaceOnlyObservations() throws {
        let fixture = FixtureRecognizer(lines: [
            RecognizedTextLine(
                text: "   ",
                normalizedBox: CGRect(x: 0.1, y: 0.5, width: 0.2, height: 0.1)
            )
        ])
        let url = track(try ImageFixtureRenderer.writePNG(lines: ["irrelevant"]))

        XCTAssertThrowsError(try ImageTextExtractor(recognizer: fixture).extract(url)) { error in
            guard case DocumentIOError.unreadable(let detail) = error else {
                return XCTFail("expected DocumentIOError.unreadable, got \(error)")
            }
            XCTAssertTrue(detail.lowercased().contains("no readable text found in the image"))
        }
    }
}

// MARK: - Injected recognizer fixture

/// A canned recognizer so geometry logic is testable without Vision.
struct FixtureRecognizer: ImageTextRecognizing {
    let lines: [RecognizedTextLine]

    func recognizeTextLines(in image: CGImage) throws -> [RecognizedTextLine] {
        lines
    }
}
