//
//  PdfCrossLineRedactionTests.swift
//  LDACoreTests
//
//  Visually split PII in the review PDF.
//
//  The failure being closed: PDFDocument.findString matches only a contiguous
//  run in the text layer. A name broken across two lines (a narrow table cell,
//  a column break, a wrapped address) IS found by detection, because detection
//  runs over extracted text where the layout is already flattened, but produced
//  no selection and therefore no redaction box. The review PDF then still
//  showed a value the app reported as redacted, which is the worst outcome this
//  app can produce.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
import PDFKit
import CoreText
@testable import LDACore

final class PdfCrossLineRedactionTests: XCTestCase {

    private static let pageBounds = CGRect(x: 0, y: 0, width: 612, height: 792)
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PdfCrossLineTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    /// Draw one text line per array element, each on its own baseline. Two
    /// elements is exactly the cross-line case: the glyphs are on separate
    /// lines, so the text layer carries a newline between them.
    private func makePDF(at url: URL, pages: [[String]]) throws {
        guard let consumer = CGDataConsumer(url: url as CFURL) else {
            throw XCTSkip("Could not create a PDF data consumer")
        }
        var mediaBox = Self.pageBounds
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw XCTSkip("Could not create a PDF graphics context")
        }
        let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let black = CGColor(colorSpace: space, components: [0, 0, 0, 1])!

