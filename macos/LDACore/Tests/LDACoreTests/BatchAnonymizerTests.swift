//
//  BatchAnonymizerTests.swift
//  LDACoreTests
//
//  Batch anonymization (BatchAnonymizer, `lda batch`, the app's batch
//  window): run-in values protected without asking, a value inside an
//  ordinary word still refusing its document, one document's failure never
//  stopping the batch, the mirrored layout, resume, the model loaded once,
//  and a report that carries no document text.
//
//  Deterministic detection plus a test completer; no model is needed.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import ArgumentParser
import XCTest
@testable import LDACLI
@testable import LDACore

final class BatchAnonymizerTests: XCTestCase {
    private var workDir: URL!
    private var source: URL!
    private var output: URL!

    private static let bogusModelPath = "/nonexistent/batch-test-model.gguf"
    private static let passphrase = "batch-test-passphrase"
    /// "Jordan Lee" anchors at its first mention and runs into a digit at its
    /// second, a place the locator refuses.
    private static let glued = "Jordan Lee signed for Northwind Traders. Witnessed by Jordan Lee2 on the same day."
    /// "Ann" is written only inside "Annex": a place nothing is ever cut out of.
    private static let insideWord = "See Annex 4 for the schedule agreed with Northwind Traders."
    private static let clean = "Northwind Traders agreed to the terms."

    /// Reports the same three values for every segment. A value the segment
    /// does not hold at all is an invented one and is ignored.
    private struct ReportsTheParties: TextCompleter {
        func complete(prompt: String, maxTokens: Int?, stop: [String]) throws -> String {
            #"{"entities":[{"value":"Jordan Lee","type":"PERSON"},{"value":"Northwind Traders","type":"COMPANY"},{"value":"Ann","type":"PERSON"}],"redacted_text":""}"#
        }
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BatchAnonymizerTests-\(UUID().uuidString)", isDirectory: true)
        source = workDir.appendingPathComponent("source", isDirectory: true)
        output = workDir.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        LDAService.makeExtractorForTesting = { _ in LLMExtractor(completer: ReportsTheParties()) }
    }

    override func tearDownWithError() throws {
        LDAService.makeExtractorForTesting = nil
        if let workDir {
            try? FileManager.default.removeItem(at: workDir)
        }
        workDir = nil
        try super.tearDownWithError()
    }

