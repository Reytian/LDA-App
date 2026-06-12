//
//  TextDocumentIOTests.swift
//  LDACoreTests
//
//  Tests for TextDocumentIO: extension-based canImport, UTF-8 import with
//  encoding fallback, the unreadable error path, and exportText round-trips.
//  Every fixture is generated in a temporary directory so the tests are hermetic
//  and commit no binaries.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class TextDocumentIOTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TextDocumentIOTests-\(UUID().uuidString)", isDirectory: true)
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

    // MARK: - canImport

    func testCanImportRecognizesSupportedExtensions() {
        let io = TextDocumentIO()
        XCTAssertTrue(io.canImport(tempDir.appendingPathComponent("a.txt")))
        XCTAssertTrue(io.canImport(tempDir.appendingPathComponent("a.text")))
        XCTAssertTrue(io.canImport(tempDir.appendingPathComponent("a.md")))
    }

    func testCanImportIsCaseInsensitive() {
        let io = TextDocumentIO()
        XCTAssertTrue(io.canImport(tempDir.appendingPathComponent("A.TXT")))
        XCTAssertTrue(io.canImport(tempDir.appendingPathComponent("notes.MD")))
    }

    func testCanImportRejectsUnsupportedExtensions() {
        let io = TextDocumentIO()
        XCTAssertFalse(io.canImport(tempDir.appendingPathComponent("a.docx")))
        XCTAssertFalse(io.canImport(tempDir.appendingPathComponent("a.pdf")))
        XCTAssertFalse(io.canImport(tempDir.appendingPathComponent("a")))
    }

    // MARK: - importDocument

    func testImportReadsUTF8AndReturnsExpectedMetadata() throws {
        let io = TextDocumentIO()
        let content = "First line\nSecond line with token {PERSON_1}\nThird"
        let url = tempDir.appendingPathComponent("doc.txt")
        try content.data(using: .utf8)!.write(to: url)

        let imported = try io.importDocument(url)

        XCTAssertEqual(imported.text, content)
        XCTAssertEqual(imported.format, .plainText)
        XCTAssertFalse(imported.isScanned)
        XCTAssertEqual(imported.pageCount, 1)
    }

    func testImportPreservesUTF16OffsetsForCJKAndMultibyte() throws {
        // Confirm the imported text aligns with UTF-16 offsets the engine uses.
        let io = TextDocumentIO()
        let content = "甲方 ACME, emoji \u{1F600} tail"
        let url = tempDir.appendingPathComponent("cjk.md")
        try content.data(using: .utf8)!.write(to: url)

        let imported = try io.importDocument(url)

        XCTAssertEqual(imported.text, content)
        // The emoji is a surrogate pair: two UTF-16 code units.
        let utf16Count = imported.text.utf16.count
        XCTAssertEqual(utf16Count, content.utf16.count)
    }

    func testImportFallsBackToNonUTF8Encoding() throws {
        // Latin-1 bytes that are not valid UTF-8: 0xE9 alone is invalid UTF-8 but
        // decodes as e-acute in ISO Latin 1. The byte count is kept odd so the
        // UTF-16 fallback (which requires an even byte count) fails and decoding
        // reaches ISO Latin 1.
        let io = TextDocumentIO()
        var bytes: [UInt8] = Array("Cafe".utf8)
        bytes.append(0xE9)
        let data = Data(bytes)
        XCTAssertNil(String(data: data, encoding: .utf8), "Fixture must be invalid UTF-8")
        XCTAssertEqual(data.count % 2, 1, "Fixture must be odd length so UTF-16 fails")

        let url = tempDir.appendingPathComponent("latin1.txt")
        try data.write(to: url)

        let imported = try io.importDocument(url)
        XCTAssertEqual(imported.text, "Cafe\u{00E9}")
    }

    func testImportThrowsUnreadableForMissingFile() {
        let io = TextDocumentIO()
        let url = tempDir.appendingPathComponent("does-not-exist.txt")

        XCTAssertThrowsError(try io.importDocument(url)) { error in
            guard case DocumentIOError.unreadable = error else {
                return XCTFail("Expected DocumentIOError.unreadable, got \(error)")
            }
        }
    }

    func testImportEmptyFileSucceeds() throws {
        let io = TextDocumentIO()
        let url = tempDir.appendingPathComponent("empty.txt")
        try Data().write(to: url)

        let imported = try io.importDocument(url)
        XCTAssertEqual(imported.text, "")
        XCTAssertEqual(imported.pageCount, 1)
    }

    // MARK: - exportText

    func testExportTextWritesUTF8RoundTrip() throws {
        let text = "Restored value Jane Doe\nLine two 甲方\nDone"
        let url = tempDir.appendingPathComponent("out.txt")

        try TextDocumentIO.exportText(text, to: url)

        let readBack = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(readBack, text)
    }

    func testExportThenImportRoundTrips() throws {
        let io = TextDocumentIO()
        let text = "Edit surface with {COMPANY_1} and {DATE_2}\nSecond paragraph"
        let url = tempDir.appendingPathComponent("surface.txt")

        try TextDocumentIO.exportText(text, to: url)
        let imported = try io.importDocument(url)

        XCTAssertEqual(imported.text, text)
    }

    /// Windows files arrive with CRLF line endings and often a UTF-8 BOM.
    /// Import must normalize both: a BOM surviving as U+FEFF shifts every
    /// detection offset, and a CR surviving into the companion docx breaks the
    /// edit surface in Word. Line-ending normalization is deliberate; the
    /// restored output is LF-normalized.
    func testImportNormalizesCRLFAndStripsBOM() throws {
        let url = tempDir.appendingPathComponent("windows.txt")
        var bytes = Data([0xEF, 0xBB, 0xBF])
        bytes.append(Data("line1\r\nline2\rline3\nline4".utf8))
        try bytes.write(to: url)

        let imported = try TextDocumentIO().importDocument(url)

        XCTAssertEqual(imported.text, "line1\nline2\nline3\nline4")
        XCTAssertFalse(imported.text.unicodeScalars.contains("\u{FEFF}"))
    }

    func testExportOverwritesExistingFile() throws {
        let url = tempDir.appendingPathComponent("over.txt")
        try TextDocumentIO.exportText("old content here", to: url)
        try TextDocumentIO.exportText("new", to: url)

        let readBack = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(readBack, "new")
    }
}
