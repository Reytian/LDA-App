//
//  DocxBreakElementsTests.swift
//  LDACoreTests
//
//  D1: WordprocessingML places tabs and line breaks OUTSIDE w:t, as empty
//  run children (w:tab, w:br, w:cr). A parser that reads only w:t glues the
//  text on both sides together: two tab-separated phone numbers become one
//  22-digit string no phone pattern matches, and a phone followed by a soft
//  line break and a date becomes a bank-account-shaped digit run. The break
//  elements must contribute "\t" and "\n" to the concatenated text while
//  their markup is copied through verbatim, and no replacement may ever
//  straddle one of those synthetic characters.
//
//  House rules: all comments and strings in English. Fixture values may be
//  Chinese. No em-dash and no en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class DocxBreakElementsTests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lda-breaks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    private static let phoneA = "13812345678"
    private static let phoneB = "13912345678"
    private static let phoneC = "13700001111"

    // MARK: - Parser

    /// Every run-level break element contributes one character to the text
    /// and none to any run, while tab STOPS in w:pPr/w:tabs contribute nothing.
    func testParserMapsRunBreaksToTextAndKeepsMarkupVerbatim() throws {
        let body = "<w:p><w:pPr><w:tabs><w:tab w:val=\"left\" w:pos=\"720\"/></w:tabs></w:pPr>"
            + "<w:r><w:t>A</w:t><w:tab/><w:t>B</w:t><w:br/><w:t>C</w:t><w:cr/><w:t>D</w:t>"
            + "<w:br w:type=\"page\"/><w:t>E</w:t></w:r></w:p>"
        let url = try DocxTestPackage.write(body: body, to: workDir.appendingPathComponent("breaks.docx"))

        let (imported, layout) = try DocxImporter().importDocxLayout(url)

        XCTAssertEqual(imported.text, "A\tB\nC\nD\nE")
        XCTAssertEqual(layout.runs.map(\.charStart), [0, 2, 4, 6, 8])
        XCTAssertEqual(layout.runs.map(\.charLength), [1, 1, 1, 1, 1])
        let serialized = String(decoding: DocxDocumentXML.serialize(layout), as: UTF8.self)
        XCTAssertEqual(serialized.components(separatedBy: "<w:tab/>").count, 2, "the run tab survives")
        XCTAssertTrue(
            serialized.contains("<w:tabs><w:tab w:val=\"left\" w:pos=\"720\"/></w:tabs>"),
            "the tab stop survives verbatim"
        )
        XCTAssertTrue(serialized.contains("<w:br w:type=\"page\"/>"))
        XCTAssertTrue(serialized.contains("<w:cr/>"))
    }

    // MARK: - SpanSplitter

    /// A detected span carrying a tab is split into per-run parts exactly like
    /// one carrying a paragraph newline.
    func testSplitterSplitsSpansAtTabs() {
        let text = "备用联系方式：\(Self.phoneA)\t\(Self.phoneB)"
        let surface = "\(Self.phoneA)\t\(Self.phoneB)"
        let start = (text as NSString).range(of: surface).location
        let span = Span(
            start: start, end: start + (surface as NSString).length, type: .phone, text: surface,
            source: .deterministic, confidence: 0.9, priority: 60
        )

        let split = SpanSplitter.splitAtBreaks([span], in: text)

        XCTAssertEqual(split.map(\.text), [Self.phoneA, Self.phoneB])
        let ns = text as NSString
        for part in split {
            XCTAssertEqual(ns.substring(with: NSRange(location: part.start, length: part.end - part.start)), part.text)
        }
    }

    // MARK: - Service round trips

    /// Two phone numbers separated only by a w:tab must BOTH be detected,
    /// redacted, and restored, with the tab still between them.
    func testTabSeparatedPhonesAreBothRedactedAndRestored() throws {
        let original = try DocxTestPackage.write(
            body: DocxTestPackage.paragraph(
                DocxTestPackage.run("备用联系方式："),
                DocxTestPackage.run(Self.phoneA, trailing: "<w:tab/>"),
                DocxTestPackage.run(Self.phoneB)
            ),
            to: workDir.appendingPathComponent("phones.docx")
        )
        let importer = DocxImporter()
        let originalText = try importer.importDocument(original).text
        XCTAssertEqual(originalText, "备用联系方式：\(Self.phoneA)\t\(Self.phoneB)")

        let result = try LDAService.anonymize(
            input: original,
            outputDir: workDir,
            protection: .passphrase("pw"),
            createdAtISO8601: "2026-09-02T00:00:00Z",
            llmModelPath: nil
        )

        let redactedText = try importer.importDocument(result.redactedFileURL).text
        XCTAssertEqual(redactedText, "备用联系方式：{PHONE_1}\t{PHONE_2}")
        let redactedXML = try DocxTestPackage.readPart(docxMainPartPath, from: result.redactedFileURL)
        XCTAssertFalse(redactedXML.contains(Self.phoneA), "first phone leaked")
        XCTAssertFalse(redactedXML.contains(Self.phoneB), "second phone leaked")
        XCTAssertTrue(redactedXML.contains("<w:t>{PHONE_1}</w:t><w:tab/></w:r>"), redactedXML)

        let restored = workDir.appendingPathComponent("restored.docx")
        let report = try LDAService.restore(
            editedRedacted: result.redactedFileURL,
            mapping: result.mappingFileURL,
            protection: .passphrase("pw"),
            output: restored
        )
        XCTAssertEqual(report.restoredCount, 2)
        XCTAssertEqual(try importer.importDocument(restored).text, originalText)
    }

    /// Text on each side of a soft line break is detected on its own side and
    /// restores into the run it came from, with the w:br still between them.
    func testSoftLineBreakKeepsBothSidesDetectable() throws {
        let email = "zhangsan@example.com"
        let original = try DocxTestPackage.write(
            body: DocxTestPackage.paragraph(
                DocxTestPackage.run("手机 \(Self.phoneC)", trailing: "<w:br/>"),
                DocxTestPackage.run("邮箱 \(email)")
            ),
            to: workDir.appendingPathComponent("break.docx")
        )
        let importer = DocxImporter()
        let originalText = try importer.importDocument(original).text
        XCTAssertEqual(originalText, "手机 \(Self.phoneC)\n邮箱 \(email)")

        let result = try LDAService.anonymize(
            input: original,
            outputDir: workDir,
            protection: .passphrase("pw"),
            createdAtISO8601: "2026-09-02T00:00:00Z",
            llmModelPath: nil
        )

        XCTAssertEqual(
            result.entities.map(\.type).sorted { $0.rawValue < $1.rawValue },
            [.email, .phone]
        )
        let redactedText = try importer.importDocument(result.redactedFileURL).text
        XCTAssertEqual(redactedText, "手机 {PHONE_1}\n邮箱 {EMAIL_1}")
        let redactedXML = try DocxTestPackage.readPart(docxMainPartPath, from: result.redactedFileURL)
        XCTAssertTrue(redactedXML.contains("<w:t>手机 {PHONE_1}</w:t><w:br/></w:r>"), redactedXML)
        XCTAssertTrue(redactedXML.contains("<w:t>邮箱 {EMAIL_1}</w:t>"), redactedXML)

        let restored = workDir.appendingPathComponent("restored.docx")
        _ = try LDAService.restore(
            editedRedacted: result.redactedFileURL,
            mapping: result.mappingFileURL,
            protection: .passphrase("pw"),
            output: restored
        )
        XCTAssertEqual(try importer.importDocument(restored).text, originalText)
    }

    /// The probe's shape: a phone, a soft line break, then an ISO date. With
    /// the break invisible the two glued into a 21-digit run that was
    /// tokenized as a bank account and restored with the date on the wrong
    /// side of the break. Both values must now be redacted, the break must
    /// stay where it was, and the restore must reproduce the original text.
    /// (The engine may still type the pair as one PHONE because its grouped
    /// digit pattern bridges a single whitespace; that is over-redaction, not
    /// a leak, and identical for plain text, so it is not pinned here.)
    func testPhoneBreakDateIsNoLongerReadAsABankAccount() throws {
        let date = "2026-04-01"
        let original = try DocxTestPackage.write(
            body: DocxTestPackage.paragraph(
                DocxTestPackage.run("手机 \(Self.phoneC)", trailing: "<w:br/>"),
                DocxTestPackage.run("\(date) 起生效")
            ),
            to: workDir.appendingPathComponent("probe-shape.docx")
        )
        let importer = DocxImporter()
        let originalText = try importer.importDocument(original).text

        let result = try LDAService.anonymize(
            input: original,
            outputDir: workDir,
            protection: .passphrase("pw"),
            createdAtISO8601: "2026-09-02T00:00:00Z",
            llmModelPath: nil
        )

        XCTAssertFalse(result.entities.contains { $0.type == .bankAccount }, "\(result.entities)")
        let redactedXML = try DocxTestPackage.readPart(docxMainPartPath, from: result.redactedFileURL)
        XCTAssertFalse(redactedXML.contains(Self.phoneC), "phone leaked")
        XCTAssertFalse(redactedXML.contains(date), "date leaked")
        XCTAssertTrue(redactedXML.contains("</w:t><w:br/></w:r><w:r><w:t>"), "break must stay between the runs: \(redactedXML)")
        XCTAssertTrue(redactedXML.contains(" 起生效</w:t>"), "text after the break stays on its side: \(redactedXML)")

        let restored = workDir.appendingPathComponent("restored.docx")
        _ = try LDAService.restore(
            editedRedacted: result.redactedFileURL,
            mapping: result.mappingFileURL,
            protection: .passphrase("pw"),
            output: restored
        )
        XCTAssertEqual(try importer.importDocument(restored).text, originalText)
    }

    /// A token that an editor moved so it straddles a break element is left
    /// verbatim rather than written across the break: the value would land in
    /// one run while the tab stayed behind, changing the document's shape.
    func testRestoreRefusesATokenStraddlingATab() throws {
        let edited = try DocxTestPackage.write(
            body: DocxTestPackage.paragraph(
                DocxTestPackage.run("{PHONE", trailing: "<w:tab/>"),
                DocxTestPackage.run("_1}")
            ),
            to: workDir.appendingPathComponent("straddle.docx")
        )

        let restored = workDir.appendingPathComponent("restored.docx")
        try DocxRedactor.restore(
            redactedDocx: edited,
            tokenToValue: ["{PHONE_1}": Self.phoneA],
            to: restored
        )

        XCTAssertEqual(try DocxImporter().importDocument(restored).text, "{PHONE\t_1}")
    }
}