    @discardableResult
    private func write(_ text: String, _ relativePath: String) throws -> URL {
        let url = source.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: url)
        return url
    }

    private func options(policy: UnlocatedValuePolicy = .protect, redo: Bool = false) -> BatchOptions {
        BatchOptions(
            modelPath: Self.bogusModelPath,
            unlocatedPolicy: policy,
            redoFinished: redo,
            protectionLabel: "passphrase",
            protection: { _ in .passphrase(Self.passphrase) }
        )
    }

    private func run(_ options: BatchOptions) throws -> BatchReport {
        try BatchAnonymizer.run(sourceFolder: source, outputFolder: output, options: options)
    }

    private func line(_ report: BatchReport, _ source: String) throws -> BatchItem {
        try XCTUnwrap(report.items.first { $0.source == source }, "no report line for \(source)")
    }

    // MARK: - Run-in values

    func testARunInValueIsProtectedAndTheDocumentStillRestoresExactly() throws {
        try write(Self.glued, "glued.txt")

        let report = try run(options())

        let item = try line(report, "glued.txt")
        XCTAssertEqual(item.status, .done)
        XCTAssertEqual(item.autoProtectedValueCount, 1)
        let redactedURL = output.appendingPathComponent(try XCTUnwrap(item.redactedFile))
        let redacted = try String(contentsOf: redactedURL, encoding: .utf8)
        XCTAssertFalse(redacted.contains("Jordan"), redacted)
        XCTAssertFalse(redacted.contains("Northwind"), redacted)
        XCTAssertTrue(redacted.contains("}2"), "only the name is redacted, the digit stays: \(redacted)")

        let restored = workDir.appendingPathComponent("restored.txt")
        _ = try LDAService.restore(
            editedRedacted: redactedURL,
            mapping: output.appendingPathComponent(try XCTUnwrap(item.mappingFile)),
            protection: .passphrase(Self.passphrase),
            output: restored
        )
        XCTAssertEqual(try String(contentsOf: restored, encoding: .utf8), Self.glued)
    }

    func testUnderTheRefusePolicyTheDocumentIsNotWrittenAndTheBatchGoesOn() throws {
        try write(Self.glued, "glued.txt")
        try write(Self.clean, "clean.txt")

        let report = try run(options(policy: .refuse))

        XCTAssertEqual(try line(report, "glued.txt").status, .failed)
        XCTAssertEqual(try line(report, "clean.txt").status, .done)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: output.path)
            .filter { $0.hasPrefix("glued") }
        XCTAssertEqual(leftovers, [])
    }

    func testAValueWrittenOnlyInsideAWordStillRefusesItsDocument() throws {
        try write(Self.insideWord, "annex.txt")

        let report = try run(options())

        let item = try line(report, "annex.txt")
        XCTAssertEqual(item.status, .failed)
        XCTAssertTrue(item.reason?.contains("inside longer words") == true, item.reason ?? "no reason")
        XCTAssertNil(item.mappingFile)
    }

    func testSinglePolicyProtectsOnTheServiceToo() throws {
        let input = try write(Self.glued, "glued.txt")
        let outputDir = workDir.appendingPathComponent("single", isDirectory: true)

        XCTAssertThrowsError(
            try LDAService.anonymize(
                input: input,
                outputDir: outputDir,
                protection: .passphrase(Self.passphrase),
                createdAtISO8601: "2026-10-27T00:00:00Z",
                llmModelPath: Self.bogusModelPath
            )
        ) { error in
            guard case LDAServiceError.unanchoredEntities(let count) = error else {
                return XCTFail("expected unanchoredEntities, got \(error)")
            }
            XCTAssertEqual(count, 1)
        }

        let result = try LDAService.anonymize(
            input: input,
            outputDir: outputDir,
            protection: .passphrase(Self.passphrase),
            createdAtISO8601: "2026-10-27T00:00:00Z",
            llmModelPath: Self.bogusModelPath,
            unlocatedPolicy: .protect
        )
        XCTAssertEqual(result.autoProtectedValueCount, 1)
        XCTAssertEqual(result.autoProtectedPlaceCount, 1)
    }

    func testAProtectedValueIsAlsoRedactedWhereItRunsInInASidePart() throws {
        let detector = try LDAService.makeDetector(
            modelPath: Self.bogusModelPath,
            unlocatedPolicy: .protect
        )
        _ = try detector.detectText(Self.glued)

        // A DOCX header or footer goes through detectForImages.
        let header = detector.detectForImages("Prepared for Jordan Lee2")

        XCTAssertTrue(header.contains { $0.text == "Jordan Lee" }, "\(header.map(\.text))")
    }

    // MARK: - One document never stops the batch

    func testABrokenDocumentFailsAloneAndTheModelLoadsOnce() throws {
        var loads = 0
        LDAService.makeExtractorForTesting = { _ in
            loads += 1
            return LLMExtractor(completer: ReportsTheParties())
        }
        try write("This is not a Word document.", "broken.docx")
        try write(Self.clean, "a.txt")
        try write(Self.glued, "b.txt")

        let report = try run(options())

        XCTAssertEqual(try line(report, "broken.docx").status, .failed)
        XCTAssertEqual(try line(report, "a.txt").status, .done)
        XCTAssertEqual(try line(report, "b.txt").status, .done)
        XCTAssertEqual(report.failedCount, 1)
        XCTAssertEqual(loads, 1, "the model must be loaded once for the whole batch")
    }

    func testTheSourceFolderCannotBeTheOutputFolder() throws {
        try write(Self.clean, "memo.txt")

        XCTAssertThrowsError(
            try BatchAnonymizer.run(sourceFolder: source, outputFolder: source, options: options())
        ) { error in
            XCTAssertEqual(error as? BatchAnonymizer.BatchError, .outputFolderIsSourceFolder)
        }
    }

    // MARK: - Layout

    func testTheLayoutMirrorsSubfoldersAndSkipsOwnerAndHiddenFiles() throws {
        try write(Self.clean, "matter/sub/memo.txt")
        try write("owner file", "matter/~$memo.docx")
        try write(Self.clean, ".hidden/notes.txt")

        let report = try run(options())

        XCTAssertEqual(report.items.map(\.source), ["matter/sub/memo.txt"])
        XCTAssertEqual(try line(report, "matter/sub/memo.txt").redactedFile, "matter/sub/memo_redacted.txt")
    }

    func testDocumentsSharingABaseNameGetTheirOwnSubfolders() {
        let documents = [
            source.appendingPathComponent("lease.docx"),
            source.appendingPathComponent("Lease.pdf"),
            source.appendingPathComponent("memo.txt"),
        ]

        let folders = BatchAnonymizer.outputFolders(for: documents, sourceFolder: source, outputFolder: output)

        XCTAssertEqual(folders[documents[0]], output.appendingPathComponent("lease (docx)", isDirectory: true))
        XCTAssertEqual(folders[documents[1]], output.appendingPathComponent("Lease (pdf)", isDirectory: true))
        XCTAssertEqual(folders[documents[2]], output)
    }

    func testAnOutputFolderInsideTheSourceFolderIsNeverScanned() throws {
        output = source.appendingPathComponent("redacted", isDirectory: true)
        try write(Self.clean, "memo.txt")

        _ = try run(options())
        let second = try run(options(redo: true))

        XCTAssertEqual(second.items.map(\.source), ["memo.txt"])
    }

    func testAnOutputFolderAboveTheSourceFolderStillGetsEveryDocument() throws {
        output = workDir
        try write(Self.clean, "memo.txt")

        let report = try run(options())

        XCTAssertEqual(report.items.map(\.source), ["memo.txt"])
        XCTAssertEqual(try line(report, "memo.txt").status, .done)
    }

    // MARK: - Resume

    func testASecondRunSkipsFinishedDocumentsAndRedoesChangedOnes() throws {
        let memo = try write(Self.clean, "memo.txt")
        try write(Self.glued, "other.txt")
        _ = try run(options())

        let resumed = try run(options())
        XCTAssertEqual(resumed.items.map(\.status), [.skipped, .skipped])

        try Data("Northwind Traders agreed to the new terms.".utf8).write(to: memo)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)],
            ofItemAtPath: memo.path
        )
        let changed = try run(options())
        XCTAssertEqual(try line(changed, "memo.txt").status, .done)
        XCTAssertEqual(try line(changed, "other.txt").status, .skipped)

        let redone = try run(options(redo: true))
        XCTAssertEqual(redone.items.map(\.status), [.done, .done])
    }

    func testOtherSettingsStartOver() throws {
        try write(Self.clean, "memo.txt")
        _ = try run(options())

        var pseudonyms = options()
        pseudonyms.style = .pseudonym
        let report = try run(pseudonyms)

        XCTAssertEqual(try line(report, "memo.txt").status, .done)
    }

    // MARK: - The report

    func testTheReportCarriesNoDocumentTextPassphraseOrFullPath() throws {
        try write(Self.glued, "glued.txt")
        try write(Self.insideWord, "annex.txt")

        let report = try run(options())

        XCTAssertEqual(report.items.count, 2)
        let json = try String(contentsOf: output.appendingPathComponent(BatchReport.fileName), encoding: .utf8)
        let summary = try String(
            contentsOf: output.appendingPathComponent(BatchReport.summaryFileName),
            encoding: .utf8
        )
        for text in [json, summary] {
            XCTAssertFalse(text.contains("Jordan"))
            XCTAssertFalse(text.contains("Northwind"))
            XCTAssertFalse(text.contains(Self.passphrase))
            XCTAssertFalse(text.contains(workDir.path))
        }
        XCTAssertTrue(summary.contains("annex.txt:"), summary)
        XCTAssertTrue(summary.contains("Values protected automatically: 1 in 1 document(s)"), summary)
    }

    // MARK: - CLI

    func testBatchParsesAndRefusesRulesOnlyWithAModel() throws {
        let parsed = try LDARoot.parseAsRoot(["batch", "--input-dir", "/in", "--output-dir", "/out", "--rules-only"])
        let batch = try XCTUnwrap(parsed as? Batch)
        XCTAssertTrue(batch.rulesOnly)
        XCTAssertFalse(batch.askPassphrase)

        XCTAssertThrowsError(
            try LDARoot.parseAsRoot(["batch", "--input-dir", "/in", "--output-dir", "/out", "--rules-only", "--model", "/m"])
        )
    }

    func testAutoProtectIsForOneDocument() throws {
        XCTAssertNoThrow(try LDARoot.parseAsRoot(["anonymize", "--input", "/a.txt", "--output-dir", "/out", "--auto-protect"]))
        XCTAssertThrowsError(
            try LDARoot.parseAsRoot([
                "anonymize", "--input", "/a.txt", "--input", "/b.txt", "--output-dir", "/out", "--auto-protect",
            ])
        )
    }
}
