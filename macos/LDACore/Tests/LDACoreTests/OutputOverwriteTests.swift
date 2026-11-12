//
//  OutputOverwriteTests.swift
//  LDACoreTests
//
//  Review 2026-11-11, T7. `lda anonymize` wrote <base>_redacted.<ext> and
//  <base>_redacted.ldamap over the files an earlier run left in the same
//  folder: the earlier redacted copy, possibly already sent, lost the only
//  mapping that restores it. And a document whose batch re-run failed kept
//  the earlier run's outputs beside a "failed" report line, with nothing to
//  say they were made from an older version of the document.
//
//  A single-document anonymize now takes the next free name, as Save
//  Redacted and a multi-document session already did, and keys the mapping
//  on the name it took. A failed batch re-run names the earlier outputs it
//  left in place as made from an earlier version; nothing is deleted.
//
//  Hermetic: mappings are passphrase protected and detection is patterns
//  only. Every value is invented.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore
@testable import LDACLI

final class OutputOverwriteTests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OutputOverwriteTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
        try super.tearDownWithError()
    }

    private func restored(_ redacted: URL, with mapping: URL) throws -> String {
        let loaded = try MappingStore.load(from: mapping, protection: .passphrase("pw"))
        return Restorer.restore(text: try String(contentsOf: redacted, encoding: .utf8), mapping: loaded).text
    }

    // MARK: - lda anonymize

    func testASecondAnonymizeIntoTheSameFolderLeavesTheFirstOutputsAndTheirMapping() throws {
        let document = workDir.appendingPathComponent("contract.txt")
        let out = workDir.appendingPathComponent("out", isDirectory: true)
        let firstText = "Mail alice@alpha.example about the matter."
        let secondText = "Mail bob@beta.example about the matter."
        try Data(firstText.utf8).write(to: document)
        let first = try LDACLI.runAnonymize(input: document, outputDir: out, passphrase: "pw",
                                            timestamp: { "2026-11-11T00:00:00Z" })
        let firstMapping = try Data(contentsOf: first.mappingFileURL)

        try Data(secondText.utf8).write(to: document)
        let second = try LDACLI.runAnonymize(input: document, outputDir: out, passphrase: "pw",
                                             timestamp: { "2026-11-11T00:00:00Z" })

        XCTAssertNotEqual(second.mappingFileURL, first.mappingFileURL, "the second run takes another name")
        XCTAssertNotEqual(second.redactedFileURL, first.redactedFileURL)
        XCTAssertEqual(try Data(contentsOf: first.mappingFileURL), firstMapping, "the first mapping is untouched")
        XCTAssertEqual(try restored(first.redactedFileURL, with: first.mappingFileURL), firstText)
        XCTAssertEqual(try restored(second.redactedFileURL, with: second.mappingFileURL), secondText)
        XCTAssertEqual(second.redactedFileURL.deletingPathExtension().lastPathComponent,
                       second.mappingFileURL.deletingPathExtension().lastPathComponent,
                       "the mapping is named after the file it restores")
    }

    // MARK: - lda batch

    func testAFailedBatchReRunNamesTheEarlierOutputsItLeftInPlace() throws {
        let source = workDir.appendingPathComponent("source", isDirectory: true)
        let output = workDir.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let document = source.appendingPathComponent("contract.txt")
        try Data("Mail alice@alpha.example about the matter.".utf8).write(to: document)
        let options = BatchOptions(
            modelPath: nil,
            unlocatedPolicy: .protect,
            redoFinished: false,
            protectionLabel: "passphrase",
            protection: { _ in .passphrase("pw") }
        )
        let first = try BatchAnonymizer.run(sourceFolder: source, outputFolder: output, options: options)
        let done = try XCTUnwrap(first.items.first)
        XCTAssertEqual(done.status, .done)
        let earlier = try XCTUnwrap(done.redactedFile)

        // The document changes, and can no longer be read.
        try Data("Mail bob@beta.example about the new matter.".utf8).write(to: document)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: document.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: document.path) }
        let second = try BatchAnonymizer.run(sourceFolder: source, outputFolder: output, options: options)
        let failed = try XCTUnwrap(second.items.first)

        XCTAssertEqual(failed.status, .failed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.appendingPathComponent(earlier).path),
                      "nothing is deleted")
        let reason = try XCTUnwrap(failed.reason)
        XCTAssertTrue(reason.contains("earlier version"), reason)
        XCTAssertTrue(reason.contains((earlier as NSString).lastPathComponent), reason)
    }
}
