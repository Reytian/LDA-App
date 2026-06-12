//
//  CompanionWriterTests.swift
//  LDACoreTests
//
//  Tests for CompanionWriter: plain-text companion writes and the minimal .docx
//  builder. The .docx tests open the produced archive with ZIPFoundation,
//  extract word/document.xml in memory, and assert that every line and token is
//  present and XML-escaped. All fixtures live in a temporary directory so the
//  tests are hermetic and commit no binaries.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
import ZIPFoundation
@testable import LDACore

final class CompanionWriterTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CompanionWriterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: tempDir,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    /// Opens the archive at url for reading and extracts the named entry's bytes
    /// into a String. Fails the test when the entry is missing or unreadable.
    private func extractEntryText(
        from url: URL,
        entryPath: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> String {
        let archive = try Archive(url: url, accessMode: .read)
        guard let entry = archive[entryPath] else {
            XCTFail("Archive is missing entry \(entryPath)", file: file, line: line)
            return ""
        }
        var collected = Data()
        _ = try archive.extract(entry) { chunk in
            collected.append(chunk)
        }
        return String(data: collected, encoding: .utf8) ?? ""
    }

    // MARK: - writeText

    func testWriteTextRoundTrips() throws {
        let text = "Tokenized line {PERSON_1}\nSecond {COMPANY_2}\nThird"
        let url = tempDir.appendingPathComponent("companion.txt")

        try CompanionWriter.writeText(text, to: url)

        let readBack = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(readBack, text)
    }

    // MARK: - writeDocx structure

    func testWriteDocxProducesValidReadableArchive() throws {
        let text = "Line one {PERSON_1}\nLine two {DATE_2}"
        let url = tempDir.appendingPathComponent("companion.docx")

        try CompanionWriter.writeDocx(text, to: url)

        // The archive must open in read mode and expose the three required parts.
        let archive = try Archive(url: url, accessMode: .read)
        XCTAssertNotNil(archive["[Content_Types].xml"])
        XCTAssertNotNil(archive["_rels/.rels"])
        XCTAssertNotNil(archive["word/document.xml"])
    }

    func testWriteDocxDocumentXMLContainsTokensAndLines() throws {
        let lines = [
            "Engagement of {PERSON_1} of {COMPANY_1}",
            "Dated {DATE_1}, fee {AMOUNT_1}",
            "Contact {EMAIL_1}"
        ]
        let text = lines.joined(separator: "\n")
        let url = tempDir.appendingPathComponent("multi.docx")

        try CompanionWriter.writeDocx(text, to: url)
        let documentXML = try extractEntryText(from: url, entryPath: "word/document.xml")

        // Each tokenized line must appear verbatim (no escaping is needed for
        // these tokens since braces are XML-safe).
        for line in lines {
            XCTAssertTrue(
                documentXML.contains(line),
                "document.xml is missing line: \(line)"
            )
        }

        // One paragraph per line.
        let paragraphCount = documentXML.components(separatedBy: "<w:p>").count - 1
        XCTAssertEqual(paragraphCount, lines.count)
    }

    func testWriteDocxXMLEscapesSpecialCharacters() throws {
        // Characters that must be escaped inside w:t.
        let text = "A & B <tag> \"quote\" 'apos' end"
        let url = tempDir.appendingPathComponent("escape.docx")

        try CompanionWriter.writeDocx(text, to: url)
        let documentXML = try extractEntryText(from: url, entryPath: "word/document.xml")

        XCTAssertTrue(documentXML.contains("A &amp; B"))
        XCTAssertTrue(documentXML.contains("&lt;tag&gt;"))
        XCTAssertTrue(documentXML.contains("&quot;quote&quot;"))
        XCTAssertTrue(documentXML.contains("&apos;apos&apos;"))
        // The raw, unescaped angle brackets of the user text must not survive.
        XCTAssertFalse(documentXML.contains("<tag>"))
    }

    func testWriteDocxPreservesCJKText() throws {
        let text = "甲方 ACME\n乙方 Jane"
        let url = tempDir.appendingPathComponent("cjk.docx")

        try CompanionWriter.writeDocx(text, to: url)
        let documentXML = try extractEntryText(from: url, entryPath: "word/document.xml")

        XCTAssertTrue(documentXML.contains("甲方 ACME"))
        XCTAssertTrue(documentXML.contains("乙方 Jane"))
    }

    func testWriteDocxSingleLineProducesOneParagraph() throws {
        let text = "Only one line {PERSON_1}"
        let url = tempDir.appendingPathComponent("single.docx")

        try CompanionWriter.writeDocx(text, to: url)
        let documentXML = try extractEntryText(from: url, entryPath: "word/document.xml")

        let paragraphCount = documentXML.components(separatedBy: "<w:p>").count - 1
        XCTAssertEqual(paragraphCount, 1)
        XCTAssertTrue(documentXML.contains("Only one line {PERSON_1}"))
    }

    func testWriteDocxOverwritesExistingFile() throws {
        let url = tempDir.appendingPathComponent("rewrite.docx")

        try CompanionWriter.writeDocx("first {PERSON_1}", to: url)
        try CompanionWriter.writeDocx("second {COMPANY_1}", to: url)

        let documentXML = try extractEntryText(from: url, entryPath: "word/document.xml")
        XCTAssertTrue(documentXML.contains("second {COMPANY_1}"))
        XCTAssertFalse(documentXML.contains("first {PERSON_1}"))
    }

    func testWriteDocxContentTypesDeclaresMainDocument() throws {
        let url = tempDir.appendingPathComponent("ctypes.docx")
        try CompanionWriter.writeDocx("body", to: url)

        let contentTypes = try extractEntryText(from: url, entryPath: "[Content_Types].xml")
        XCTAssertTrue(
            contentTypes.contains("/word/document.xml"),
            "Content types must override the main document part"
        )
        XCTAssertTrue(
            contentTypes.contains("wordprocessingml.document.main+xml")
        )
    }

    /// A carriage return must never reach w:t content: Word renders it as a
    /// stray break and rewrites it on save, so the companion would not
    /// round-trip. CRLF and bare CR both split paragraphs exactly like LF.
    func testWriteDocxNormalizesCarriageReturns() throws {
        let url = tempDir.appendingPathComponent("crlf.docx")
        try CompanionWriter.writeDocx("alpha\r\nbeta\rgamma", to: url)

        let document = try extractEntryText(from: url, entryPath: "word/document.xml")
        XCTAssertFalse(document.contains("\r"), "raw CR leaked into w:t content")

        let imported = try DocxImporter().importDocument(url)
        XCTAssertEqual(imported.text, "alpha\nbeta\ngamma")
    }

    func testWriteDocxRelsPointsAtDocument() throws {
        let url = tempDir.appendingPathComponent("rels.docx")
        try CompanionWriter.writeDocx("body", to: url)

        let rels = try extractEntryText(from: url, entryPath: "_rels/.rels")
        XCTAssertTrue(rels.contains("Target=\"word/document.xml\""))
    }
}
