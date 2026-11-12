//
//  PdfWrappedValueTests.swift
//  LDACoreTests
//
//  Review 2026-11-11, F6. In the review PDF a value wrapped across two lines
//  was not boxed, and nothing reported it: the text companion replaced both
//  occurrences of a Chinese company name, the review PDF boxed only the one
//  printed on one line, and the summary said unboxedTokenCount 0. The
//  text-layer search collapsed the line break to a space, which a Chinese
//  name never holds, and coverage asked only whether SOME box carried the
//  token. OCR matched one recognized line at a time. Latin lines were joined
//  without a space whenever the wrapped line ended in punctuation
//  ("Agreement,and", "arrive.The", "and/orthe"), and an email at a line end
//  swallowed the next word ("jordan.ellis@example.comfor").
//
//  Now every occurrence is boxed, a soft line break included, on the
//  text-layer and the OCR channels; coverage counts the sites the text
//  replaced against the occurrences boxed, per token, so an unboxed
//  occurrence is reported even when the same placeholder is boxed elsewhere,
//  and scanned PDFs report coverage too. Latin lines join with a space unless
//  the break is a hyphenation; CJK joins stay empty.
//
//  The CJK page is the review's inputs/pdf/cjk.pdf drawn again. Every name is
//  invented.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
import PDFKit
import CoreText
@testable import LDACore

final class PdfWrappedValueTests: XCTestCase {

