//
//  LLMExtractorFailureCoverageTests.swift
//  LDACoreTests
//
//  A model completion that never happened, or that came back as something
//  other than the entities JSON, is not a scan. Before these tests a throwing
//  completer became an empty SUCCESSFUL segment and a prose reply such as
//  "I cannot process this text." became an empty, non-truncated extraction,
//  so ExtractionResult.fullyCovered stayed true, LDAService accepted the
//  result, and the redacted artifact was written although no name in it had
//  been looked at.
//
//  The repaired contract: a genuinely empty entities array is a clean scan; a
//  backend failure, an empty reply, prose, or a JSON object without the
//  entities schema marks the segment unscanned, so the existing coverage gate
//  refuses exactly as it does for a truncated completion.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore

final class LLMExtractorFailureCoverageTests: XCTestCase {

    private struct FixedCompleter: TextCompleter {
        let output: String
        func complete(prompt: String, maxTokens: Int?, stop: [String]) throws -> String {
            return output
        }
    }

    private struct ThrowingCompleter: TextCompleter {
        struct BackendDown: Error {}
        func complete(prompt: String, maxTokens: Int?, stop: [String]) throws -> String {
            throw BackendDown()
        }
    }

    /// Short enough to be a single extraction window, so one failure is one
    /// unscanned segment.
    private static let text = "Alice Smith signed for Acme Corporation. Contact alice@example.com."

    override func setUpWithError() throws {
        try super.setUpWithError()
        assertNoTestSeamsInstalled()
    }

    override func tearDown() {
        LDAService.makeExtractorForTesting = nil
        super.tearDown()
    }

    // MARK: - Extractor: a failure is an unscanned segment

    func testThrowingCompleterMarksTheSegmentUnscanned() throws {
        let result = try LLMExtractor(completer: ThrowingCompleter()).extractDetailed(from: Self.text)

        XCTAssertEqual(
            result.incompleteSegmentCount, 1,
            "a backend failure is a segment that was never scanned"
        )
        XCTAssertFalse(result.fullyCovered, "a backend failure must not pass the coverage gate")
        XCTAssertTrue(result.spans.isEmpty)
    }

    func testProseReplyMarksTheSegmentUnscanned() throws {
        let completer = FixedCompleter(output: "I cannot process this text.")

        let result = try LLMExtractor(completer: completer).extractDetailed(from: Self.text)

        XCTAssertFalse(
            result.fullyCovered,
            "a prose reply carries no entities array, so nothing was scanned"
        )
        XCTAssertEqual(result.incompleteSegmentCount, 1)
    }

    func testEmptyReplyMarksTheSegmentUnscanned() throws {
        let result = try LLMExtractor(completer: FixedCompleter(output: "")).extractDetailed(from: Self.text)

        XCTAssertFalse(result.fullyCovered, "an empty completion is not an empty entities array")
    }

    func testObjectWithoutTheEntitiesSchemaMarksTheSegmentUnscanned() throws {
        let completer = FixedCompleter(output: #"{"error":"context window exceeded"}"#)

        let result = try LLMExtractor(completer: completer).extractDetailed(from: Self.text)

        XCTAssertFalse(
            result.fullyCovered,
            "valid JSON without an entities array is a schema failure, not a clean scan"
        )
    }

    func testWellFormedEmptyEntitiesArrayIsAFullyCoveredScan() throws {
        let completer = FixedCompleter(output: #"{"entities":[],"redacted_text":""}"#)

        let result = try LLMExtractor(completer: completer).extractDetailed(from: Self.text)

        XCTAssertTrue(result.fullyCovered, "the model looked and found nothing: that is a clean scan")
        XCTAssertEqual(result.incompleteSegmentCount, 0)
    }

    func testBareEmptyArrayIsAFullyCoveredScan() throws {
        let result = try LLMExtractor(completer: FixedCompleter(output: "[]")).extractDetailed(from: Self.text)

        XCTAssertTrue(result.fullyCovered)
    }

    // MARK: - Service: the gate refuses what the extractor could not scan

    private func writeFixture() throws -> (dir: URL, input: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LLMExtractorFailureCoverageTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let input = dir.appendingPathComponent("source.txt")
        try Data(Self.text.utf8).write(to: input)
        return (dir, input)
    }

    func testDetectRefusesWhenTheBackendFailed() throws {
        let fixture = try writeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.dir) }
        LDAService.makeExtractorForTesting = { _ in LLMExtractor(completer: ThrowingCompleter()) }

        XCTAssertThrowsError(
            try LDAService.detect(input: fixture.input, llmModelPath: "/nonexistent.gguf")
        ) { error in
            XCTAssertEqual(
                error as? LDAServiceError,
                .incompleteExtraction(incompleteSegmentCount: 1)
            )
        }
    }

    func testAnonymizeWritesNothingWhenTheModelRepliedInProse() throws {
        let fixture = try writeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.dir) }
        LDAService.makeExtractorForTesting = { _ in
            LLMExtractor(completer: FixedCompleter(output: "I cannot process this text."))
        }
        let outputDir = fixture.dir.appendingPathComponent("out", isDirectory: true)

        XCTAssertThrowsError(
            try LDAService.anonymize(
                input: fixture.input,
                outputDir: outputDir,
                protection: .passphrase("pw"),
                createdAtISO8601: "2026-09-07T00:00:00Z",
                llmModelPath: "/nonexistent.gguf"
            )
        ) { error in
            XCTAssertEqual(
                error as? LDAServiceError,
                .incompleteExtraction(incompleteSegmentCount: 1)
            )
        }
        let written = (try? FileManager.default.contentsOfDirectory(atPath: outputDir.path)) ?? []
        XCTAssertTrue(written.isEmpty, "no artifact may be written for an unscanned document, got \(written)")
    }
}
