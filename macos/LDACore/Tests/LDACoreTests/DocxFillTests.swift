//
//  DocxFillTests.swift
//  LDACoreTests
//
//  Filling blanks in .docx drafts through DocxFiller: value lands, formatting
//  survives, offsets map through DocxImporter text, originals untouched.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class DocxFillTests: XCTestCase {

    // MARK: - Fixture building
    //
    // Deliberately copied from DocxIOTests for test isolation. The duplication
    // is intentional: each test file stands alone without shared helper coupling.

    private struct FixtureParagraph {
        var runs: [String]
    }

    private static let contentTypesXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
    <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
    <Default Extension="xml" ContentType="application/xml"/>
    <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
    </Types>
    """

    private static let relsXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
    </Relationships>
    """

    private func buildDocumentXML(_ paragraphs: [FixtureParagraph]) -> String {
        var body = ""
        for paragraph in paragraphs {
            body += "<w:p>"
            for runText in paragraph.runs {
                body += "<w:r><w:rPr><w:b/></w:rPr>"
                body += "<w:t xml:space=\"preserve\">"
                body += xmlEncode(runText)
                body += "</w:t></w:r>"
            }
            body += "</w:p>"
        }
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:body>\(body)</w:body>
        </w:document>
        """
    }

    private func writeFixtureDocx(_ paragraphs: [FixtureParagraph]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lda-fill-\(UUID().uuidString).docx")

        let documentXML = buildDocumentXML(paragraphs)
        let parts: [(String, Data)] = [
            ("[Content_Types].xml", Data(Self.contentTypesXML.utf8)),
            ("_rels/.rels", Data(Self.relsXML.utf8)),
            ("word/document.xml", Data(documentXML.utf8))
        ]

        try DocxZip.writeArchive(parts: parts, to: url)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func tempOutputURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lda-fill-out-\(UUID().uuidString).docx")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    /// Build a UTF-16 span from a surface's first occurrence in text.
    private func blankSpan(in text: String, surface: String) -> Span {
        let ns = text as NSString
        let range = ns.range(of: surface)
        precondition(range.location != NSNotFound, "surface not found in text: \(surface)")
        return Span(
            start: range.location,
            end: range.location + range.length,
            type: .unknown,
            text: surface,
            source: .manual,
            confidence: 1,
            priority: 0
        )
    }

    // MARK: - Tests

    func testFillReplacesBracketBlankWithValue() throws {
        let docx = try writeFixtureDocx([.init(runs: ["between [Company Name], a company"])])
        let imported = try DocxImporter().importDocument(docx)
        let span = blankSpan(in: imported.text, surface: "[Company Name]")
        let out = tempOutputURL()
        try DocxFiller.fill(
            original: docx,
            fills: [DocxFill(span: span, value: "Acme Holdings Limited")],
            to: out
        )
        let filled = try DocxImporter().importDocument(out)
        XCTAssertTrue(filled.text.contains("between Acme Holdings Limited, a company"))
        XCTAssertFalse(filled.text.contains("[Company Name]"))
    }

    func testFillValueWithAmpersandSurvivesRoundTrip() throws {
        let docx = try writeFixtureDocx([.init(runs: ["supplier: [Supplier]"])])
        let imported = try DocxImporter().importDocument(docx)
        let span = blankSpan(in: imported.text, surface: "[Supplier]")
        let out = tempOutputURL()
        try DocxFiller.fill(
            original: docx,
            fills: [DocxFill(span: span, value: "Smith & Wesson <Asia> Ltd")],
            to: out
        )
        let filled = try DocxImporter().importDocument(out)
        XCTAssertTrue(filled.text.contains("Smith & Wesson <Asia> Ltd"))
    }

    func testFillMultipleBlanksAcrossParagraphs() throws {
        // Use distinct surfaces so range(of:) finds the correct occurrence for
        // each blank. "on the _10_" vs "_JUNE_" vs "[Address]" are unambiguous.
        let docx = try writeFixtureDocx([
            .init(runs: ["this _10_ day of _JUNE_"]),
            .init(runs: ["registered office at [Address]"])
        ])
        let imported = try DocxImporter().importDocument(docx)
        let fills = [
            DocxFill(span: blankSpan(in: imported.text, surface: "_10_"), value: "10th"),
            DocxFill(span: blankSpan(in: imported.text, surface: "_JUNE_"), value: "June"),
            DocxFill(span: blankSpan(in: imported.text, surface: "[Address]"), value: "1 Main Street")
        ]
        let out = tempOutputURL()
        try DocxFiller.fill(original: docx, fills: fills, to: out)
        let filled = try DocxImporter().importDocument(out)
        XCTAssertTrue(filled.text.contains("this 10th day of June"))
        XCTAssertTrue(filled.text.contains("registered office at 1 Main Street"))
    }

    func testOriginalFileUntouched() throws {
        let docx = try writeFixtureDocx([.init(runs: ["x [B] y"])])
        let before = try Data(contentsOf: docx)
        let imported = try DocxImporter().importDocument(docx)
        let out = tempOutputURL()
        try DocxFiller.fill(
            original: docx,
            fills: [DocxFill(span: blankSpan(in: imported.text, surface: "[B]"), value: "v")],
            to: out
        )
        XCTAssertEqual(try Data(contentsOf: docx), before)
    }

    func testRunFormattingPreserved() throws {
        // Mirror DocxIOTests.testRedactPreservesRunFormatting: the fixture puts
        // <w:b/> on every run; after filling, the rPr element must still be present
        // in word/document.xml.
        let docx = try writeFixtureDocx([.init(runs: ["Name: ", "[BLANK]", "."])])
        let imported = try DocxImporter().importDocument(docx)
        let span = blankSpan(in: imported.text, surface: "[BLANK]")
        let out = tempOutputURL()
        try DocxFiller.fill(
            original: docx,
            fills: [DocxFill(span: span, value: "Jane Roe")],
            to: out
        )
        let xml = try DocxZip.readEntry(docxMainPartPath, from: out)
        let xmlString = String(data: xml, encoding: .utf8) ?? ""
        XCTAssertTrue(xmlString.contains("<w:b/>"), "run formatting should survive fill")
        XCTAssertTrue(xmlString.contains("Jane Roe"))
        XCTAssertFalse(xmlString.contains("[BLANK]"))
    }

    func testFillSpanCrossingTwoRuns() throws {
        // "[CO" lives in run 0 and "MPANY]" begins run 1, so the surface
        // "[COMPANY]" straddles the run boundary. The fill value lands in the
        // first overlapped run; the covered text is deleted from the second run.
        let docx = try writeFixtureDocx([
            .init(runs: ["signed by [CO", "MPANY] today."])
        ])
        let importer = DocxImporter()
        let (imported, layout) = try importer.importDocxLayout(docx)
        XCTAssertEqual(imported.text, "signed by [COMPANY] today.")
        XCTAssertEqual(layout.runs.count, 2)

        let span = blankSpan(in: imported.text, surface: "[COMPANY]")
        let out = tempOutputURL()
        try DocxFiller.fill(
            original: docx,
            fills: [DocxFill(span: span, value: "Initech Ltd")],
            to: out
        )
        let filled = try importer.importDocument(out)
        XCTAssertEqual(filled.text, "signed by Initech Ltd today.")
        XCTAssertFalse(filled.text.contains("[CO"))
        XCTAssertFalse(filled.text.contains("MPANY]"))
    }
}
