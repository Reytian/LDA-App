import XCTest
import PDFKit
import CoreText
@testable import LDACore

/// Synthetic PDF sites must belong to one replacement, including case variants.
final class PdfOccurrenceOwnershipTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PdfOccurrenceOwnershipTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func pdf(_ lines: [String]) throws -> URL {
        let url = directory.appendingPathComponent("input.pdf")
        var bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &bounds, nil))
        let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
        context.beginPage(mediaBox: &bounds)
        for (index, line) in lines.enumerated() {
            context.textPosition = CGPoint(x: 72, y: 720 - index * 24)
            CTLineDraw(CTLineCreateWithAttributedString(
                NSAttributedString(string: line, attributes: [.font: font])
            ), context)
        }
        context.endPage()
        context.closePDF()
        return url
    }

    func testCaseVariantsHaveOneOwnerAtEachPrintedSite() throws {
        for (first, second) in [
            ("Marek Okafor", "MAREK OKAFOR"),
            ("Brightwater Holdings LLC", "BRIGHTWATER HOLDINGS LLC"),
            ("Jordan.Ellis@Example.com", "jordan.ellis@example.com"),
            ("1:24-cv-01234", "1:24-CV-01234"),
        ] {
            let url = try pdf([first, second, first])
            let pairs = [(text: first, token: "{VALUE_1}"), (text: second, token: "{VALUE_2}")]
            for ordered in [pairs, Array(pairs.reversed())] {
                let result = PdfImporter.redactionCoverage(in: url, surfaceTexts: ordered)
                XCTAssertEqual(result.occurrences.count, 3, first)
                XCTAssertEqual(result.occurrenceCount(forToken: "{VALUE_1}"), 2, first)
                XCTAssertEqual(result.occurrenceCount(forToken: "{VALUE_2}"), 1, first)
                XCTAssertEqual(PdfRedactionCoverage.unboxedOccurrenceCount(
                    sitesByToken: ["{VALUE_1}": 2, "{VALUE_2}": 1], occurrences: result.occurrences
                ), 0, first)
                let upper = try XCTUnwrap(result.occurrences.first { $0.token == "{VALUE_2}" })
                XCTAssertTrue(upper.boxes.allSatisfy { $0.token == "{VALUE_2}" })
                XCTAssertLessThan(try XCTUnwrap(upper.boxes.first).rect.midY, 710)
            }
        }
    }

    func testOneVariantCannotPayForAnUnlocatedCaseVariant() throws {
        let url = try pdf(["1:24-cv-01234", "1:24-cv-01234", "1:24-CV-", "01234"])
        let coverage = PdfImporter.redactionCoverage(in: url, surfaceTexts: [
            ("1:24-cv-01234", "{CASE_1}"), ("1:24-CV-01234", "{CASE_2}"),
        ])
        XCTAssertEqual(PdfRedactionCoverage.unboxedOccurrenceCount(
            sitesByToken: ["{CASE_1}": 2, "{CASE_2}": 1], occurrences: coverage.occurrences
        ), 1, "lowercase sites must not cover the unlocated uppercase site")
        XCTAssertFalse(coverage.occurrences.contains { $0.token == "{CASE_2}" && $0.isCovered })
    }

    func testCaseInsensitiveFallbackStillCoversASingleMappingValue() throws {
        let url = try pdf(["MAREK OKAFOR"])
        let coverage = PdfImporter.redactionCoverage(in: url, surfaceTexts: [("Marek Okafor", "{PERSON_1}")])
        XCTAssertEqual(coverage.occurrences.count, 1)
        XCTAssertEqual(coverage.boxes.first?.token, "{PERSON_1}")
    }

    func testLongNameAndStandaloneShortNameKeepTheirOwnLabels() throws {
        let url = try pdf(["Jordan Ellis and Ellis confirmed."])
        let coverage = PdfImporter.redactionCoverage(in: url, surfaceTexts: [
            ("Ellis", "{PERSON_2}"), ("Jordan Ellis", "{PERSON_1}"),
        ])
        XCTAssertEqual(coverage.occurrences.count, 2)
        XCTAssertEqual(coverage.occurrenceCount(forToken: "{PERSON_2}"), 1)
        XCTAssertEqual(PdfRedactionCoverage.unboxedOccurrenceCount(
            sitesByToken: ["{PERSON_1}": 1, "{PERSON_2}": 1], occurrences: coverage.occurrences
        ), 0)
    }

    func testOCRDistinctSitesOnTheSameLineAreNotNestedOccurrences() {
        let occurrences = PdfOCRImporter.occurrences(onLines: [
            (text: "Marek Okafor signed. MAREK OKAFOR witnessed. Ellis called Jordan Ellis.",
             rect: CGRect(x: 72, y: 700, width: 450, height: 18)),
        ], matching: [
            ("Marek Okafor", "{PERSON_1}"), ("MAREK OKAFOR", "{PERSON_2}"),
            ("Ellis", "{PERSON_3}"), ("Jordan Ellis", "{PERSON_4}"),
        ], pageIndex: 0)
        XCTAssertEqual(occurrences.count, 4)
        XCTAssertEqual(PdfRedactionCoverage.unboxedOccurrenceCount(
            sitesByToken: ["{PERSON_1}": 1, "{PERSON_2}": 1, "{PERSON_3}": 1, "{PERSON_4}": 1],
            occurrences: occurrences
        ), 0, "OCR boxes cover full lines; containment must use text sites, not geometry")
    }

    func testOriginalPDFWithCaseVariantEmailsWritesAndLeavesNoOriginalText() throws {
        let values = ["Jordan.Ellis@Example.com", "jordan.ellis@example.com"]
        let input = try pdf(["Delivery is due after inspection."] + values)
        let result = try LDAService.anonymize(
            input: input, outputDir: directory.appendingPathComponent("out"),
            protection: .passphrase("synthetic-pdf-test"), createdAtISO8601: "2026-11-12T00:00:00Z",
            format: .original
        )
        XCTAssertEqual(result.unboxedTokenCount, 0)
        let pdfURL = try XCTUnwrap(result.visualPdfURL)
        XCTAssertEqual(pdfURL.pathExtension, "pdf")
        let output = try XCTUnwrap(PDFDocument(url: pdfURL))
        for value in values {
            XCTAssertTrue(output.findString(value, withOptions: .caseInsensitive).isEmpty)
        }
        let ocr = try PdfOCRImporter().importDocument(pdfURL).text
        for value in values {
            XCTAssertFalse(ocr.localizedCaseInsensitiveContains(value), ocr)
        }
        XCTAssertTrue(ocr.contains("Delivery"), "OCR must read the output page: \(ocr)")

    }

    func testOriginalFormatRefusesWhenOnlyTheOtherCaseWasBoxed() throws {
        let input = try pdf(["Case 1:24-cv-01234", "Again 1:24-cv-01234", "Case 1:24-CV-", "01234"])
        let out = directory.appendingPathComponent("refused")
        XCTAssertThrowsError(try LDAService.anonymize(
            input: input, outputDir: out, protection: .passphrase("synthetic-pdf-test"),
            createdAtISO8601: "2026-11-12T00:00:00Z", format: .original
        )) { error in
            guard case RedactedOutputError.valuesNotCovered(let count) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertGreaterThan(count, 0)
        }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: out.path)) ?? []
        XCTAssertTrue(files.isEmpty, "a refused original-format export must write no files")
    }
}
