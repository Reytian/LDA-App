//
//  PdfLineReflowTests.swift
//  LDACoreTests
//
//  Soft line breaks in a PDF's text are joined, real ones are kept. The case
//  that motivated it: in guiding-case PDFs a name wrapped at the right margin
//  reached detection in two pieces, so one company got several placeholders.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import CoreText
import PDFKit
import XCTest
@testable import LDACore

final class PdfLineReflowTests: XCTestCase {

    /// A 20-character CJK line: 40 display columns, a full line in these tests.
    private func full(_ seed: Character) -> String { String(repeating: seed, count: 20) }

    // MARK: - Joining

    func testAChineseNameWrappedAtTheMarginIsJoined() {
        let text = [
            String(repeating: "甲", count: 16) + "华光精密",
            "仪器有限公司" + String(repeating: "乙", count: 14),
            full("丙"),
            "本院予以确认。"
        ].joined(separator: "\n")
        let joined = PdfLineReflow.joinSoftBreaks(text)
        XCTAssertTrue(joined.contains("华光精密仪器有限公司"), joined)
        XCTAssertFalse(joined.contains("\n"), "one paragraph, one line: \(joined)")
    }

    func testAShortLastLineEndsTheParagraph() {
        let text = [full("甲"), full("乙"), "第一段结束。", full("丙"), full("丁"), "第二段结束。"].joined(separator: "\n")
        XCTAssertEqual(
            PdfLineReflow.joinSoftBreaks(text),
            full("甲") + full("乙") + "第一段结束。\n" + full("丙") + full("丁") + "第二段结束。"
        )
    }

    func testLatinWordsWrappedAtTheMarginGetOneSpace() {
        let text = """
        The parties agree that Brightwater Analytics shall deliver the
        goods by the date stated in Schedule 1 of this Agreement, and
        shall bear the cost of carriage and insurance until the goods
        arrive.
        """
        XCTAssertEqual(
            PdfLineReflow.joinSoftBreaks(text),
            "The parties agree that Brightwater Analytics shall deliver the goods by the date stated in "
                + "Schedule 1 of this Agreement, and shall bear the cost of carriage and insurance until "
                + "the goods arrive."
        )
    }

    func testAnAddressWrappedAtTheMarginContinuesWithoutASpace() {
        let text = [
            String(repeating: "甲", count: 8) + " https://example.com/terms/",
            "section-4" + String(repeating: "乙", count: 15),
            full("丙"),
            "完。"
        ].joined(separator: "\n")
        XCTAssertTrue(PdfLineReflow.joinSoftBreaks(text).contains("https://example.com/terms/section-4"))
    }

    func testANumberAfterTheBreakIsNotAListMarker() {
        let text = [String(repeating: "甲", count: 15) + "合计人民币", "1.5万元" + String(repeating: "乙", count: 17), full("丙"), "完。"]
            .joined(separator: "\n")
        XCTAssertTrue(PdfLineReflow.joinSoftBreaks(text).contains("合计人民币1.5万元"))
    }

    // MARK: - Real breaks

    func testIndentedNumberedAndBracketedLinesStartNewParagraphs() {
        for start in ["\u{3000}\u{3000}新的段落", "1.第一项", "（一）第一项", "一、第一项", "第三条 违约责任", "【基本案情】", "• 要点"] {
            let text = [full("甲"), full("乙"), full("丙"), start].joined(separator: "\n")
            XCTAssertEqual(
                PdfLineReflow.joinSoftBreaks(text),
                full("甲") + full("乙") + full("丙") + "\n" + start,
                "a line opening with \(start) must stay on its own line"
            )
        }
    }

    func testBlankLinesAndPageBreaksStay() {
        let text = [full("甲"), full("乙"), full("丙"), "", "", full("丁"), "完。"].joined(separator: "\n")
        XCTAssertEqual(PdfLineReflow.joinSoftBreaks(text), full("甲") + full("乙") + full("丙") + "\n\n\n" + full("丁") + "完。")
    }

    func testAPageOfShortLinesIsLeftAsItIs() {
        let text = "第一条\n第二条\n甲方（盖章）：\n乙方（盖章）：\n日期："
        XCTAssertEqual(PdfLineReflow.joinSoftBreaks(text), text)
    }

    func testWidthCountsChineseAsTwoColumns() {
        XCTAssertEqual(PdfLineReflow.width(of: "华光A1"), 6)
        XCTAssertEqual(PdfLineReflow.width(of: "（）"), 4)
    }

    // MARK: - Through the PDF importer

    func testThePdfImporterJoinsANameWrappedAtTheMargin() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PdfLineReflowTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("wrapped.pdf")
        let paragraph = String(repeating: "依法审理", count: 4) + "华光精密仪器有限公司" + String(repeating: "本院认为", count: 13) + "原告"
        let lines = stride(from: 0, to: 80, by: 20).map { start -> String in
            let from = paragraph.index(paragraph.startIndex, offsetBy: start)
            return String(paragraph[from..<paragraph.index(from, offsetBy: 20)])
        } + ["诉讼请求成立。", "判决如下："]
        try drawPDF(lines: lines, at: url)

        let text = try PdfImporter().importDocument(url).text
        XCTAssertTrue(text.contains("华光精密仪器有限公司"), text)
        XCTAssertTrue(text.contains(String(paragraph.prefix(80)) + "诉讼请求成立。\n判决如下："), text)
    }

    /// One line of text per element, each on its own baseline, so the text
    /// layer carries a newline after every line, as a typeset PDF does.
    private func drawPDF(lines: [String], at url: URL) throws {
        guard let consumer = CGDataConsumer(url: url as CFURL) else { throw XCTSkip("no PDF consumer") }
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { throw XCTSkip("no PDF context") }
        let font = CTFontCreateWithName("PingFang SC" as CFString, 14, nil)
        context.beginPage(mediaBox: &mediaBox)
        var y: CGFloat = 720
        for line in lines {
            let attributed = NSAttributedString(
                string: line,
                attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
            )
            context.textPosition = CGPoint(x: 72, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
            y -= 24
        }
        context.endPage()
        context.closePDF()
    }
}
