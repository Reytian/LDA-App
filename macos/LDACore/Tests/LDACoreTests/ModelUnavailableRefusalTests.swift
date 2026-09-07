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
//  refused with LDAServiceError.modelUnavailable before anything is written,
//  on the facade, the session service, the CLI, and the MCP server alike (the
//  GUI never routes a model path through the facade; its own detection pass
//  already reports a missing model file, see DetectionReportingTests).
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACLI
@testable import LDACore
@testable import LDAMCP

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
        LDAService.makeExtractorForTesting = nil
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

    /// The thrown error must be the refusal, naming the path that was asked for.
    private func assertRefusal(_ error: Error, path: String, file: StaticString = #filePath, line: UInt = #line) {
        guard case .modelUnavailable(let reportedPath, let reason)? = error as? LDAServiceError else {
            XCTFail("expected LDAServiceError.modelUnavailable, got \(error)", file: file, line: line)
            return
        }
        XCTAssertEqual(reportedPath, path, file: file, line: line)
        XCTAssertFalse(reason.isEmpty, "the refusal must say what failed", file: file, line: line)
    }

    // MARK: - Facade

    func testDetectWithAMissingModelFileIsRefusedNotSilentlyDowngraded() throws {
        let input = try writeFixture()

        XCTAssertThrowsError(
            try LDAService.detect(input: input, llmModelPath: Self.bogusModelPath),
            "a model the caller asked for and that cannot run must be refused, not replaced by pattern-only detection"
        ) { assertRefusal($0, path: Self.bogusModelPath) }
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
        ) { assertRefusal($0, path: Self.bogusModelPath) }
        XCTAssertTrue(
            filesWritten(under: outputDir).isEmpty,
            "nothing may be written when the requested model cannot run, got \(filesWritten(under: outputDir))"
        )
    }

    func testDetectSummaryWithAMissingModelFileIsRefused() throws {
        let input = try writeFixture()

        XCTAssertThrowsError(
            try LDAService.detectSummary(input: input, llmModelPath: Self.bogusModelPath)
        ) { assertRefusal($0, path: Self.bogusModelPath) }
    }

    func testSessionAnonymizeWithAMissingModelFileIsRefused() throws {
        let input = try writeFixture()

        XCTAssertThrowsError(
            try LDAService.anonymizeSession(
                inputs: [input],
                createdAtISO8601: Self.createdAt,
                llmModelPath: Self.bogusModelPath
            )
        ) { assertRefusal($0, path: Self.bogusModelPath) }
    }

    func testAModelThatFailsToLoadIsRefusedTheSameWay() throws {
        // The seam stands in for the engine load; nil from it is a load that
        // failed. The file check is not the only gate: a present but broken
        // GGUF must be refused too, and through the same error.
        let input = try writeFixture()
        let presentButBroken = workDir.appendingPathComponent("broken.gguf").path
        try Data("not a gguf".utf8).write(to: URL(fileURLWithPath: presentButBroken))
        LDAService.makeExtractorForTesting = { _ in nil }

        XCTAssertThrowsError(
            try LDAService.detect(input: input, llmModelPath: presentButBroken)
        ) { assertRefusal($0, path: presentButBroken) }
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
        ) { assertRefusal($0, path: Self.bogusModelPath) }
        XCTAssertTrue(
            filesWritten(under: outputDir).isEmpty,
            "the CLI must not write an unredacted file for a model it could not run, got \(filesWritten(under: outputDir))"
        )
    }

    func testCLIDetectWithAMissingModelIsRefused() throws {
        let input = try writeFixture()

        XCTAssertThrowsError(
            try LDACLI.runDetect(input: input, llmModelPath: Self.bogusModelPath)
        ) { assertRefusal($0, path: Self.bogusModelPath) }
    }

    func testCLIMessageNamesThePathTheReasonAndTheWayOut() {
        let error = LDAServiceError.modelUnavailable(
            path: Self.bogusModelPath,
            reason: "the file does not exist"
        )

        let message = CLIRuntimeError(error).description

        XCTAssertTrue(message.contains(Self.bogusModelPath), message)
        XCTAssertTrue(message.contains("the file does not exist"), message)
        XCTAssertTrue(message.contains("Nothing was written"), message)
        XCTAssertTrue(message.contains("--model"), "the way out must be named, got: \(message)")
    }

    // MARK: - MCP

    func testMCPAnonymizeWithAMissingModelReturnsARefusalWithoutEchoingThePath() throws {
        // The path sits inside an allowed root so the path policy lets it
        // through and the model gate is what answers. The handle-first surface
        // never echoes a path, so the refusal is recognised by its code.
        let vaultDir = workDir.appendingPathComponent("vault", isDirectory: true)
        let server = MCPServer(environment: VaultTestSupport.serverEnvironment(vaultDir: vaultDir))
        let handle = try VaultTestSupport.vault(root: vaultDir)
            .stage(fileURL: try writeFixture(), stagedAtISO8601: Self.createdAt)
            .handle
        let missingButAllowed = workDir.appendingPathComponent("missing.gguf").path
        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": [
                "name": "anonymize",
                "arguments": ["handle": handle, "passphrase": "pw", "modelPath": missingButAllowed]
            ]
        ]

        let responseData = try XCTUnwrap(server.handle(try JSONSerialization.data(withJSONObject: request)))
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: responseData) as? [String: Any])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = (content.first?["text"] as? String) ?? ""

        XCTAssertEqual(result["isError"] as? Bool, true, "a model that cannot run must be an error, got: \(text)")
        XCTAssertTrue(text.contains("model_unavailable"), "the refusal must carry its code, got: \(text)")
        XCTAssertFalse(text.contains(missingButAllowed), "the boundary-safe message must not echo the path, got: \(text)")
        XCTAssertFalse(
            text.contains("allowed directories for GGUF models"),
            "an in-root path must be refused by the model gate, not the path policy, got: \(text)"
        )
    }

    // MARK: - The deliberate pattern-only path is untouched

    func testNilModelPathStaysTheDeliberatePatternOnlyPath() throws {
        let input = try writeFixture()

        let spans = try LDAService.detect(input: input, llmModelPath: nil)

        XCTAssertTrue(spans.contains { $0.type == .email && $0.text == Self.email })
    }
}
