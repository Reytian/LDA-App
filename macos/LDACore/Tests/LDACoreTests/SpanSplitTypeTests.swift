//
//  SpanSplitTypeTests.swift
//  LDACoreTests
//
//  Two defects of the same shape, both about a span that crosses a synthetic
//  break (a paragraph newline, a w:br, a w:cr, or a w:tab):
//
//  W-01: SpanSplitter copied the PARENT's type into every sub-span. The
//  merger absorbs a PHONE and a DATE separated only by a line break into one
//  PHONE span, so after the split the date half was still typed PHONE: the
//  token said {PHONE_n}, the pseudonym style told the AI a date was a phone
//  number, and the asterisk style masked it with the phone rule, which leaves
//  the year prefix visible. Each part must be re-typed from its own text.
//
//  W-02: the split was gated to .docx, so a plain-text or Markdown edit
//  surface swallowed the newline inside the replacement and lost a line.
//  Every text-shaped input splits now.
//
//  House rules: all comments and strings in English. Fixture values may be
//  Chinese. No em-dash and no en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore
@testable import LDAUI

final class SpanSplitTypeTests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("span-split-type-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    // MARK: - W-01: per-part re-typing

    /// Each sub-span is typed from its own text when one deterministic
    /// detection covers essentially all of it, and keeps the parent's type
    /// otherwise.
    func testSplitPartsAreRetypedFromTheirOwnText() {
        let cases: [(name: String, surface: String, parent: EntityType, expected: [(String, EntityType)])] = [
            (
                name: "a phone and a date bridged by a line break split into PHONE and DATE",
                surface: "13700001111\n2026-04-01",
                parent: .phone,
                expected: [("13700001111", .phone), ("2026-04-01", .date)]
            ),
            (
                name: "a name split across a tab keeps the parent type on both parts",
                surface: "John\tSmith",
                parent: .person,
                expected: [("John", .person), ("Smith", .person)]
            ),
            (
                name: "a part only partly covered by a detection keeps the parent type",
                surface: "2026-04-01 order form\nAcme",
                parent: .company,
                expected: [("2026-04-01 order form", .company), ("Acme", .company)]
            ),
            (
                name: "whitespace-only parts are dropped, as before",
                surface: "A\n \nB",
                parent: .person,
                expected: [("A", .person), ("B", .person)]
            )
        ]

        for testCase in cases {
            let text = "Prefix \(testCase.surface) suffix."
            let span = DocxTestPackage.span(in: text, surface: testCase.surface, type: testCase.parent)

            let split = SpanSplitter.splitAtBreaks([span], in: text)

            XCTAssertEqual(split.map(\.text), testCase.expected.map(\.0), testCase.name)
            XCTAssertEqual(split.map(\.type), testCase.expected.map(\.1), testCase.name)
            // Offsets must still slice back exactly, and the parent's source,
            // confidence, and priority ride along unchanged.
            let ns = text as NSString
            for part in split {
                let slice = ns.substring(with: NSRange(location: part.start, length: part.end - part.start))
                XCTAssertEqual(slice, part.text, testCase.name)
                XCTAssertEqual(part.source, span.source, testCase.name)
                XCTAssertEqual(part.confidence, span.confidence, testCase.name)
                XCTAssertEqual(part.priority, span.priority, testCase.name)
            }
        }
    }

    /// A surface with no break is returned untouched, type included: nothing
    /// is re-typed that was not split.
    func testSpansWithoutABreakAreNotRetyped() {
        let text = "Invoice 2026-04-01 for Acme."
        let span = DocxTestPackage.span(in: text, surface: "2026-04-01", type: .company)

        XCTAssertEqual(SpanSplitter.splitAtBreaks([span], in: text), [span])
    }

    // MARK: - W-02: text and Markdown split too

    /// The .txt edit surface keeps the original line structure, the date half
    /// renders as a DATE token, and restore is byte-identical.
    func testPlainTextExportKeepsLineCountAndTypesTheDateHalf() throws {
        let source = workDir.appendingPathComponent("contract.txt")
        try Self.probeText.write(to: source, atomically: true, encoding: .utf8)

        let result = try LDAService.anonymize(
            input: source,
            outputDir: workDir,
            protection: .passphrase("pw"),
            createdAtISO8601: "2026-09-03T00:00:00Z",
            llmModelPath: nil
        )

        let redacted = try String(contentsOf: result.redactedFileURL, encoding: .utf8)
        XCTAssertEqual(
            redacted.components(separatedBy: "\n").count,
            Self.probeText.components(separatedBy: "\n").count,
            "the newline between the two parts must survive: \(redacted.debugDescription)"
        )
        XCTAssertTrue(redacted.contains("{PHONE_1}\n{DATE_1}"), redacted)
        XCTAssertFalse(redacted.contains(Self.probePhone), "phone leaked: \(redacted)")
        XCTAssertFalse(redacted.contains(Self.probeDate), "date leaked: \(redacted)")

        let restored = workDir.appendingPathComponent("restored.txt")
        _ = try LDAService.restore(
            editedRedacted: result.redactedFileURL,
            mapping: result.mappingFileURL,
            protection: .passphrase("pw"),
            output: restored
        )
        XCTAssertEqual(try String(contentsOf: restored, encoding: .utf8), Self.probeText)
    }

    /// The same for Markdown, which item 1 of this wave made the AI handoff
    /// format: the redacted file keeps its lines and restores byte-identically.
    func testMarkdownExportKeepsLineCountAndTypesTheDateHalf() throws {
        let source = workDir.appendingPathComponent("contract.md")
        try Self.probeText.write(to: source, atomically: true, encoding: .utf8)

        let result = try LDAService.anonymize(
            input: source,
            outputDir: workDir,
            protection: .passphrase("pw"),
            createdAtISO8601: "2026-09-03T00:00:00Z",
            llmModelPath: nil
        )

        let redacted = try String(contentsOf: result.redactedFileURL, encoding: .utf8)
        XCTAssertEqual(
            redacted.components(separatedBy: "\n").count,
            Self.probeText.components(separatedBy: "\n").count,
            redacted.debugDescription
        )
        XCTAssertTrue(redacted.contains("{PHONE_1}\n{DATE_1}"), redacted)

        let restored = workDir.appendingPathComponent("restored.md")
        _ = try LDAService.restore(
            editedRedacted: result.redactedFileURL,
            mapping: result.mappingFileURL,
            protection: .passphrase("pw"),
            output: restored
        )
        XCTAssertEqual(try String(contentsOf: restored, encoding: .utf8), Self.probeText)
    }

    // The GUI export path (ReviewModel.performExport) is covered end to end in
    // ReviewModelExportBreakSplitTests, for both .docx and .txt sources.

    // MARK: - Sealed chips

    /// A value that was split has no mapping entry for its whole surface, so
    /// the chip falls back to the first part's token. Reporting nil would tell
    /// the user the value is unprotected, which is the more dangerous wrong
    /// answer: it WAS redacted, in two pieces.
    func testSealedChipTokenFallsBackToTheFirstPartOfASplitSurface() {
        let tokenBySurface = [
            Self.probePhone: "{PHONE_1}",
            Self.probeDate: "{DATE_1}",
            "Acme Ltd": "{COMPANY_1}"
        ]

        XCTAssertEqual(ReviewModel.chipToken(for: "Acme Ltd", in: tokenBySurface), "{COMPANY_1}")
        XCTAssertEqual(
            ReviewModel.chipToken(for: "\(Self.probePhone)\n\(Self.probeDate)", in: tokenBySurface),
            "{PHONE_1}"
        )
        XCTAssertNil(ReviewModel.chipToken(for: "Never seen", in: tokenBySurface))
        XCTAssertNil(ReviewModel.chipToken(for: "Never\nseen", in: tokenBySurface))
    }

    /// The splitter's first-part helper is nil when nothing would be split, so
    /// the chip lookup never invents a fallback for an unsplit surface.
    func testFirstPartIsNilWithoutABreak() {
        XCTAssertNil(SpanSplitter.firstPart(of: "Acme Ltd"))
        XCTAssertNil(SpanSplitter.firstPart(of: " \n \t "))
        XCTAssertEqual(SpanSplitter.firstPart(of: "\(Self.probePhone)\n\(Self.probeDate)"), Self.probePhone)
    }

    // MARK: - Fixture

    private static let probePhone = "13700001111"
    private static let probeDate = "2026-04-01"

    /// Seven lines, with the phone and the date on lines 2 and 3 so the merger
    /// absorbs them into one break-crossing span.
    private static let probeText = """
    甲方联系人
    手机 \(probePhone)
    \(probeDate) 起生效
    乙方联系人
    邮箱 lisi@example.com
    备注：无
    完
    """
}