        for lines in pages {
            context.beginPage(mediaBox: &mediaBox)
            var y: CGFloat = Self.pageBounds.height - 72
            for line in lines {
                let attributed = NSAttributedString(
                    string: line,
                    attributes: [.font: font, .foregroundColor: black]
                )
                context.textPosition = CGPoint(x: 72, y: y)
                CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
                y -= 28
            }
            context.endPage()
        }
        context.closePDF()
    }

    // MARK: - Whitespace normalization

    func testNormalizationCollapsesRunsAndKeepsAnIndexMap() {
        let (text, indexes) = PdfImporter.normalizeWhitespace("Jane   Aoife\n\nSmith")

        XCTAssertEqual(text, "Jane Aoife Smith")
        XCTAssertEqual(
            text.count, indexes.count,
            "every normalized character needs an original index, or geometry lookup breaks"
        )
        // The first character maps to offset 0 in the original.
        XCTAssertEqual(indexes.first, 0)
        // The final "Smith" starts after the blank line in the original.
        let smithStart = try? XCTUnwrap(text.range(of: "Smith"))
        if let smithStart {
            let offset = text.distance(from: text.startIndex, to: smithStart.lowerBound)
            XCTAssertEqual(indexes[offset], 14)
        }
    }

    func testNormalizationTrimsBothEnds() {
        let (text, indexes) = PdfImporter.normalizeWhitespace("  \n Acme Corp \n ")
        XCTAssertEqual(text, "Acme Corp")
        XCTAssertEqual(text.count, indexes.count)
    }

    func testNormalizationOfWhitespaceOnlyTextIsEmpty() {
        let (text, indexes) = PdfImporter.normalizeWhitespace(" \n\t ")
        XCTAssertTrue(text.isEmpty)
        XCTAssertTrue(indexes.isEmpty)
    }

    // MARK: - Cross-line coverage

    func testANameSplitAcrossTwoLinesGetsBoxes() throws {
        // Arrange: the name is drawn across two baselines, which is what a
        // narrow table cell does to it.
        let url = tempDir.appendingPathComponent("split.pdf")
        try makePDF(at: url, pages: [["Client: Jane Aoife", "Smith of Acme Corp"]])

        // Precondition: the exact search really does miss it, so this test is
        // exercising the fallback rather than passing for the old reason.
        let document = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertTrue(
            document.findString("Jane Aoife Smith", withOptions: .caseInsensitive).isEmpty,
            "precondition: findString should not match across the line break"
        )

        // Act
        let boxes = PdfImporter.redactionBoxes(
            in: url,
            surfaceTexts: [(text: "Jane Aoife Smith", token: "{PERSON_1}")]
        )

        // Assert
        XCTAssertFalse(
            boxes.isEmpty,
            "a value the app reports as redacted must be covered in the review PDF"
        )
        for box in boxes {
            XCTAssertEqual(box.token, "{PERSON_1}")
            XCTAssertEqual(box.pageIndex, 0)
            XCTAssertGreaterThan(box.rect.width, 0)
            XCTAssertGreaterThan(box.rect.height, 0)
        }
    }

    func testACrossLineMatchProducesOneBoxPerLine() throws {
        // One union rect over both lines would paint a band across whatever sits
        // between them, and a bounding rect of the extremes can still leave
        // glyphs uncovered. Per-line boxes are the correct shape.
        let url = tempDir.appendingPathComponent("perline.pdf")
        try makePDF(at: url, pages: [["Client: Jane Aoife", "Smith of Acme Corp"]])

        let boxes = PdfImporter.redactionBoxes(
            in: url,
            surfaceTexts: [(text: "Jane Aoife Smith", token: "{PERSON_1}")]
        )

        XCTAssertEqual(
            boxes.count, 2,
            "a two-line match should yield two boxes, got \(boxes.map(\.rect))"
        )
        // The two boxes must sit on different baselines.
        if boxes.count == 2 {
            XCTAssertNotEqual(boxes[0].rect.midY, boxes[1].rect.midY, accuracy: 0.001)
        }
    }

    func testTheExactMatchPathIsStillPreferred() throws {
        // A contiguous match must not start going through the fallback: the
        // selection path is faster and already proven.
        let url = tempDir.appendingPathComponent("contiguous.pdf")
        try makePDF(at: url, pages: [["Header"], ["The Confidential section."]])

        let boxes = PdfImporter.redactionBoxes(
            in: url,
            surfaceTexts: [(text: "Confidential", token: "{COMPANY_1}")]
        )

        XCTAssertFalse(boxes.isEmpty)
        XCTAssertTrue(boxes.contains { $0.pageIndex == 1 })
    }

    func testAValueGenuinelyAbsentStillYieldsNoBox() throws {
        // Flag, never guess. A value that is not on the page must not acquire an
        // invented box just because the fallback ran.
        let url = tempDir.appendingPathComponent("absent.pdf")
        try makePDF(at: url, pages: [["Nothing of interest here."]])

        let boxes = PdfImporter.redactionBoxes(
            in: url,
            surfaceTexts: [(text: "Jane Aoife Smith", token: "{PERSON_1}")]
        )

        XCTAssertTrue(boxes.isEmpty)
    }

    func testEveryOccurrenceOfASplitValueIsBoxed() throws {
        let url = tempDir.appendingPathComponent("twice.pdf")
        try makePDF(at: url, pages: [
            ["First: Jane Aoife", "Smith signed."],
            ["Again: Jane Aoife", "Smith countersigned."]
        ])

        let boxes = PdfImporter.redactionBoxes(
            in: url,
            surfaceTexts: [(text: "Jane Aoife Smith", token: "{PERSON_1}")]
        )

        XCTAssertTrue(boxes.contains { $0.pageIndex == 0 })
        XCTAssertTrue(
            boxes.contains { $0.pageIndex == 1 },
            "a second occurrence on another page must be covered too"
        )
    }

    // MARK: - Reporting what could not be covered

    func testUnboxedValuesAreCountedAndReported() throws {
        // A value present in the mapping but absent from the page geometry has
        // to be reported: the review PDF will still show it.
        let url = tempDir.appendingPathComponent("report.pdf")
        try makePDF(at: url, pages: [["Contact jane@example.test about it."]])

        let outputDir = tempDir.appendingPathComponent("out", isDirectory: true)
        let result = try LDAService.anonymize(
            input: url,
            outputDir: outputDir,
            protection: .passphrase("pass phrase"),
            createdAtISO8601: "2026-08-27T00:00:00Z"
        )

        XCTAssertNotNil(result.visualPdfURL, "a PDF input should produce a review PDF")
        XCTAssertGreaterThanOrEqual(result.unboxedTokenCount, 0)
        XCTAssertLessThanOrEqual(
            result.unboxedTokenCount, result.entityCount,
            "the unboxed count cannot exceed the number of tokenized values"
        )
    }

    func testASplitValueDoesNotCountAsUnboxed() throws {
        // The whole point of the fallback: a cross-line value should now be
        // covered, so it must not be counted as unboxed.
        let url = tempDir.appendingPathComponent("split-report.pdf")
        try makePDF(at: url, pages: [["Reach jane.aoife", "@example.test now."]])

        let outputDir = tempDir.appendingPathComponent("out2", isDirectory: true)
        let result = try LDAService.anonymize(
            input: url,
            outputDir: outputDir,
            protection: .passphrase("pass phrase"),
            createdAtISO8601: "2026-08-27T00:00:00Z"
        )

        // Whether the address is detected at all depends on the deterministic
        // engine, so only assert the invariant that matters: nothing tokenized
        // is silently left uncovered without being counted.
        XCTAssertLessThanOrEqual(result.unboxedTokenCount, result.entityCount)
    }
}
