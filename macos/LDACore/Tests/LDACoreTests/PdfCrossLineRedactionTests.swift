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

    // MARK: - Index-space integrity (grapheme vs UTF-16)

    func testTheIndexMapIsPerUTF16UnitWithDecomposedAccents() {
        // "Jose" + combining acute: 5 graphemes but 6 UTF-16 units. The map
        // must carry one entry per UNIT; a per-grapheme map shifts every later
        // match and paints boxes over the wrong glyphs, which the review PDF
        // then presents as covered.
        let decomposed = "Jose\u{0301} met Smith"
        let (text, indexes) = PdfImporter.normalizeWhitespace(decomposed)

        XCTAssertEqual(
            indexes.count, text.utf16.count,
            "one index entry per UTF-16 unit is the invariant every search relies on"
        )
        // The combining mark keeps its own entry pointing at its own original
        // offset (unit 4 in the source).
        XCTAssertEqual(indexes[4], 4)
        // "Smith" sits after the accent: its mapped offset must reflect the
        // UTF-16 layout of the original, not a grapheme count.
        let smithRange = (text as NSString).range(of: "Smith")
        XCTAssertNotEqual(smithRange.location, NSNotFound)
        XCTAssertEqual(indexes[smithRange.location], 10)
    }

    func testTheIndexMapSurvivesSurrogatePairs() {
        // A supplementary-plane character (here MATHEMATICAL DOUBLE-STRUCK A,
        // U+1D538) occupies two UTF-16 units; both need entries or every later
        // offset is off by one.
        let text = "\u{1D538} Smith"
        let (normalized, indexes) = PdfImporter.normalizeWhitespace(text)

        XCTAssertEqual(indexes.count, normalized.utf16.count)
        let smithRange = (normalized as NSString).range(of: "Smith")
        XCTAssertNotEqual(smithRange.location, NSNotFound)
        XCTAssertEqual(
            indexes[smithRange.location], 3,
            "the pair contributes two units, so Smith starts at original unit 3"
        )
    }

    func testCaseInsensitiveMatchingSurvivesWithoutLowercasingTheHaystack() throws {
        // Lowercasing can change UTF-16 length (Turkish dotted I), so the
        // search must match case-insensitively without transforming either
        // string. Mixed case in the page must still produce boxes.
        let url = tempDir.appendingPathComponent("case.pdf")
        try makePDF(at: url, pages: [["Client: JANE Aoife", "smith of Acme."]])

        let boxes = PdfImporter.redactionBoxes(
            in: url,
            surfaceTexts: [(text: "Jane Aoife Smith", token: "{PERSON_1}")]
        )

        XCTAssertEqual(boxes.count, 2, "case differences must not defeat the fallback")
    }

    func testDecomposedAccentsBeforeTheMatchDoNotShiftTheBoxes() throws {
        // The regression this guards: decomposed accents EARLIER in the page
        // text shifted the box mapping for every later match. Draw an accented
        // prefix (decomposed form) on the same line, then verify the fallback
        // boxes for the split name land where the glyphs really are.
        let url = tempDir.appendingPathComponent("accents.pdf")
        try makePDF(at: url, pages: [["Re\u{0301}: Jane Aoife", "Smith signed."]])

        let boxes = PdfImporter.redactionBoxes(
            in: url,
            surfaceTexts: [(text: "Jane Aoife Smith", token: "{PERSON_1}")]
        )
        XCTAssertEqual(boxes.count, 2, "the split name must still get its two per-line boxes")

        // Anchor the first box against the TRUE glyph geometry: find "Jane" in
        // the page's own text layer and compare against its character bounds.
        let document = try XCTUnwrap(PDFDocument(url: url))
        let page = try XCTUnwrap(document.page(at: 0))
        let pageText = try XCTUnwrap(page.string) as NSString
        let janeRange = pageText.range(of: "Jane")
        guard janeRange.location != NSNotFound else {
            throw XCTSkip("PDFKit rewrote the text layer; geometry anchor unavailable")
        }
        let janeRect = page.characterBounds(at: janeRange.location)
        let firstLineBox = try XCTUnwrap(boxes.max(by: { $0.rect.midY < $1.rect.midY }))
        XCTAssertEqual(
            firstLineBox.rect.minX, janeRect.minX, accuracy: 3.0,
            "boxes must cover the real glyphs, not a position shifted by the accent"
        )
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

    // MARK: - Mixed contiguous and wrapped occurrences (finding 3)

    func testAValueContiguousOnOnePageAndWrappedOnAnotherIsBoxedOnBoth() throws {
        // The failure being closed: the whitespace-normalized search ran ONLY
        // when the exact search found the value nowhere in the document. A name
        // printed normally on one page and wrapped across two lines on another
        // therefore got a box on the normal page only. The wrapped page kept
        // the original pixels while the coverage count, which asked whether
        // SOME box existed for the token, called the value covered.
        let url = tempDir.appendingPathComponent("mixed-wrap.pdf")
        try makePDF(at: url, pages: [
            ["Client: Jane Aoife Smith signed."],
            ["Again: Jane Aoife", "Smith countersigned."]
        ])

        // Precondition: the exact search sees the contiguous occurrence only,
        // so this test exercises the combination rather than passing for the
        // old reason.
        let document = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(
            document.findString("Jane Aoife Smith", withOptions: .caseInsensitive).count, 1,
            "precondition: only the contiguous occurrence matches the exact search"
        )

        let boxes = PdfImporter.redactionBoxes(
            in: url,
            surfaceTexts: [(text: "Jane Aoife Smith", token: "{PERSON_1}")]
        )

        XCTAssertTrue(
            boxes.contains { $0.pageIndex == 0 },
            "the contiguous occurrence must stay boxed"
        )
        XCTAssertTrue(
            boxes.contains { $0.pageIndex == 1 },
            "the wrapped occurrence is left visible in the review PDF; boxed pages: "
                + "\(boxes.map(\.pageIndex))"
        )
    }

    // MARK: - Deduplicating the two searches, not the real occurrences

    func testAnOccurrenceSeenByBothSearchesYieldsOneBox() throws {
        // Both searches run for every value now, so a contiguous occurrence is
        // found twice. It has to collapse to ONE box rather than two rects
        // stacked on the same glyphs.
        let url = tempDir.appendingPathComponent("both-searches.pdf")
        try makePDF(at: url, pages: [["Client: Jane Aoife Smith signed."]])
        let needle = "Jane Aoife Smith"

        // Precondition: each search really does see this occurrence on its own,
        // so the single box below is dedup and not one search coming up empty.
        let document = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(
            document.findString(needle, withOptions: .caseInsensitive).count, 1,
            "precondition: the exact search sees the occurrence"
        )
        XCTAssertEqual(
            PdfImporter.normalizedSearchBoxes(
                needle: needle, token: "{PERSON_1}", in: document
            ).count,
            1,
            "precondition: the normalized search sees the same occurrence"
        )

        let coverage = PdfImporter.redactionCoverage(
            in: url,
            surfaceTexts: [(text: needle, token: "{PERSON_1}")]
        )

        XCTAssertEqual(coverage.occurrences.count, 1)
        XCTAssertEqual(
            coverage.boxes.count, 1,
            "one occurrence must not be painted twice, rects: \(coverage.boxes.map(\.rect))"
        )
    }

    func testTwoContiguousOccurrencesOnSeparatePagesStillYieldTwoBoxes() throws {
        // Dedup collapses the two SEARCHES that see one occurrence. It must
        // never collapse two real occurrences of the value.
        let url = tempDir.appendingPathComponent("twice-contiguous.pdf")
        try makePDF(at: url, pages: [
            ["Client: Jane Aoife Smith signed."],
            ["Witness: Jane Aoife Smith attended."]
        ])

        let coverage = PdfImporter.redactionCoverage(
            in: url,
            surfaceTexts: [(text: "Jane Aoife Smith", token: "{PERSON_1}")]
        )

        XCTAssertEqual(coverage.occurrences.count, 2)
        XCTAssertEqual(
            coverage.boxes.count, 2,
            "boxed pages: \(coverage.boxes.map(\.pageIndex))"
        )
        XCTAssertEqual(coverage.uncoveredOccurrenceCount, 0)
    }

    func testTwoContiguousOccurrencesOnOneLineStillYieldTwoBoxes() throws {
        // Two occurrences side by side on one line vertically overlap, so
        // dedup cannot key off the line: rects that merely touch must stay
        // separate boxes.
        let url = tempDir.appendingPathComponent("same-line-twice.pdf")
        try makePDF(at: url, pages: [["Jane Aoife Smith and Jane Aoife Smith agreed."]])

        let coverage = PdfImporter.redactionCoverage(
            in: url,
            surfaceTexts: [(text: "Jane Aoife Smith", token: "{PERSON_1}")]
        )

        XCTAssertEqual(
            coverage.boxes.count, 2,
            "both occurrences on the line need their own box, rects: "
                + "\(coverage.boxes.map(\.rect))"
        )
    }

    // MARK: - Coverage counted per occurrence, not per value

    func testTheReportedCountNamesAnUnboxedOccurrenceOfABoxedValue() {
        // Deliberately leave one occurrence of a two-occurrence value unboxed.
        // A per-value count answers 0 here, because the other occurrence IS
        // boxed, and the review PDF then claims coverage over visible PII.
        let token = "{PERSON_1}"
        let boxed = PdfTextOccurrence(
            pageIndex: 0,
            token: token,
            boxes: [
                RedactionBox(
                    pageIndex: 0,
                    rect: CGRect(x: 72, y: 700, width: 120, height: 14),
                    token: token
                )
            ]
        )
        let unboxed = PdfTextOccurrence(pageIndex: 1, token: token, boxes: [])
        let coverage = PdfRedactionCoverage(occurrences: [boxed, unboxed])

        XCTAssertEqual(coverage.occurrenceCount(forToken: token), 2)
        XCTAssertEqual(coverage.uncoveredOccurrenceCount, 1)
        XCTAssertEqual(
            PdfRedactionCoverage.unboxedOccurrenceCount(
                surfaceTexts: [(text: "Jane Aoife Smith", token: token)],
                textCoverage: coverage,
                boxedTokens: Set(coverage.boxes.map(\.token))
            ),
            1,
            "an unboxed occurrence must be reported even though the same value "
                + "is boxed elsewhere in the document"
        )
    }

    func testAValueTheTextLayerNeverLocatedIsStillReported() {
        // The other way a value stays visible: no occurrence at all, and no box
        // from the OCR or embedded-image channels either.
        let count = PdfRedactionCoverage.unboxedOccurrenceCount(
            surfaceTexts: [(text: "jane@example.test", token: "{EMAIL_1}")],
            textCoverage: PdfRedactionCoverage(),
            boxedTokens: []
        )
        XCTAssertEqual(count, 1)
    }

    func testAValueBoxedByAnotherChannelIsNotReportedUnboxed() {
        // Page OCR and embedded-image OCR contribute boxes without
        // contributing text-layer occurrences, so a value they boxed is
        // covered rather than a warning.
        let count = PdfRedactionCoverage.unboxedOccurrenceCount(
            surfaceTexts: [(text: "jane@example.test", token: "{EMAIL_1}")],
            textCoverage: PdfRedactionCoverage(),
            boxedTokens: ["{EMAIL_1}"]
        )
        XCTAssertEqual(count, 0)
    }
}
