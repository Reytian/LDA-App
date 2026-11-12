//
//  BatchOutputFormatTests.swift
//  LDACoreTests
//
//  The output format through a batch (BatchOptions.format, `lda batch
//  --format`): one Markdown file per document, each document in its own
//  format, two documents sharing a base name kept apart, the format treated
//  as a setting by the resume check, reports from before formats existed
//  still resuming the edit surfaces they describe, and the report naming
//  the format.
//
//  Pattern detection only; no model, no Keychain.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import ArgumentParser
import PDFKit
import XCTest
@testable import LDACLI
@testable import LDACore

final class BatchOutputFormatTests: XCTestCase {
    private var workDir: URL!
    private var source: URL!
    private var output: URL!

    private static let passphrase = "batch-format-passphrase"
    private static let phone = "13812345678"
    private static let email = "zhangsan@example.com"
    private static let memoText = "Call \(phone) or write to \(email)."

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BatchOutputFormatTests-\(UUID().uuidString)", isDirectory: true)
        source = workDir.appendingPathComponent("source", isDirectory: true)
        output = workDir.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
        workDir = nil
        try super.tearDownWithError()
    }

    private func options(_ format: RedactedOutputFormat?) -> BatchOptions {
        BatchOptions(
            modelPath: nil,
            protectionLabel: "passphrase",
            protection: { _ in .passphrase(Self.passphrase) },
            format: format
        )
    }

    private func run(_ format: RedactedOutputFormat?) throws -> BatchReport {
        try BatchAnonymizer.run(sourceFolder: source, outputFolder: output, options: options(format))
    }

    private func line(_ report: BatchReport, _ source: String) throws -> BatchItem {
        try XCTUnwrap(report.items.first { $0.source == source }, "no report line for \(source)")
    }

    /// A memo, and a Word document and a PDF that share the base name
    /// "lease", so all three would otherwise write lease_redacted.md side by
    /// side.
    private func writeSources() throws {
        try Data(Self.memoText.utf8).write(to: source.appendingPathComponent("memo.txt"))
        try DocxTestPackage.write(
            body: DocxTestPackage.paragraph(
                DocxTestPackage.run("Tenant phone \(Self.phone), email "),
                DocxTestPackage.run(Self.email, rPr: "<w:b/>")
            ),
            to: source.appendingPathComponent("lease.docx")
        )
        try OutputFormatFixtures.writePDF(
            [.init(size: OutputFormatFixtures.letter, lines: ["Tenant phone \(Self.phone)", "Email \(Self.email)"])],
            metadataValue: Self.email,
            to: source.appendingPathComponent("lease.pdf")
        )
    }

    private func restoredText(_ item: BatchItem) throws -> String {
        let redacted = output.appendingPathComponent(try XCTUnwrap(item.redactedFile))
        let restored = workDir.appendingPathComponent("restored-\(UUID().uuidString).\(redacted.pathExtension)")
        _ = try LDAService.restore(
            editedRedacted: redacted,
            mapping: output.appendingPathComponent(try XCTUnwrap(item.mappingFile)),
            protection: .passphrase(Self.passphrase),
            output: restored
        )
        return try LDAService.localReviewText(input: restored)
    }

    // MARK: - Markdown

    func testMarkdownWritesOneMarkdownFilePerDocumentAndEveryOneRestores() throws {
        try writeSources()

        let report = try run(.markdown)

        XCTAssertEqual(report.outputFormat, .markdown)
        XCTAssertEqual(report.failedCount, 0, report.items.compactMap(\.reason).joined(separator: "; "))
        XCTAssertEqual(try line(report, "memo.txt").redactedFile, "memo_redacted.md")
        XCTAssertEqual(try line(report, "lease.docx").redactedFile, "lease (docx)/lease_redacted.md")
        XCTAssertEqual(try line(report, "lease.pdf").redactedFile, "lease (pdf)/lease_redacted.md")
        XCTAssertEqual(try line(report, "lease.pdf").mappingFile, "lease (pdf)/lease_redacted.ldamap")
        XCTAssertNil(try line(report, "lease.pdf").reviewPDF, "Markdown writes no review copy")

        for item in report.items {
            let markdown = try String(
                contentsOf: output.appendingPathComponent(try XCTUnwrap(item.redactedFile)),
                encoding: .utf8
            )
            XCTAssertTrue(markdown.hasPrefix(MarkdownHandoffWriter.tokenStylePreamble), item.source)
            XCTAssertFalse(markdown.contains(Self.phone), item.source)
            XCTAssertFalse(markdown.contains(Self.email), item.source)
            XCTAssertTrue(try restoredText(item).contains(Self.email), item.source)
        }
        XCTAssertEqual(
            try restoredText(try line(report, "memo.txt")),
            MarkdownHandoffWriter.tokenStylePreamble + "\n\n" + Self.memoText
        )
    }

    // MARK: - Original

    func testOriginalWritesEachDocumentInItsOwnFormat() throws {
        try writeSources()

        let report = try run(.original)

        XCTAssertEqual(report.outputFormat, .original)
        XCTAssertEqual(report.failedCount, 0, report.items.compactMap(\.reason).joined(separator: "; "))
        XCTAssertEqual(try line(report, "memo.txt").redactedFile, "memo_redacted.txt")
        XCTAssertEqual(try line(report, "lease.docx").redactedFile, "lease (docx)/lease_redacted.docx")
        // The restorable text is the redacted file; the boxed PDF beside it
        // is recorded as the PDF.
        XCTAssertEqual(try line(report, "lease.pdf").redactedFile, "lease (pdf)/lease_redacted.txt")
        XCTAssertEqual(try line(report, "lease.pdf").reviewPDF, "lease (pdf)/lease_redacted.pdf")

        let pdf = try XCTUnwrap(PDFDocument(url: output.appendingPathComponent("lease (pdf)/lease_redacted.pdf")))
        XCTAssertEqual(pdf.pageCount, 1)
        XCTAssertFalse((pdf.string ?? "").contains(Self.email))
        XCTAssertEqual(try restoredText(try line(report, "memo.txt")), Self.memoText)
        XCTAssertTrue(try restoredText(try line(report, "lease.docx")).contains(Self.email))
    }

    // MARK: - Resume

    func testChangingTheFormatProcessesEveryDocumentAgain() throws {
        try writeSources()
        _ = try run(.markdown)

        let resumed = try run(.markdown)
        XCTAssertEqual(Set(resumed.items.map(\.status)), [.skipped])

        let original = try run(.original)
        XCTAssertEqual(Set(original.items.map(\.status)), [.done], "a new format is a new setting")
        // Written beside the Markdown run's files, never over them.
        XCTAssertEqual(try line(original, "lease.docx").redactedFile, "lease (docx)/lease_redacted_2.docx")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: output.appendingPathComponent("lease (docx)/lease_redacted.md").path
        ))

        let resumedOriginal = try run(.original)
        XCTAssertEqual(Set(resumedOriginal.items.map(\.status)), [.skipped])

        let editSurfaces = try run(nil)
        XCTAssertEqual(Set(editSurfaces.items.map(\.status)), [.done])
    }

    func testAReportFromBeforeFormatsResumesOnlyTheEditSurfacesItDescribes() throws {
        try Data(Self.memoText.utf8).write(to: source.appendingPathComponent("memo.txt"))
        _ = try run(nil)

        // A run with no format writes no outputFormat key, exactly like a
        // report written before there was one.
        let reportURL = output.appendingPathComponent(BatchReport.fileName)
        let json = try String(contentsOf: reportURL, encoding: .utf8)
        XCTAssertFalse(json.contains("outputFormat"), json)
        let decoded = try JSONDecoder().decode(BatchReport.self, from: Data(json.utf8))
        XCTAssertNil(decoded.outputFormat)

        XCTAssertEqual(try run(nil).items.map(\.status), [.skipped])
        XCTAssertEqual(try run(.markdown).items.map(\.status), [.done])
    }

    /// The review's finding: a run with another format re-did every document
    /// and wrote its mapping over the earlier run's, so the earlier .docx,
    /// left in place, restored its footnote to orphaned placeholders.
    func testAFormatChangeNeverWritesOverAnEarlierRunsMapping() throws {
        let footnoteEmail = "footnote-contact@example.org"
        try DocxTestPackage.write(
            body: DocxTestPackage.paragraph(
                DocxTestPackage.run("Call \(Self.phone) about the lease."),
                "<w:r><w:footnoteReference w:id=\"1\"/></w:r>"
            ),
            extraParts: [(
                "word/footnotes.xml",
                DocxTestPackage.wordPart(
                    rootTag: "footnotes",
                    body: "<w:footnote w:id=\"1\">"
                        + DocxTestPackage.paragraph(DocxTestPackage.run("Write to \(footnoteEmail)."))
                        + "</w:footnote>"
                )
            )],
            to: source.appendingPathComponent("probe.docx")
        )
        let first = try line(try run(nil), "probe.docx")
        XCTAssertEqual(first.mappingFile, "probe_redacted.ldamap")
        let firstMapping = output.appendingPathComponent("probe_redacted.ldamap")
        let firstMappingBytes = try Data(contentsOf: firstMapping)

        let second = try line(try run(.markdown), "probe.docx")
        XCTAssertEqual(second.status, .done)
        XCTAssertEqual(second.redactedFile, "probe_redacted_2.md")
        XCTAssertEqual(second.mappingFile, "probe_redacted_2.ldamap")
        XCTAssertEqual(try Data(contentsOf: firstMapping), firstMappingBytes, "the earlier mapping is untouched")

        // The earlier copy still restores everywhere, its footnote included.
        let restored = workDir.appendingPathComponent("restored.docx")
        let report = try LDAService.restore(
            editedRedacted: output.appendingPathComponent(try XCTUnwrap(first.redactedFile)),
            mapping: firstMapping,
            protection: .passphrase(Self.passphrase),
            output: restored
        )
        XCTAssertTrue(report.orphanTokens.isEmpty, "orphaned: \(report.orphanTokens)")
        XCTAssertEqual(report.restoredCount, first.replacedCount)
        XCTAssertTrue(try DocxParts.restoreReportText(from: restored).contains(footnoteEmail))
    }

    func testARedoWithTheSameSettingsReplacesItsOwnFiles() throws {
        try Data(Self.memoText.utf8).write(to: source.appendingPathComponent("memo.txt"))
        _ = try run(.markdown)

        let redone = try BatchAnonymizer.run(
            sourceFolder: source,
            outputFolder: output,
            options: BatchOptions(
                modelPath: nil,
                redoFinished: true,
                protectionLabel: "passphrase",
                protection: { _ in .passphrase(Self.passphrase) },
                format: .markdown
            )
        )
        XCTAssertEqual(try line(redone, "memo.txt").status, .done)
        XCTAssertEqual(try line(redone, "memo.txt").redactedFile, "memo_redacted.md")
        XCTAssertFalse(
            (try FileManager.default.contentsOfDirectory(atPath: output.path)).contains { $0.contains("_redacted_2") },
            "a redo writes its own files again, under their own names"
        )
    }

    func testARemovedBoxedCopyIsWrittenAgain() throws {
        try OutputFormatFixtures.writePDF(
            [.init(size: OutputFormatFixtures.letter, lines: ["Email \(Self.email)"])],
            metadataValue: Self.email,
            to: source.appendingPathComponent("lease.pdf")
        )
        let first = try line(try run(.original), "lease.pdf")
        try FileManager.default.removeItem(at: output.appendingPathComponent(try XCTUnwrap(first.reviewPDF)))

        XCTAssertEqual(try line(try run(.original), "lease.pdf").status, .done)
    }

    func testTheEditSurfacesTakeTheDocumentsBatchesAlwaysTook() throws {
        try Data(Self.memoText.utf8).write(to: source.appendingPathComponent("lease.txt"))
        try Data("# Notes\n\nCall \(Self.phone).".utf8).write(to: source.appendingPathComponent("lease.md"))

        let editSurfaces = try run(nil)
        XCTAssertEqual(editSurfaces.items.map(\.source), ["lease.txt"], "no .md without a format")
        XCTAssertEqual(try line(editSurfaces, "lease.txt").redactedFile, "lease_redacted.txt", "and no subfolder")

        let markdown = try BatchAnonymizer.run(
            sourceFolder: source,
            outputFolder: workDir.appendingPathComponent("markdown-output", isDirectory: true),
            options: options(.markdown)
        )
        XCTAssertEqual(markdown.items.map(\.source).sorted(), ["lease.md", "lease.txt"])
        XCTAssertEqual(try line(markdown, "lease.md").redactedFile, "lease (md)/lease_redacted.md")
    }

    /// Only the value is compared: nothing here reads or writes the Keychain.
    func testTheCLISealsEachMappingUnderItsOwnName() {
        let base = TestNamespace.fileBaseName("lease") + "_redacted_2"
        let mapping = URL(fileURLWithPath: "/out/\(base).ldamap")
        guard case .keychain(let account) = Batch.mappingProtection(passphrase: nil)(mapping) else {
            return XCTFail("without a passphrase the mapping goes into the Keychain")
        }
        XCTAssertEqual(account, LDACLI.keychainAccount(forMappingBaseName: base))
        guard case .passphrase(let phrase) = Batch.mappingProtection(passphrase: "pw")(mapping) else {
            return XCTFail("a passphrase seals every mapping")
        }
        XCTAssertEqual(phrase, "pw")
    }

    // MARK: - The report

    func testTheReportAndItsSummaryNameTheFormat() throws {
        try Data(Self.memoText.utf8).write(to: source.appendingPathComponent("memo.txt"))

        _ = try run(.markdown)
        let json = try String(contentsOf: output.appendingPathComponent(BatchReport.fileName), encoding: .utf8)
        let summary = try String(contentsOf: output.appendingPathComponent(BatchReport.summaryFileName), encoding: .utf8)
        XCTAssertTrue(json.contains("\"outputFormat\" : \"markdown\""), json)
        XCTAssertTrue(summary.contains("Output format: Markdown\n"), summary)

        _ = try run(.original)
        let originalSummary = try String(
            contentsOf: output.appendingPathComponent(BatchReport.summaryFileName),
            encoding: .utf8
        )
        XCTAssertTrue(originalSummary.contains("Output format: original (each document in its own format)"), originalSummary)

        _ = try run(nil)
        let legacySummary = try String(
            contentsOf: output.appendingPathComponent(BatchReport.summaryFileName),
            encoding: .utf8
        )
        XCTAssertTrue(legacySummary.contains("Output format: edit surfaces"), legacySummary)
    }

    func testTheSummaryJSONCarriesTheFormatOnlyWhenOneWasChosen() throws {
        try Data(Self.memoText.utf8).write(to: source.appendingPathComponent("memo.txt"))
        let markdown = try CLIJSON.encode(BatchSummaryJSON(report: try run(.markdown), outputFolder: output))
        XCTAssertTrue(markdown.contains("\"outputFormat\":\"markdown\""), markdown)
        let legacy = try CLIJSON.encode(BatchSummaryJSON(report: try run(nil), outputFolder: output))
        XCTAssertFalse(legacy.contains("outputFormat"), legacy)
    }

    // MARK: - CLI

    /// The help says what the batch takes: .md only with a format.
    func testTheHelpSaysMarkdownFilesNeedAFormat() {
        let discussion = Batch.configuration.discussion
        XCTAssertTrue(discussion.contains("every .md file when --format is given"), discussion)
        XCTAssertFalse(discussion.contains(".txt, .md,"), discussion)
    }

    func testBatchParsesTheFormat() throws {
        func parse(_ extra: [String]) throws -> Batch {
            let parsed = try LDARoot.parseAsRoot(["batch", "--input-dir", "/in", "--output-dir", "/out"] + extra)
            return try XCTUnwrap(parsed as? Batch)
        }
        XCTAssertNil(try parse([]).format)
        XCTAssertEqual(try parse(["--format", "markdown"]).format, .markdown)
        XCTAssertEqual(try parse(["--format", "original"]).format, .original)
        XCTAssertThrowsError(try parse(["--format", "pdf"]))
    }
}