    static let company = "华光精密仪器有限公司"
    /// inputs/pdf/cjk.pdf, line for line: the company wraps after 华光精密
    /// and is printed again on one line further down.
    static let cjkLines = [
        "依法审理依法审理依法审理依法审理华光精密",
        "仪器有限公司本院认为本院认为本院认为本院",
        "认为本院认为本院认为本院认为本院认为本院",
        "认为本院认为本院认为本院认为本院认为原告",
        "被告华光精密仪器有限公司诉讼请求成立。",
        "判决如下：",
    ]

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        assertNoTestSeamsInstalled()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PdfWrappedValueTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        LDAService.makeExtractorForTesting = nil
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        try super.tearDownWithError()
    }

    private func makePDF(_ lines: [String], font name: String, size: CGFloat, at url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { throw XCTSkip("no PDF context") }
        let font = CTFontCreateWithName(name as CFString, size, nil)
        context.beginPage(mediaBox: &box)
        var y: CGFloat = 720
        for line in lines {
            context.textPosition = CGPoint(x: 72, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: line, attributes: [.font: font])), context)
            y -= size * 1.6
        }
        context.endPage()
        context.closePDF()
    }

    // MARK: - Text layer: a wrapped CJK value is boxed

    func testBothOccurrencesOfAWrappedChineseNameAreBoxed() throws {
        let url = tempDir.appendingPathComponent("cjk.pdf")
        try makePDF(Self.cjkLines, font: "PingFang SC", size: 16, at: url)
        let coverage = PdfImporter.redactionCoverage(in: url, surfaceTexts: [(Self.company, "{COMPANY_1}")])
        XCTAssertEqual(coverage.occurrences.count, 2, "the wrapped occurrence and the one-line one")
        XCTAssertTrue(coverage.occurrences.allSatisfy(\.isCovered))
        let wrapped = try XCTUnwrap(coverage.occurrences.max { $0.boxes.count < $1.boxes.count })
        XCTAssertEqual(wrapped.boxes.count, 2, "one box per printed line of the wrapped occurrence")
    }

    func testTheServiceBoxesEveryOccurrenceAndReportsNoneUnboxed() throws {
        struct Reports: TextCompleter {
            func complete(prompt: String, maxTokens: Int?, stop: [String]) throws -> String {
                #"{"entities":[{"value":"华光精密仪器有限公司","type":"COMPANY"}],"redacted_text":""}"#
            }
        }
        LDAService.makeExtractorForTesting = { _ in LLMExtractor(completer: Reports()) }
        let url = tempDir.appendingPathComponent("cjk.pdf")
        try makePDF(Self.cjkLines, font: "PingFang SC", size: 16, at: url)
        let result = try LDAService.anonymize(
            input: url,
            outputDir: tempDir.appendingPathComponent("out", isDirectory: true),
            protection: .passphrase("pdf-wrapped"),
            createdAtISO8601: "2026-11-11T00:00:00Z",
            llmModelPath: tempDir.appendingPathComponent("model.gguf").path
        )
        let companion = try String(contentsOf: result.redactedFileURL, encoding: .utf8)
        XCTAssertEqual(companion.components(separatedBy: "{COMPANY_1}").count - 1, 2, companion)
        XCTAssertEqual(result.unboxedTokenCount, 0)

        // Every glyph of both occurrences is under a box in the review PDF:
        // sample the centre of each glyph of the original in the rendered
        // review page.
        let original = try XCTUnwrap(PDFDocument(url: url)?.page(at: 0))
        let review = try XCTUnwrap(PDFDocument(url: try XCTUnwrap(result.visualPdfURL))?.page(at: 0))
        let pageText = (original.string ?? "") as NSString
        var glyphs: [CGRect] = []
        var from = 0
        for part in ["华光精密", "仪器有限公司", Self.company] {
            let range = pageText.range(of: part, range: NSRange(location: from, length: pageText.length - from))
            XCTAssertNotEqual(range.location, NSNotFound, part)
            // PDFKit's selection for each character: characterBounds(at:) can
            // drift from the page string by one index per line break.
            for index in range.location ..< range.location + range.length {
                glyphs.append(try XCTUnwrap(original.selection(for: NSRange(location: index, length: 1))).bounds(for: original))
            }
            from = range.location + range.length
        }
        let raster = try XCTUnwrap(render(review))
        let boxed = glyphs.filter { isBoxed($0, in: raster) }.count
        XCTAssertEqual(boxed, glyphs.count, "every glyph of both occurrences is boxed (\(boxed) of \(glyphs.count))")
    }

    /// True when the upper band of `rect` (PDF page coordinates) is dark in
    /// the rendered review page: a box, whose white token label sits at its
    /// bottom edge, and not the paper around an uncovered glyph's strokes.
    private func isBoxed(_ rect: CGRect, in raster: (data: UnsafeMutableRawPointer, width: Int, height: Int, scale: CGFloat)) -> Bool {
        var dark = 0
        for i in 1...5 {
            for fraction in [0.75, 0.88] as [CGFloat] {
                let point = CGPoint(x: rect.minX + rect.width * CGFloat(i) / 6, y: rect.minY + rect.height * fraction)
                let x = Int(point.x * raster.scale), y = Int(point.y * raster.scale)
                guard x >= 0, x < raster.width, y >= 0, y < raster.height else { continue }
                let pixel = raster.data.advanced(by: (raster.height - 1 - y) * raster.width * 4 + x * 4)
                    .assumingMemoryBound(to: UInt8.self)
                if Int(pixel[0]) + Int(pixel[1]) + Int(pixel[2]) < 3 * 60 { dark += 1 }
            }
        }
        return dark >= 9
    }

    private func render(_ page: PDFPage) -> (data: UnsafeMutableRawPointer, width: Int, height: Int, scale: CGFloat)? {
        let bounds = page.bounds(for: .mediaBox)
        let scale: CGFloat = 2
        let width = Int(bounds.width * scale), height = Int(bounds.height * scale)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        rasters.append(context)
        guard let data = context.data else { return nil }
        return (data, width, height, scale)
    }

    /// Keeps the rendered contexts alive while their pixels are read.
    private var rasters: [CGContext] = []


    // MARK: - Coverage is counted per occurrence against the replaced sites

    func testAnUnboxedOccurrenceIsReportedWhenTheSameTokenIsBoxedElsewhere() {
        let boxed = PdfTextOccurrence(
            pageIndex: 0, token: "{COMPANY_1}",
            boxes: [RedactionBox(pageIndex: 0, rect: CGRect(x: 72, y: 600, width: 100, height: 16), token: "{COMPANY_1}")]
        )
        // The text replaced the company at two sites; one occurrence is boxed.
        XCTAssertEqual(PdfRedactionCoverage.unboxedOccurrenceCount(
            sitesByToken: ["{COMPANY_1}": 2],
            occurrences: [boxed]
        ), 1)
        XCTAssertEqual(PdfRedactionCoverage.unboxedOccurrenceCount(
            sitesByToken: ["{COMPANY_1}": 1, "{PERSON_1}": 1],
            occurrences: [boxed]
        ), 1, "a token never boxed anywhere counts its sites")
    }

    /// The independent review of F6: a short name is also found inside a
    /// longer one ("Ellis" in "Jordan Ellis"), boxed there, and that box
    /// counted as covering one of the short name's own sites, so a real
    /// unboxed site of it was cancelled to 0. An occurrence lying wholly in
    /// another token's box is part of that value, not a site of its own.
    func testAShortNameFoundInsideALongerOneDoesNotCancelItsUnboxedSite() {
        func box(_ x: CGFloat, _ width: CGFloat, _ token: String) -> RedactionBox {
            RedactionBox(pageIndex: 0, rect: CGRect(x: x, y: 600, width: width, height: 16), token: token)
        }
        let long = PdfTextOccurrence(pageIndex: 0, token: "{PERSON_1}", boxes: [box(72, 120, "{PERSON_1}")])
        let nested = PdfTextOccurrence(pageIndex: 0, token: "{PERSON_2}", boxes: [box(140, 52, "{PERSON_2}")])
        let unboxed = PdfTextOccurrence(pageIndex: 0, token: "{PERSON_2}", boxes: [])
        XCTAssertEqual(PdfRedactionCoverage.unboxedOccurrenceCount(
            sitesByToken: ["{PERSON_1}": 1, "{PERSON_2}": 1],
            occurrences: [long, nested, unboxed]
        ), 1, "the standalone short name is still showing")
    }

    // MARK: - OCR: a value wrapped across recognized lines is boxed

    func testOCROccurrencesSpanRecognizedLines() {
        let lines: [(text: String, rect: CGRect)] = [
            ("依法审理依法审理华光精密", CGRect(x: 72, y: 700, width: 300, height: 20)),
            ("仪器有限公司本院认为", CGRect(x: 72, y: 676, width: 300, height: 20)),
            ("被告华光精密仪器有限公司诉讼请求成立。", CGRect(x: 72, y: 652, width: 300, height: 20)),
        ]
        let occurrences = PdfOCRImporter.occurrences(
            onLines: lines,
            matching: [(text: Self.company, token: "{COMPANY_1}")],
            pageIndex: 0
        )
        XCTAssertEqual(occurrences.count, 2)
        XCTAssertEqual(occurrences.map(\.boxes.count).sorted(), [1, 2], "the wrapped one is boxed on both lines")
    }

    // MARK: - Line joins

    func testLatinLinesJoinWithASpaceUnlessTheBreakIsAHyphenation() {
        // The review's inputs/pdf/lines.txt.
        let text = """
        This Consulting Agreement is made by and between Willowcrest Studio LLC and
        Jordan Ellis, who accept each and every one of the terms of this Agreement,
        and it shall remain in force until the goods listed in Schedule One arrive.
        The costs of carriage and insurance are to be borne by the Buyer and/or
        the Seller in equal parts; questions are to go to jordan.ellis@example.com
        for the attention of the General Counsel, who replies within ten days, sub-
        ject to the notice provisions of this Agreement and of the governing law.
        Signed by Jordan Ellis.
        """
        let joined = PdfLineReflow.joinSoftBreaks(text)
        XCTAssertTrue(joined.contains("this Agreement, and it"), joined)
        XCTAssertTrue(joined.contains("arrive. The costs"), joined)
        XCTAssertTrue(joined.contains("and/or the Seller"), joined)
        XCTAssertTrue(joined.contains("jordan.ellis@example.com for the"), joined)
        XCTAssertTrue(joined.contains("sub-ject"), "a hyphenation joins with no space: \(joined)")
    }

    // MARK: - A value broken at its own hyphen (independent review of F6)

    /// The independent review's p20 lines: full lines (so each break is a
    /// soft one) broken at one of the value's own hyphens. F6's space made
    /// them "212-555- 0148", which no rule reads, so they went into the
    /// redacted text in clear; 2.0 joined them with nothing.
    static let hyphenBrokenLines = [
        "(Fictional) The tenant may be reached on the main office line, which is 212-555-",
        "0148, and  the  landlord  may be reached on the second line, which is 646-555-",
        "0199. Under the lease the tenant's social security number is listed as 123-45-",
        "6789 and  the  related matter in the federal court is docketed as No. 1:24-cv-",
        "01234 in  the  Southern  District.  For  the  keys  please  contact  Mr. Jean-",
        "Pierre Dupont  at  the  front  desk  of  the  building  on  any  business day.",
        "Nothing else  in  this  note  is  confidential  and  it  may be shared freely.",
    ]

    func testALineBrokenAtAHyphenJoinsWithNothing() {
        let joined = PdfLineReflow.joinSoftBreaks(Self.hyphenBrokenLines.joined(separator: "\n"))
        for value in ["212-555-0148", "646-555-0199", "123-45-6789", "1:24-cv-01234", "Jean-Pierre Dupont"] {
            XCTAssertTrue(joined.contains(value), "\(value) in: \(joined)")
        }
    }

    func testANumberBrokenAtItsHyphenJoinsEvenOnAShortLine() {
        // The review's p19: the lines are short, so the measure calls every
        // break a hard one and nothing used to join; the numbers stayed split
        // across lines and in clear (2.0 alike). A line ending in a letter or
        // digit and a hyphen, followed by a line starting with a digit, is a
        // number or code broken at its own separator.
        let text = """
        (Fictional) The tenant may be reached on the main office line, which is 212-555-
        0148, or on the mobile line +1 646-555-
        0199. The tenant's SSN is 123-45-
        6789 and the docket is No. 1:24-cv-
        01234 in the Southern District. Contact Jean-
        Pierre Dupont for the keys.
        """
        let joined = PdfLineReflow.joinSoftBreaks(text)
        for value in ["212-555-0148", "646-555-0199", "123-45-6789", "1:24-cv-01234"] {
            XCTAssertTrue(joined.contains(value), "\(value) in: \(joined)")
        }
        XCTAssertTrue(joined.contains("Contact Jean-\nPierre"), "a short line is still a hard break otherwise: \(joined)")
    }

    func testValuesBrokenAtAHyphenInAPDFAreFoundWhole() throws {
        let url = tempDir.appendingPathComponent("hyphen.pdf")
        try makePDF(Self.hyphenBrokenLines, font: "Helvetica", size: 11, at: url)
        let text = try PdfImporter().importDocument(url).text
        let found = DeterministicEngine().detect(text).map(\.text)
        for value in ["212-555-0148", "123-45-6789", "1:24-cv-01234"] {
            XCTAssertTrue(found.contains { $0.contains(value) }, "\(value) not found whole in \(found) from: \(text)")
        }
    }

    /// The second independent review of F6 (probe t01_spaced_dash.pdf): a
    /// line ending in a dash set off by a space ("Tenant SSN -") joined the
    /// next line with nothing, so the SSN and the phone number at its start
    /// read "-123-45-6789" and "-010-62551234", which no rule reads, and went
    /// into the redacted text in clear. A hyphen is the value's own only when
    /// it is attached to a letter or digit; a spaced dash joins with a space.
    static let spacedDashLines = [
        "(Fictional) Under  the  lease the tenant must report all changes. Tenant SSN -",
        "123-45-6789 and the landlord may be reached at the office line, which is Tel -",
        "010-62551234 during business hours. The parties signed the lease on 3 May 2026",
        "and agreed  that the deposit is held by the landlord until the lease is ended.",
    ]

    func testALineEndingInASpacedDashJoinsWithASpace() {
        let joined = PdfLineReflow.joinSoftBreaks(Self.spacedDashLines.joined(separator: "\n"))
        XCTAssertTrue(joined.contains("Tenant SSN - 123-45-6789 and"), joined)
        XCTAssertTrue(joined.contains("Tel - 010-62551234 during"), joined)
        XCTAssertFalse(joined.contains("-123-45-6789"), joined)
    }

    func testValuesAfterASpacedDashInAPDFAreFound() throws {
        let url = tempDir.appendingPathComponent("spaced-dash.pdf")
        try makePDF(Self.spacedDashLines, font: "Helvetica", size: 11, at: url)
        let text = try PdfImporter().importDocument(url).text
        let found = DeterministicEngine().detect(text).map(\.text)
        for value in ["123-45-6789", "010-62551234"] {
            XCTAssertTrue(found.contains(value), "\(value) not found in \(found) from: \(text)")
        }
    }

    func testChineseLinesStillJoinWithNothing() {
        let joined = PdfLineReflow.joinSoftBreaks(Self.cjkLines.joined(separator: "\n"))
        XCTAssertTrue(joined.contains("华光精密仪器有限公司本院认为"), joined)
    }

    func testAnAddressBrokenAtItsOwnSeparatorStillJoinsWithNothing() {
        let text = """
        The schedule is published at https://example.com/schedules/2026/
        annex-b and it is incorporated by reference in this agreement here.
        The parties have read it and accept every term it sets out in full.
        Nothing in it changes the price, the term or the governing law of it.
        """
        let joined = PdfLineReflow.joinSoftBreaks(text)
        XCTAssertTrue(joined.contains("https://example.com/schedules/2026/annex-b"), joined)
    }
}
