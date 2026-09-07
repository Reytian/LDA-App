//
//  DocxArchiveBudgetTests.swift
//  LDACoreTests
//
//  Review finding 14 (2026-09-06): a .docx IS a zip archive, and the DOCX
//  reader inflated its entries with no actual-bytes budget at all. The
//  document-size ceiling checks the COMPRESSED file, so a 1,294 byte package
//  inflated 65,536 bytes of text past a 4,096 byte ceiling and the import
//  succeeded. The export repeated it: DocxZip.rewrite inflated every untouched
//  member into memory the same way.
//
//  The shared ledger already exists (ArchiveBudget, metering bytes the
//  inflater ACTUALLY produced because ZIPFoundation ignores declared sizes).
//  These tests pin it to the DOCX path, and pin the error TYPE: a size limit
//  reported as "corrupt" sends a lawyer looking for file damage that is not
//  there, and the sibling tests in NestedArchiveBudgetTests exist because the
//  ledger must not be minted per call.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
import ZIPFoundation
@testable import LDACore

final class DocxArchiveBudgetTests: XCTestCase {

    /// The ceiling every test here runs under. Small enough that kilobyte
    /// fixtures exercise the real metering path.
    private static let budgetBytes = 16 * 1024

    /// One part's inflated text, comfortably over the ceiling on its own.
    private static let overBudgetTextBytes = 64 * 1024

    /// One part's inflated text, comfortably under it, so a package of
    /// several is legitimate part by part and only the total is not.
    private static let underBudgetTextBytes = 6 * 1024

    private var workDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocxArchiveBudget-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        ImportLimits.archiveBudgetSeam.clear()
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    /// A high-ratio .docx: a package of a few hundred bytes whose parts
    /// inflate to `bodyBytes` in the body plus `bodyBytes` in each of
    /// `extraHeaders` headers. Honest deflate, honest declared sizes; the
    /// ratio is what a run of one repeated character buys.
    @discardableResult
    private func writeHighRatioDocx(
        named name: String,
        bodyBytes: Int,
        extraHeaders: Int = 0
    ) throws -> URL {
        let filler = String(repeating: "A", count: bodyBytes)
        let extras = (1 ... max(1, extraHeaders)).prefix(extraHeaders).map { index in
            (
                "word/header\(index).xml",
                DocxTestPackage.wordPart(
                    rootTag: "hdr",
                    body: DocxTestPackage.paragraph(DocxTestPackage.run(filler))
                )
            )
        }
        return try DocxTestPackage.write(
            body: DocxTestPackage.paragraph(DocxTestPackage.run(filler)),
            extraParts: Array(extras),
            to: workDir.appendingPathComponent(name)
        )
    }

    private func assertRefusedForSize(
        _ body: () throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            guard case DocumentIOError.tooLarge(let detail) = error else {
                return XCTFail(
                    "a size ceiling must surface as tooLarge, not as \(error)",
                    file: file,
                    line: line
                )
            }
            XCTAssertFalse(detail.isEmpty, file: file, line: line)
        }
    }

    // MARK: - Import

    /// The review's probe: the archive is tiny, the inflated text is not, and
    /// the configured ceiling is smaller still.
    func testImportChargesActualInflatedBytesNotTheArchiveSize() throws {
        let input = try writeHighRatioDocx(
            named: "high-ratio.docx",
            bodyBytes: Self.overBudgetTextBytes
        )
        let onDisk = try XCTUnwrap(ImportLimits.fileSize(at: input))
        XCTAssertLessThan(onDisk, Self.budgetBytes, "fixture: the package itself is under the ceiling")

        ImportLimits.archiveBudgetSeam.value = Self.budgetBytes
        assertRefusedForSize { _ = try DocxImporter().importDocument(input) }
    }

    /// One ledger for the whole package. Every part is legitimate alone, so
    /// only a ledger shared across the body and the supplementary parts
    /// refuses the total; a budget minted per entry read would pass this.
    func testOneLedgerIsSharedByTheBodyAndEverySupplementaryPart() throws {
        let input = try writeHighRatioDocx(
            named: "many-parts.docx",
            bodyBytes: Self.underBudgetTextBytes,
            extraHeaders: 4
        )
        XCTAssertLessThan(
            Self.underBudgetTextBytes,
            Self.budgetBytes,
            "fixture: no single part exceeds the ceiling"
        )

        ImportLimits.archiveBudgetSeam.value = Self.budgetBytes
        assertRefusedForSize {
            _ = try LDAService.anonymize(
                input: input,
                outputDir: self.workDir.appendingPathComponent("out", isDirectory: true),
                protection: .passphrase("synthetic-review-passphrase"),
                createdAtISO8601: "2026-09-06T00:00:00Z"
            )
        }
    }

    /// An ordinary document still imports: the ceiling bounds a bomb, not a
    /// filing.
    func testAnOrdinaryDocumentStillImports() throws {
        let input = try writeHighRatioDocx(
            named: "ordinary.docx",
            bodyBytes: Self.underBudgetTextBytes
        )
        ImportLimits.archiveBudgetSeam.value = Self.budgetBytes

        let imported = try DocxImporter().importDocument(input)
        XCTAssertEqual(imported.text.utf8.count, Self.underBudgetTextBytes)
    }

    // MARK: - Rewrite

    /// The export inflates every untouched member to copy it, so the rewrite
    /// needs the same metering the read has.
    func testRewriteChargesTheBytesItInflatesToCopy() throws {
        let source = try writeHighRatioDocx(
            named: "rewrite-source.docx",
            bodyBytes: Self.overBudgetTextBytes,
            extraHeaders: 1
        )
        let out = workDir.appendingPathComponent("rewritten.docx")

        assertRefusedForSize {
            try DocxZip.rewrite(
                source: source,
                replacing: [docxMainPartPath: Data("<w:document/>".utf8)],
                to: out,
                budget: ArchiveBudget(totalBytes: Self.budgetBytes)
            )
        }
    }

    /// A rewrite under the ceiling still writes every member.
    func testRewriteUnderTheCeilingStillCopiesEveryMember() throws {
        let source = try writeHighRatioDocx(
            named: "small-source.docx",
            bodyBytes: 64,
            extraHeaders: 1
        )
        let out = workDir.appendingPathComponent("copied.docx")

        try DocxZip.rewrite(
            source: source,
            replacing: [:],
            to: out,
            budget: ArchiveBudget(totalBytes: Self.budgetBytes)
        )

        let sourcePaths = try DocxTestPackage.allMembers(in: source).map(\.path).sorted()
        let outPaths = try DocxTestPackage.allMembers(in: out).map(\.path).sorted()
        XCTAssertEqual(outPaths, sourcePaths)
    }

    // MARK: - Error type

    /// The ceiling must surface as the size error it is. Converting it into
    /// the generic corrupt-file error was the silent part of this finding:
    /// the user was told their document was damaged.
    func testTheCeilingIsNotReportedAsACorruptFile() throws {
        let input = try writeHighRatioDocx(
            named: "not-corrupt.docx",
            bodyBytes: Self.overBudgetTextBytes
        )
        ImportLimits.archiveBudgetSeam.value = Self.budgetBytes

        do {
            _ = try DocxImporter().importDocument(input)
            XCTFail("the ceiling did not fire")
        } catch let error as DocumentIOError {
            if case .corrupt(let detail) = error {
                XCTFail("a size ceiling reported as corruption: \(detail)")
            }
            XCTAssertTrue(
                error.localizedDescription.lowercased().contains("large"),
                error.localizedDescription
            )
        }
    }
}
