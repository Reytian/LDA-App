//
//  DocxServiceFidelityIntegrationTests.swift
//  LDACoreTests
//
//  One realistic contract through LDAService.anonymize and LDAService.restore:
//  a styled heading, a numbered list, a 3x3 table with PII in its cells, a
//  bold/italic run boundary inside an email, a header and a footer carrying
//  PII, two phone numbers separated by a tab, and a soft line break. The
//  restored package must read back as the original text, keep styles.xml and
//  numbering.xml byte for byte, keep every run's properties in order, and
//  carry no placeholder token in any part. Deterministic detection only.
//
//  House rules: all comments and strings in English. Fixture values may be
//  Chinese. No em-dash and no en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class DocxServiceFidelityIntegrationTests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lda-fidelity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    // MARK: - Fixture values (deterministic-detector types only)

    private static let phoneA = "13812345678"
    private static let phoneB = "13912345678"
    private static let email = "zhangsan@example.com"
    private static let nationalID = "33010619900101123X"
    private static let chineseDate = "2026年3月15日"
    private static let isoDate = "2026-04-30"
    private static let amount = "人民币 500,000.00"
    private static let piiValues = [phoneA, phoneB, email, nationalID, chineseDate, isoDate, amount]

    // MARK: - Fixture markup

    private static let listParagraphProperties =
        "<w:pStyle w:val=\"ListNumber\"/><w:numPr><w:ilvl w:val=\"0\"/><w:numId w:val=\"1\"/></w:numPr>"

    private static func cell(_ runs: String...) -> String {
        "<w:tc><w:tcPr><w:tcW w:w=\"3000\" w:type=\"dxa\"/></w:tcPr>"
            + DocxTestPackage.paragraph(runs: runs) + "</w:tc>"
    }

    private static let table = "<w:tbl><w:tblPr><w:tblStyle w:val=\"TableGrid\"/><w:tblW w:w=\"0\" w:type=\"auto\"/></w:tblPr>"
        + "<w:tblGrid><w:gridCol w:w=\"3000\"/><w:gridCol w:w=\"3000\"/><w:gridCol w:w=\"3000\"/></w:tblGrid>"
        + "<w:tr>"
        + cell(DocxTestPackage.run("项目", rPr: "<w:b/>"))
        + cell(DocxTestPackage.run("内容", rPr: "<w:b/>"))
        + cell(DocxTestPackage.run("备注", rPr: "<w:b/>"))
        + "</w:tr><w:tr>"
        + cell(DocxTestPackage.run("联系人"))
        + cell(DocxTestPackage.run("张三"))
        + cell(DocxTestPackage.run("电话：\(phoneA)"))
        + "</w:tr><w:tr>"
        + cell(DocxTestPackage.run("公司"))
        + cell(DocxTestPackage.run("杭州云溪科技有限公司"))
        + cell(DocxTestPackage.run("邮箱：\(email)；证件："), DocxTestPackage.run(nationalID, rPr: "<w:i/>"))
        + "</w:tr></w:tbl>"

    private static let body = DocxTestPackage.paragraph(
            DocxTestPackage.run("技术服务合同 Technical Services Agreement"),
            pPr: "<w:pStyle w:val=\"Heading1\"/>"
        )
        + DocxTestPackage.paragraph(
            DocxTestPackage.run("乙方：张三，身份证号：\(nationalID)，联系电话：\(phoneA)，电子邮箱："),
            DocxTestPackage.run("zhang", rPr: "<w:b/>"),
            DocxTestPackage.run("san@example.com。", rPr: "<w:i/>")
        )
        + DocxTestPackage.paragraph(
            DocxTestPackage.run("本合同于"),
            DocxTestPackage.run(chineseDate, rPr: "<w:i/>"),
            DocxTestPackage.run("在杭州市西湖区签署。")
        )
        + DocxTestPackage.paragraph(DocxTestPackage.run("服务内容：软件开发与运维服务。"), pPr: listParagraphProperties)
        + DocxTestPackage.paragraph(DocxTestPackage.run("合同总价为\(amount) 元。"), pPr: listParagraphProperties)
        + DocxTestPackage.paragraph(DocxTestPackage.run("付款期限：\(isoDate) 前支付首期款。"), pPr: listParagraphProperties)
        + table
        + DocxTestPackage.paragraph(
            DocxTestPackage.run("备用联系方式："),
            DocxTestPackage.run(phoneA, trailing: "<w:tab/>"),
            DocxTestPackage.run(phoneB)
        )
        + DocxTestPackage.paragraph(
            DocxTestPackage.run("手机 \(phoneB)", trailing: "<w:br/>"),
            DocxTestPackage.run("邮箱 \(email)")
        )
        + DocxTestPackage.sectionWithHeaderAndFooter

    private static let headerXML = DocxTestPackage.wordPart(
        rootTag: "hdr",
        body: DocxTestPackage.paragraph(
            DocxTestPackage.run("杭州云溪科技有限公司 保密文件", rPr: "<w:b/>"),
            DocxTestPackage.run(" 联系人：张三 \(phoneA)", preserve: true),
            pPr: "<w:jc w:val=\"right\"/>"
        )
    )

    private static let footerXML = DocxTestPackage.wordPart(
        rootTag: "ftr",
        body: DocxTestPackage.paragraph(
            DocxTestPackage.run("第 1 页 联系邮箱 \(email)"),
            pPr: "<w:jc w:val=\"center\"/>"
        )
    )

    private static let stylesXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:styles xmlns:w="\(DocxTestPackage.wordNamespace)">
    <w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Times New Roman" w:eastAsia="宋体"/><w:sz w:val="24"/></w:rPr></w:rPrDefault></w:docDefaults>
    <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/></w:style>
    <w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/>\
    <w:pPr><w:keepNext/><w:outlineLvl w:val="0"/></w:pPr><w:rPr><w:b/><w:sz w:val="32"/></w:rPr></w:style>
    <w:style w:type="paragraph" w:styleId="ListNumber"><w:name w:val="List Number"/><w:basedOn w:val="Normal"/>\
    <w:pPr><w:numPr><w:numId w:val="1"/></w:numPr></w:pPr></w:style>
    <w:style w:type="table" w:styleId="TableGrid"><w:name w:val="Table Grid"/><w:tblPr><w:tblBorders>\
    <w:top w:val="single" w:sz="4" w:space="0" w:color="auto"/><w:bottom w:val="single" w:sz="4" w:space="0" w:color="auto"/>\
    <w:insideH w:val="single" w:sz="4" w:space="0" w:color="auto"/><w:insideV w:val="single" w:sz="4" w:space="0" w:color="auto"/>\
    </w:tblBorders></w:tblPr></w:style>
    </w:styles>
    """

    private static let numberingXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:numbering xmlns:w="\(DocxTestPackage.wordNamespace)">
    <w:abstractNum w:abstractNumId="0"><w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="decimal"/>\
    <w:lvlText w:val="%1."/><w:lvlJc w:val="left"/><w:pPr><w:ind w:left="720" w:hanging="360"/></w:pPr></w:lvl></w:abstractNum>
    <w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>
    </w:numbering>
    """

    private func writeContract() throws -> URL {
        try DocxTestPackage.write(
            body: Self.body,
            extraParts: [
                ("word/styles.xml", Self.stylesXML),
                ("word/numbering.xml", Self.numberingXML),
                ("word/header1.xml", Self.headerXML),
                ("word/footer1.xml", Self.footerXML)
            ],
            to: workDir.appendingPathComponent("contract.docx")
        )
    }

    // MARK: - Helpers

    /// Every w:rPr and w:pPr element of a part, in document order. Redaction
    /// rewrites run text only, so these sequences must never change.
    private func formattingProperties(in xml: String) throws -> [String] {
        let regex = try NSRegularExpression(pattern: "<w:(rPr|pPr)>.*?</w:\\1>", options: [.dotMatchesLineSeparators])
        let ns = xml as NSString
        return regex.matches(in: xml, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }

    private func placeholderCount(in xml: String) throws -> Int {
        let regex = try NSRegularExpression(pattern: TokenGrammar.placeholderPattern)
        return regex.numberOfMatches(in: xml, range: NSRange(location: 0, length: (xml as NSString).length))
    }

    // MARK: - The round trip

    func testRealisticContractRoundTripsThroughTheService() throws {
        let original = try writeContract()
        let originalVisibleText = try DocxParts.restoreReportText(from: original)
        let originalBody = try DocxTestPackage.readPart(docxMainPartPath, from: original)
        let originalHeader = try DocxTestPackage.readPart("word/header1.xml", from: original)
        for value in Self.piiValues {
            XCTAssertTrue(originalVisibleText.contains(value), "fixture must carry \(value)")
        }

        let result = try LDAService.anonymize(
            input: original,
            outputDir: workDir,
            protection: .passphrase("pw"),
            createdAtISO8601: "2026-09-02T00:00:00Z",
            llmModelPath: nil
        )

        // Redacted: no fixture PII in ANY part, layout markup intact.
        for part in try DocxTestPackage.allTextParts(in: result.redactedFileURL) {
            for value in Self.piiValues where part.xml.contains(value) {
                XCTFail("\(part.path) still contains \(value)")
            }
        }
        let redactedBody = try DocxTestPackage.readPart(docxMainPartPath, from: result.redactedFileURL)
        XCTAssertEqual(try formattingProperties(in: redactedBody), try formattingProperties(in: originalBody))
        XCTAssertTrue(redactedBody.contains("<w:rPr><w:b/></w:rPr><w:t>{EMAIL_1}</w:t>"), redactedBody)
        XCTAssertTrue(redactedBody.contains("<w:rPr><w:i/></w:rPr><w:t>。</w:t>"), redactedBody)
        XCTAssertTrue(redactedBody.contains("<w:t>{PHONE_1}</w:t><w:tab/></w:r><w:r><w:t>{PHONE_2}</w:t>"), redactedBody)
        XCTAssertTrue(redactedBody.contains("<w:t>手机 {PHONE_2}</w:t><w:br/></w:r>"), redactedBody)
        XCTAssertEqual(
            try DocxTestPackage.readPart("word/styles.xml", from: result.redactedFileURL), Self.stylesXML
        )
        XCTAssertEqual(
            try DocxTestPackage.readPart("word/numbering.xml", from: result.redactedFileURL), Self.numberingXML
        )

        // Restore.
        let restored = workDir.appendingPathComponent("restored.docx")
        let report = try LDAService.restore(
            editedRedacted: result.redactedFileURL,
            mapping: result.mappingFileURL,
            protection: .passphrase("pw"),
            output: restored
        )
        XCTAssertTrue(report.orphanTokens.isEmpty)
        XCTAssertTrue(report.suspectPlaceholders.isEmpty)
        // Body 3 (ID, phone, email) + date 1 + list 2 (amount, date) + table 3
        // (phone, email, ID) + tab pair 2 + break paragraph 2 + header 1 + footer 1.
        XCTAssertEqual(report.restoredCount, 15, "every body, table, header, and footer site restores")

        XCTAssertEqual(try DocxParts.restoreReportText(from: restored), originalVisibleText)
        XCTAssertEqual(try DocxTestPackage.readPart("word/styles.xml", from: restored), Self.stylesXML)
        XCTAssertEqual(try DocxTestPackage.readPart("word/numbering.xml", from: restored), Self.numberingXML)
        let restoredBody = try DocxTestPackage.readPart(docxMainPartPath, from: restored)
        XCTAssertEqual(try formattingProperties(in: restoredBody), try formattingProperties(in: originalBody))
        XCTAssertEqual(
            try formattingProperties(in: try DocxTestPackage.readPart("word/header1.xml", from: restored)),
            try formattingProperties(in: originalHeader)
        )
        XCTAssertEqual(
            try DocxTestPackage.readPart("word/footer1.xml", from: restored), Self.footerXML,
            "a footer whose only edit was a token in its own run restores byte for byte"
        )
        for part in try DocxTestPackage.allTextParts(in: restored) {
            XCTAssertEqual(try placeholderCount(in: part.xml), 0, "\(part.path) still carries a placeholder")
        }
    }
}
