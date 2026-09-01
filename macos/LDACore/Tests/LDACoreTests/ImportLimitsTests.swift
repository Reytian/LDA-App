//
//  ImportLimitsTests.swift
//  LDACoreTests
//
//  The import-boundary ceilings. What matters is that the guard sits on EVERY
//  importer, not only on the service facade: a caller that reaches for
//  DocxImporter or TextDocumentIO directly (LDAFillService does) must hit the
//  same ceiling.
//
//  The oversize fixtures are sparse files, so a 200 MB limit can be exercised
//  without writing 200 MB.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
import ImageIO
@testable import LDACore

final class ImportLimitsTests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImportLimitsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir, FileManager.default.fileExists(atPath: workDir.path) {
            try FileManager.default.removeItem(at: workDir)
        }
        try super.tearDownWithError()
    }

    /// Create a sparse file of the given logical size. The file reports its full
    /// size to the size check while occupying almost no disk.
    private func makeSparseFile(named name: String, bytes: Int) throws -> URL {
        let url = workDir.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(bytes))
        return url
    }

    // MARK: - The check itself

    func testAnOrdinarySizedFilePasses() throws {
        let url = workDir.appendingPathComponent("normal.txt")
        try Data(repeating: 0x41, count: 4096).write(to: url)
        XCTAssertNoThrow(try ImportLimits.enforceDocumentSize(at: url))
    }

    func testAnOversizeFileIsRejected() throws {
        let url = try makeSparseFile(named: "huge.txt", bytes: ImportLimits.maxDocumentBytes + 1)

        XCTAssertThrowsError(try ImportLimits.enforceDocumentSize(at: url)) { error in
            guard case DocumentIOError.tooLarge(let detail) = error else {
                XCTFail("Expected tooLarge, got \(error)")
                return
            }
            XCTAssertTrue(
                detail.contains("huge.txt"),
                "the message should name the file the lawyer picked, got: \(detail)"
            )
        }
    }

    func testExactlyAtTheLimitIsAccepted() throws {
        // The boundary is inclusive: a file exactly at the ceiling is fine, so
        // the limit reads as "up to 200 MB", not "under 200 MB".
        let url = try makeSparseFile(named: "boundary.txt", bytes: ImportLimits.maxDocumentBytes)
        XCTAssertNoThrow(try ImportLimits.enforceDocumentSize(at: url))
    }

    func testAMissingFileIsNotASizeFailure() {
        // Size is not this check's job to diagnose absence; the importer that
        // follows produces the specific "not found" error.
        let missing = workDir.appendingPathComponent("nope.txt")
        XCTAssertNoThrow(try ImportLimits.enforceDocumentSize(at: missing))
    }

    // MARK: - Decoded image budget

    func testDecodedImagePixelBudgetAcceptsTheExactBoundary() {
        XCTAssertNoThrow(
            try ImportLimits.enforceDecodedImageSize(
                width: 10_000,
                height: 5_000,
                filename: "boundary.png"
            )
        )
    }

    func testDecodedImagePixelBudgetRejectsOnePixelBeyondTheBoundary() {
        XCTAssertThrowsError(
            try ImportLimits.enforceDecodedImageSize(
                width: 10_000,
                height: 5_001,
                filename: "compressed.png"
            )
        ) { error in
            guard case DocumentIOError.tooLarge(let detail) = error else {
                return XCTFail("expected tooLarge, got \(error)")
            }
            XCTAssertTrue(detail.contains("compressed.png"))
            XCTAssertTrue(detail.contains("50 megapixel"))
        }
    }

    func testDecodedImagePixelBudgetCannotBeBypassedByIntegerOverflow() {
        XCTAssertThrowsError(
            try ImportLimits.enforceDecodedImageSize(
                width: Int.max,
                height: 2,
                filename: "hostile.jpg"
            )
        ) { error in
            guard case DocumentIOError.tooLarge = error else {
                return XCTFail("expected tooLarge, got \(error)")
            }
        }
    }

    func testDecodedImagePixelBudgetRejectsNonpositiveDimensions() {
        for (width, height) in [(0, 100), (100, 0), (-1, 100), (100, -1)] {
            XCTAssertThrowsError(
                try ImportLimits.enforceDecodedImageSize(
                    width: width,
                    height: height,
                    filename: "invalid.png"
                )
            ) { error in
                guard case DocumentIOError.corrupt(let detail) = error else {
                    return XCTFail("expected corrupt, got \(error)")
                }
                XCTAssertTrue(detail.contains("invalid.png"))
                XCTAssertTrue(detail.contains("positive pixel dimensions"))
            }
        }
    }

    func testImageMetadataRequiresPositiveIntegerPixelDimensionsBeforeDecode() throws {
        XCTAssertThrowsError(
            try ImageTextExtractor.validatedPixelDimensions(
                in: nil,
                filename: "missing-metadata.png"
            )
        )
        XCTAssertThrowsError(
            try ImageTextExtractor.validatedPixelDimensions(
                in: [
                    kCGImagePropertyPixelWidth: NSNumber(value: 10.5),
                    kCGImagePropertyPixelHeight: NSNumber(value: 100)
                ],
                filename: "fractional-metadata.png"
            )
        )

        let dimensions = try ImageTextExtractor.validatedPixelDimensions(
            in: [
                kCGImagePropertyPixelWidth: NSNumber(value: 2_000),
                kCGImagePropertyPixelHeight: NSNumber(value: 1_500)
            ],
            filename: "ordinary.png"
        )
        XCTAssertEqual(dimensions.width, 2_000)
        XCTAssertEqual(dimensions.height, 1_500)
    }

    // MARK: - Every importer enforces it

    func testTextImporterRejectsAnOversizeFile() throws {
        let url = try makeSparseFile(named: "huge.txt", bytes: ImportLimits.maxDocumentBytes + 1)
        XCTAssertThrowsError(try TextDocumentIO().importDocument(url)) { error in
            guard case DocumentIOError.tooLarge = error else {
                XCTFail("TextDocumentIO should enforce the ceiling, got \(error)")
                return
            }
        }
    }

    func testDocxImporterRejectsAnOversizeFile() throws {
        let url = try makeSparseFile(named: "huge.docx", bytes: ImportLimits.maxDocumentBytes + 1)
        XCTAssertThrowsError(try DocxImporter().importDocument(url)) { error in
            guard case DocumentIOError.tooLarge = error else {
                XCTFail("DocxImporter should enforce the ceiling, got \(error)")
                return
            }
        }
    }

    func testPdfImporterRejectsAnOversizeFile() throws {
        let url = try makeSparseFile(named: "huge.pdf", bytes: ImportLimits.maxDocumentBytes + 1)
        XCTAssertThrowsError(try PdfImporter().importDocument(url)) { error in
            guard case DocumentIOError.tooLarge = error else {
                XCTFail("PdfImporter should enforce the ceiling, got \(error)")
                return
            }
        }
    }

    func testTheServiceFacadeRejectsAnOversizeFile() throws {
        // The facade routes by extension; the ceiling has to hold there too,
        // since that is the path the GUI and CLI take.
        let url = try makeSparseFile(named: "huge.txt", bytes: ImportLimits.maxDocumentBytes + 1)
        XCTAssertThrowsError(try LDAService.importDocument(url, extension: "txt")) { error in
            guard case DocumentIOError.tooLarge = error else {
                XCTFail("Expected tooLarge from the facade, got \(error)")
                return
            }
        }
    }

    // MARK: - Reporting

    func testHumanSizesReadSensibly() {
        XCTAssertEqual(ImportLimits.describe(bytes: 512), "512 bytes")
        XCTAssertEqual(ImportLimits.describe(bytes: 200 * 1024 * 1024), "200 MB")
        XCTAssertEqual(ImportLimits.describe(bytes: 3 * 1024 * 1024 * 1024), "3.0 GB")
    }

    func testTheCeilingsAreGenerousAgainstRealDocuments() {
        // A 500 page scanned PDF is on the order of 50 MB; the limit must not
        // land anywhere near an ordinary filing.
        XCTAssertGreaterThanOrEqual(ImportLimits.maxDocumentBytes, 100 * 1024 * 1024)
        XCTAssertGreaterThanOrEqual(
            ImportLimits.maxArchiveUncompressedBytes,
            ImportLimits.maxDocumentBytes,
            "an archive budget below the single-document limit would reject a valid bundle"
        )
    }
}
