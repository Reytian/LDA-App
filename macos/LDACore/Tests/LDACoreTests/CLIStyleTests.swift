//
//  CLIStyleTests.swift
//  LDACoreTests
//
//  Tests for the --style flag on the anonymize subcommand: argument parsing
//  (valid values, the token default, rejection of unknown values) and the
//  pass-through to the service for both the single-document and session
//  paths. Restore summaries surface ambiguousReplacements.
//
//  House rules: all comments and strings in English. Fixture strings and
//  generated pseudonyms may be Chinese. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACLI
@testable import LDACore

final class CLIStyleTests: XCTestCase {
    private var tempDir: URL!
    private let fixedTimestamp = "2026-08-30T00:00:00Z"
    private let passphrase = "cli-style-passphrase"

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CLIStyleTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    private func writeSample(named name: String = "doc.txt") throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try Data("Mail jane.doe@example.com or call 13912345678.".utf8).write(to: url)
        return url
    }

    // MARK: - Argument parsing

    func testStyleFlagParsesEveryStyle() throws {
        for style in SubstitutionStyle.allCases {
            let command = try Anonymize.parse([
                "--input", "/tmp/in.txt",
                "--output-dir", "/tmp/out",
                "--style", style.rawValue
            ])
            XCTAssertEqual(command.style, style)
        }
    }

    func testStyleFlagDefaultsToToken() throws {
        let command = try Anonymize.parse([
            "--input", "/tmp/in.txt",
            "--output-dir", "/tmp/out"
        ])
        XCTAssertEqual(command.style, .token)
    }

    func testStyleFlagRejectsUnknownValue() {
        XCTAssertThrowsError(
            try Anonymize.parse([
                "--input", "/tmp/in.txt",
                "--output-dir", "/tmp/out",
                "--style", "emoji"
            ])
        )
    }

    // MARK: - Pass-through to the service

    func testRunAnonymizeHonorsPseudonymStyle() throws {
        let input = try writeSample()
        let outputDir = tempDir.appendingPathComponent("out", isDirectory: true)

        let result = try LDACLI.runAnonymize(
            input: input,
            outputDir: outputDir,
            passphrase: passphrase,
            style: .pseudonym,
            timestamp: { self.fixedTimestamp }
        )

        let redacted = try String(contentsOf: result.redactedFileURL, encoding: .utf8)
        XCTAssertFalse(redacted.contains("jane.doe@example.com"))
        XCTAssertTrue(redacted.contains("contact1@example.com"))
        XCTAssertFalse(redacted.contains("{EMAIL_1}"))

        let mapping = try MappingStore.load(
            from: result.mappingFileURL,
            protection: .passphrase(passphrase)
        )
        XCTAssertEqual(mapping.style, .pseudonym)
    }

    func testRunAnonymizeSessionHonorsStyle() throws {
        let one = try writeSample(named: "one.txt")
        let two = try writeSample(named: "two.txt")
        let outputDir = tempDir.appendingPathComponent("session-out", isDirectory: true)

        let summary = try LDACLI.runAnonymizeSession(
            inputs: [one, two],
            outputDir: outputDir,
            passphrase: passphrase,
            style: .pseudonym,
            timestamp: { self.fixedTimestamp }
        )

        XCTAssertEqual(summary.documents.count, 2)
        for document in summary.documents {
            let text = try String(
                contentsOf: URL(fileURLWithPath: document.redactedFile),
                encoding: .utf8
            )
            XCTAssertFalse(text.contains("jane.doe@example.com"))
            XCTAssertTrue(text.contains("contact1@example.com"))
        }

        let mapping = try MappingStore.load(
            from: URL(fileURLWithPath: summary.mappingFile),
            protection: .passphrase(passphrase)
        )
        XCTAssertEqual(mapping.style, .pseudonym)
    }

    // MARK: - Restore summary carries the ambiguity report

    func testRestoreSummaryJSONIncludesAmbiguousReplacements() throws {
        // Two CN mobiles that mask identically force an asterisk ambiguity.
        let url = tempDir.appendingPathComponent("phones.txt")
        try Data("A: 13812345678 B: 13887655678.".utf8).write(to: url)
        let outputDir = tempDir.appendingPathComponent("ast-out", isDirectory: true)

        let result = try LDACLI.runAnonymize(
            input: url,
            outputDir: outputDir,
            passphrase: passphrase,
            style: .asterisk,
            timestamp: { self.fixedTimestamp }
        )

        let report = try LDACLI.runRestore(
            input: result.redactedFileURL,
            mapping: result.mappingFileURL,
            output: tempDir.appendingPathComponent("restored.txt"),
            passphrase: passphrase
        )
        let summary = RestoreSummaryJSON(report: report)
        XCTAssertEqual(summary.ambiguousReplacements, ["138****5678"])
        XCTAssertEqual(summary.restoredCount, 0)

        // The JSON encodes the new field so scripts can see the refusal.
        let encoded = try CLIJSON.encode(summary)
        XCTAssertTrue(encoded.contains("\"ambiguousReplacements\":[\"138****5678\"]"))
    }
}
