//
//  DocxIOTests.swift
//  LDACoreTests
//
//  Hermetic tests for DocxImporter and DocxRedactor. Every test builds its own
//  fixture .docx in FileManager.temporaryDirectory using ZIPFoundation, so no
//  binary fixtures are committed and tests do not depend on each other.
//
//  Coverage:
//  - import extracts visible text in run order with paragraph newlines.
//  - import maps multibyte and CJK run text to UTF-16 offsets correctly.
//  - redact substitutes tokens on the runs, preserving formatting and other runs.
//  - redact handles a replacement span that crosses two runs.
//  - restore round-trips token -> value back to the original surfaces.
//  - malformed .docx throws DocumentIOError.corrupt.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class DocxIOTests: XCTestCase {

    // MARK: - Fixture building

    /// A paragraph is an ordered list of run texts. Each run becomes its own
    /// w:r/w:t pair so tests can place PII surfaces across run boundaries.
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

    /// Build document.xml content for the given paragraphs. Each run carries a
    /// run-properties element so the test can verify formatting survives redaction.
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

    /// Write a minimal valid .docx package to a fresh temporary URL.
    private func writeFixtureDocx(_ paragraphs: [FixtureParagraph]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lda-docx-\(UUID().uuidString).docx")

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

    /// A fresh temporary output URL that is cleaned up at test teardown.
    private func tempOutputURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lda-out-\(UUID().uuidString).docx")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    /// Build a UTF-16 span from a surface's first occurrence in text.
    private func span(in text: String, surface: String, type: EntityType) -> Span {
        let ns = text as NSString
        let range = ns.range(of: surface)
        precondition(range.location != NSNotFound, "surface not found in text")
        return Span(
            start: range.location,
            end: range.location + range.length,
            type: type,
            text: surface,
            source: .llm,
            confidence: 0.9,
            priority: 0
        )
    }

    // MARK: - canImport

    func testCanImportRecognizesDocxExtension() {
        let importer = DocxImporter()
        XCTAssertTrue(importer.canImport(URL(fileURLWithPath: "/tmp/contract.DOCX")))
        XCTAssertFalse(importer.canImport(URL(fileURLWithPath: "/tmp/contract.txt")))
        XCTAssertFalse(importer.canImport(URL(fileURLWithPath: "/tmp/contract.pdf")))
    }

    // MARK: - Import text extraction

    func testImportConcatenatesRunsWithParagraphNewlines() throws {
        let url = try writeFixtureDocx([
            FixtureParagraph(runs: ["Hello ", "John Smith."]),
            FixtureParagraph(runs: ["Pay ", "Acme Inc.", " by Friday."])
        ])

        let imported = try DocxImporter().importDocument(url)

        XCTAssertEqual(imported.format, .docx)
        XCTAssertFalse(imported.isScanned)
        XCTAssertEqual(imported.pageCount, 1)
        XCTAssertEqual(imported.text, "Hello John Smith.\nPay Acme Inc. by Friday.")
    }

    func testImportNoLeadingNewlineForFirstParagraph() throws {
        let url = try writeFixtureDocx([
            FixtureParagraph(runs: ["First."]),
            FixtureParagraph(runs: ["Second."])
        ])
        let imported = try DocxImporter().importDocument(url)
        XCTAssertEqual(imported.text, "First.\nSecond.")
    }

    func testImportDecodesXMLEntities() throws {
        // The fixture builder XML-encodes, so an ampersand survives the round trip
        // into decoded visible text.
        let url = try writeFixtureDocx([
            FixtureParagraph(runs: ["Smith & Co < > \" '"])
        ])
        let imported = try DocxImporter().importDocument(url)
        XCTAssertEqual(imported.text, "Smith & Co < > \" '")
    }

    func testImportPreservesUTF16OffsetsForCJK() throws {
        // A CJK run followed by an ASCII run. The offset map must use UTF-16
        // lengths so the ASCII run begins at the correct offset.
        let url = try writeFixtureDocx([
            FixtureParagraph(runs: ["甲方：", "John"])
        ])
        let importer = DocxImporter()
        let (imported, layout) = try importer.importDocxLayout(url)

        XCTAssertEqual(imported.text, "甲方：John")
        XCTAssertEqual(layout.runs.count, 2)
        // "甲方：" is three CJK characters, each one UTF-16 code unit here.
        XCTAssertEqual(layout.runs[0].charStart, 0)
        XCTAssertEqual(layout.runs[0].charLength, 3)
        XCTAssertEqual(layout.runs[1].charStart, 3)
        XCTAssertEqual(layout.runs[1].charLength, 4)
    }

    // MARK: - Corrupt input

    func testImportThrowsCorruptOnNonZipFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lda-bad-\(UUID().uuidString).docx")
        try Data("this is not a zip".utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try DocxImporter().importDocument(url)) { error in
            guard case DocumentIOError.corrupt = error else {
                return XCTFail("expected DocumentIOError.corrupt, got \(error)")
            }
        }
    }

    func testImportThrowsCorruptWhenDocumentXMLMissing() throws {
        // A valid zip that lacks word/document.xml.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lda-empty-\(UUID().uuidString).docx")
        try DocxZip.writeArchive(parts: [("other.xml", Data("noop".utf8))], to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try DocxImporter().importDocument(url)) { error in
            guard case DocumentIOError.corrupt = error else {
                return XCTFail("expected DocumentIOError.corrupt, got \(error)")
            }
        }
    }

    // MARK: - Redact: single run

    func testRedactReplacesSurfaceWithinSingleRun() throws {
        let url = try writeFixtureDocx([
            FixtureParagraph(runs: ["Client is ", "John Smith", " today."])
        ])
        let importer = DocxImporter()
        let imported = try importer.importDocument(url)
        let replacement = Replacement(
            span: span(in: imported.text, surface: "John Smith", type: .person),
            token: "{PERSON_1}"
        )

        let out = tempOutputURL()
        try DocxRedactor.redact(original: url, replacements: [replacement], to: out)

        let redactedText = try importer.importDocument(out).text
        XCTAssertEqual(redactedText, "Client is {PERSON_1} today.")
        XCTAssertFalse(redactedText.contains("John Smith"))
    }

    func testRedactPreservesRunFormatting() throws {
        let url = try writeFixtureDocx([
            FixtureParagraph(runs: ["Name: ", "Jane Roe", "."])
        ])
        let imported = try DocxImporter().importDocument(url)
        let replacement = Replacement(
            span: span(in: imported.text, surface: "Jane Roe", type: .person),
            token: "{PERSON_1}"
        )
        let out = tempOutputURL()
        try DocxRedactor.redact(original: url, replacements: [replacement], to: out)

        // The redacted document.xml must still carry the bold run-properties that
        // the fixture put on every run.
        let xml = try DocxZip.readEntry(docxMainPartPath, from: out)
        let xmlString = String(data: xml, encoding: .utf8) ?? ""
        XCTAssertTrue(xmlString.contains("<w:b/>"), "run formatting should survive redaction")
        XCTAssertTrue(xmlString.contains("{PERSON_1}"))
    }

    // MARK: - Redact: cross-run span

    func testRedactSpanCrossingTwoRuns() throws {
        // "John" lives in run 0 and " Smith" begins run 1, so the surface
        // "John Smith" straddles the run boundary.
        let url = try writeFixtureDocx([
            FixtureParagraph(runs: ["Hello John", " Smith, welcome."])
        ])
        let importer = DocxImporter()
        let (imported, layout) = try importer.importDocxLayout(url)
        XCTAssertEqual(imported.text, "Hello John Smith, welcome.")
        XCTAssertEqual(layout.runs.count, 2)

        let replacement = Replacement(
            span: span(in: imported.text, surface: "John Smith", type: .person),
            token: "{PERSON_1}"
        )
        let out = tempOutputURL()
        try DocxRedactor.redact(original: url, replacements: [replacement], to: out)

        let redactedText = try importer.importDocument(out).text
        XCTAssertEqual(redactedText, "Hello {PERSON_1}, welcome.")
        XCTAssertFalse(redactedText.contains("John"))
        XCTAssertFalse(redactedText.contains("Smith"))
    }

    func testRedactMultipleReplacementsAcrossParagraphs() throws {
        let url = try writeFixtureDocx([
            FixtureParagraph(runs: ["Buyer ", "Acme Inc.", " pays ", "$1,000"]),
            FixtureParagraph(runs: ["Contact ", "jane@example.com"])
        ])
        let importer = DocxImporter()
        let imported = try importer.importDocument(url)

        let replacements = [
            Replacement(span: span(in: imported.text, surface: "Acme Inc.", type: .company), token: "{COMPANY_1}"),
            Replacement(span: span(in: imported.text, surface: "$1,000", type: .amount), token: "{AMOUNT_1}"),
            Replacement(span: span(in: imported.text, surface: "jane@example.com", type: .email), token: "{EMAIL_1}")
        ]
        let out = tempOutputURL()
        try DocxRedactor.redact(original: url, replacements: replacements, to: out)

        let redactedText = try importer.importDocument(out).text
        XCTAssertEqual(redactedText, "Buyer {COMPANY_1} pays {AMOUNT_1}\nContact {EMAIL_1}")
    }

    // MARK: - Restore round-trip

    func testRestoreRoundTripsSingleRun() throws {
        let url = try writeFixtureDocx([
            FixtureParagraph(runs: ["Client is ", "John Smith", " today."])
        ])
        let importer = DocxImporter()
        let imported = try importer.importDocument(url)
        let replacement = Replacement(
            span: span(in: imported.text, surface: "John Smith", type: .person),
            token: "{PERSON_1}"
        )

        let redacted = tempOutputURL()
        try DocxRedactor.redact(original: url, replacements: [replacement], to: redacted)

        let restored = tempOutputURL()
        try DocxRedactor.restore(
            redactedDocx: redacted,
            tokenToValue: ["{PERSON_1}": "John Smith"],
            to: restored
        )

        let restoredText = try importer.importDocument(restored).text
        XCTAssertEqual(restoredText, "Client is John Smith today.")
    }

    func testRestoreRoundTripsCrossRunSpan() throws {
        let url = try writeFixtureDocx([
            FixtureParagraph(runs: ["Hello John", " Smith, welcome."])
        ])
        let importer = DocxImporter()
        let imported = try importer.importDocument(url)
        let replacement = Replacement(
            span: span(in: imported.text, surface: "John Smith", type: .person),
            token: "{PERSON_1}"
        )

        let redacted = tempOutputURL()
        try DocxRedactor.redact(original: url, replacements: [replacement], to: redacted)

        let restored = tempOutputURL()
        try DocxRedactor.restore(
            redactedDocx: redacted,
            tokenToValue: ["{PERSON_1}": "John Smith"],
            to: restored
        )

        // The original visible text returns even though the surface was split
        // across two runs before redaction.
        let restoredText = try importer.importDocument(restored).text
        XCTAssertEqual(restoredText, "Hello John Smith, welcome.")
    }

    func testRestoreLeavesUnknownTokensUntouched() throws {
        let url = try writeFixtureDocx([
            FixtureParagraph(runs: ["A ", "John Smith", " B"])
        ])
        let importer = DocxImporter()
        let imported = try importer.importDocument(url)
        let replacement = Replacement(
            span: span(in: imported.text, surface: "John Smith", type: .person),
            token: "{PERSON_1}"
        )
        let redacted = tempOutputURL()
        try DocxRedactor.redact(original: url, replacements: [replacement], to: redacted)

        // Empty mapping: the token must survive so an orphan guard can see it.
        let restored = tempOutputURL()
        try DocxRedactor.restore(redactedDocx: redacted, tokenToValue: [:], to: restored)

        let restoredText = try importer.importDocument(restored).text
        XCTAssertEqual(restoredText, "A {PERSON_1} B")
    }

    func testFullRoundTripMultipleEntities() throws {
        let url = try writeFixtureDocx([
            FixtureParagraph(runs: ["Buyer ", "Acme Inc.", " pays ", "$1,000"]),
            FixtureParagraph(runs: ["Contact ", "jane@example.com"])
        ])
        let importer = DocxImporter()
        let imported = try importer.importDocument(url)
        let original = imported.text

        let replacements = [
            Replacement(span: span(in: original, surface: "Acme Inc.", type: .company), token: "{COMPANY_1}"),
            Replacement(span: span(in: original, surface: "$1,000", type: .amount), token: "{AMOUNT_1}"),
            Replacement(span: span(in: original, surface: "jane@example.com", type: .email), token: "{EMAIL_1}")
        ]
        let redacted = tempOutputURL()
        try DocxRedactor.redact(original: url, replacements: replacements, to: redacted)

        let restored = tempOutputURL()
        try DocxRedactor.restore(
            redactedDocx: redacted,
            tokenToValue: [
                "{COMPANY_1}": "Acme Inc.",
                "{AMOUNT_1}": "$1,000",
                "{EMAIL_1}": "jane@example.com"
            ],
            to: restored
        )

        let restoredText = try importer.importDocument(restored).text
        XCTAssertEqual(restoredText, original)
    }

    func testRedactKeepsAmpersandSafeThroughRoundTrip() throws {
        // A value containing "&" must be XML-escaped on restore so the package
        // stays well-formed and import decodes it back cleanly.
        let url = try writeFixtureDocx([
            FixtureParagraph(runs: ["Owner ", "Placeholder", " signs."])
        ])
        let importer = DocxImporter()
        let imported = try importer.importDocument(url)
        let replacement = Replacement(
            span: span(in: imported.text, surface: "Placeholder", type: .company),
            token: "{COMPANY_1}"
        )
        let redacted = tempOutputURL()
        try DocxRedactor.redact(original: url, replacements: [replacement], to: redacted)

        let restored = tempOutputURL()
        try DocxRedactor.restore(
            redactedDocx: redacted,
            tokenToValue: ["{COMPANY_1}": "Smith & Wesson <LLC>"],
            to: restored
        )

        let restoredText = try importer.importDocument(restored).text
        XCTAssertEqual(restoredText, "Owner Smith & Wesson <LLC> signs.")
    }
}
