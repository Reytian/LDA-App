//
//  ModelUnavailableRefusalTests.swift
//  LDACoreTests
//
//  A caller who passes a model path is asking for PERSON, COMPANY, and ADDRESS
//  detection. When that model cannot run, the only honest answers are a
//  refusal or an explicitly reported fallback. Before these tests the service
//  quietly built a deterministic-only detector for a path that did not exist,
//  so the compiled CLI accepted a nonexistent --model, exited 0, and wrote
//  "Alice Smith signed for Acme Corporation." unredacted with no warning.
//
//  The repaired contract: a nil model path is the deliberate pattern-only
//  path and keeps working; a non-nil path that cannot be opened or loaded is
//  refused before anything is written, on the facade, the session service,
//  and the CLI alike (the MCP server routes through the same facade, and the
//  GUI already reports a missing model file in its own detection pass).
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACLI
@testable import LDACore

final class ModelUnavailableRefusalTests: XCTestCase {

    private static let bogusModelPath = "/nonexistent-lda-model.gguf"
    private static let email = "jane.doe@example.com"
    private static let createdAt = "2026-09-07T00:00:00Z"

    private var workDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        assertNoTestSeamsInstalled()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelUnavailableRefusalTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir, FileManager.default.fileExists(atPath: workDir.path) {
            try? FileManager.default.removeItem(at: workDir)
        }
        workDir = nil
        try super.tearDownWithError()
    }

    private func writeFixture() throws -> URL {
        let input = workDir.appendingPathComponent("source.txt")
        try Data("Alice Smith signed for Acme Corporation. Contact \(Self.email).".utf8).write(to: input)
        return input
    }

    private func filesWritten(under dir: URL) -> [String] {
        return (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    }

    // MARK: - Facade

    func testDetectWithAMissingModelFileIsRefusedNotSilentlyDowngraded() throws {
        let input = try writeFixture()

        XCTAssertThrowsError(
            try LDAService.detect(input: input, llmModelPath: Self.bogusModelPath),
            "a model the caller asked for and that cannot run must be refused, not replaced by pattern-only detection"
        )
    }

    func testAnonymizeWithAMissingModelFileWritesNothing() throws {
        let input = try writeFixture()
        let outputDir = workDir.appendingPathComponent("out", isDirectory: true)

        XCTAssertThrowsError(
            try LDAService.anonymize(
                input: input,
                outputDir: outputDir,
                protection: .passphrase("pw"),
                createdAtISO8601: Self.createdAt,
                llmModelPath: Self.bogusModelPath
            )
        )
        XCTAssertTrue(
            filesWritten(under: outputDir).isEmpty,
            "nothing may be written when the requested model cannot run, got \(filesWritten(under: outputDir))"
        )
    }

    func testDetectSummaryWithAMissingModelFileIsRefused() throws {
        let input = try writeFixture()

        XCTAssertThrowsError(try LDAService.detectSummary(input: input, llmModelPath: Self.bogusModelPath))
    }

    func testSessionAnonymizeWithAMissingModelFileIsRefused() throws {
        let input = try writeFixture()

        XCTAssertThrowsError(
            try LDAService.anonymizeSession(
                inputs: [input],
                createdAtISO8601: Self.createdAt,
                llmModelPath: Self.bogusModelPath
            )
        )
    }

    // MARK: - CLI

    func testCLIAnonymizeWithAMissingModelIsRefusedAndWritesNothing() throws {
        let input = try writeFixture()
        let outputDir = workDir.appendingPathComponent("cli-out", isDirectory: true)

        XCTAssertThrowsError(
            try LDACLI.runAnonymize(
                input: input,
                outputDir: outputDir,
                passphrase: "pw",
                llmModelPath: Self.bogusModelPath
            )
        )
        XCTAssertTrue(
            filesWritten(under: outputDir).isEmpty,
            "the CLI must not write an unredacted file for a model it could not run, got \(filesWritten(under: outputDir))"
        )
    }

    func testCLIDetectWithAMissingModelIsRefused() throws {
        let input = try writeFixture()

        XCTAssertThrowsError(try LDACLI.runDetect(input: input, llmModelPath: Self.bogusModelPath))
    }

    // MARK: - The deliberate pattern-only path is untouched

    func testNilModelPathStaysTheDeliberatePatternOnlyPath() throws {
        let input = try writeFixture()

        let spans = try LDAService.detect(input: input, llmModelPath: nil)

        XCTAssertTrue(spans.contains { $0.type == .email && $0.text == Self.email })
    }
}
