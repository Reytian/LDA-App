//
//  MCPHardeningTests.swift
//  LDACoreTests
//
//  Two edges of the MCP server that are not about a tool's output:
//
//   - stdio framing, including the request-line size cap that stops a client
//     from growing the accumulation buffer without bound;
//   - the restore fallback to the legacy shared Keychain account, which must
//     fire only when the per-document key is MISSING and must never mask a
//     decryption failure behind the second attempt's error.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDACore
@testable import LDAMCP

final class MCPHardeningTests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPHardeningTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir, FileManager.default.fileExists(atPath: workDir.path) {
            try FileManager.default.removeItem(at: workDir)
        }
        try super.tearDownWithError()
    }

    // MARK: - Stdio framing

    func testCompleteLinesAreSplitOut() {
        let step = MCPServer.consume(
            buffer: Data(),
            appending: Data("{\"a\":1}\n{\"b\":2}\n".utf8)
        )

        XCTAssertEqual(step.lines.count, 2)
        XCTAssertEqual(String(decoding: step.lines[0], as: UTF8.self), "{\"a\":1}")
        XCTAssertEqual(String(decoding: step.lines[1], as: UTF8.self), "{\"b\":2}")
        XCTAssertTrue(step.buffer.isEmpty)
        XCTAssertFalse(step.oversizeDiscarded)
    }

    func testAPartialLineStaysBuffered() {
        // A request may arrive across several reads; the tail must be kept.
        let first = MCPServer.consume(buffer: Data(), appending: Data("{\"a\":".utf8))
        XCTAssertTrue(first.lines.isEmpty)
        XCTAssertFalse(first.oversizeDiscarded)

        let second = MCPServer.consume(buffer: first.buffer, appending: Data("1}\n".utf8))
        XCTAssertEqual(second.lines.count, 1)
        XCTAssertEqual(String(decoding: second.lines[0], as: UTF8.self), "{\"a\":1}")
    }

    func testAnOversizePartialLineIsDiscarded() {
        // No newline and past the cap: the bytes are dropped and the caller is
        // told to report a parse error, rather than the buffer growing until the
        // process dies.
        let oversize = Data(repeating: UInt8(ascii: "x"), count: MCPServer.maxRequestLineBytes + 1)

        let step = MCPServer.consume(buffer: Data(), appending: oversize)

        XCTAssertTrue(step.oversizeDiscarded)
        XCTAssertTrue(step.lines.isEmpty)
        XCTAssertTrue(step.buffer.isEmpty, "the accumulated bytes must not be retained")
    }

    func testAnOversizeBufferThatDoesContainANewlineIsStillFramed() {
        // The cap is about unbounded accumulation, not about refusing a large
        // chunk that happens to hold complete lines.
        var chunk = Data(repeating: UInt8(ascii: "x"), count: MCPServer.maxRequestLineBytes + 1)
        chunk.append(UInt8(ascii: "\n"))

        let step = MCPServer.consume(buffer: Data(), appending: chunk)

        XCTAssertFalse(step.oversizeDiscarded)
        XCTAssertEqual(step.lines.count, 1)
    }

    func testBufferGrowthIsBoundedAcrossManyChunks() {
        // The realistic attack is a stream of chunks with no newline. Whatever
        // the pattern, the retained buffer must stay bounded.
        var buffer = Data()
        let chunk = Data(repeating: UInt8(ascii: "x"), count: 1024 * 1024)
        for _ in 0 ..< 20 {
            let step = MCPServer.consume(buffer: buffer, appending: chunk)
            buffer = step.buffer
        }
        XCTAssertLessThanOrEqual(buffer.count, MCPServer.maxRequestLineBytes)
    }

    func testTheCapIsWellAboveARealRequest() {
        // Requests carry paths and options, never document bytes.
        XCTAssertGreaterThanOrEqual(MCPServer.maxRequestLineBytes, 1024 * 1024)
    }

    // MARK: - Restore fallback

    /// Send one tools/call and return the text of its content block.
    private func callText(tool: String, arguments: [String: Any]) throws -> (isError: Bool, text: String) {
        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": ["name": tool, "arguments": arguments]
        ]
        let payload = try JSONSerialization.data(withJSONObject: request)
        let responseData = try XCTUnwrap(MCPServer().handle(payload))
        let response = try XCTUnwrap(
            JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        )
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        return (
            isError: (result["isError"] as? Bool) ?? false,
            text: (content.first?["text"] as? String) ?? ""
        )
    }

    func testADecryptionFailureIsNotMaskedByTheLegacyRetry() throws {
        // Arrange: a sidecar protected by a PASSPHRASE, restored without one.
        // The container's protection tag will not match, which is a decryption
        // failure, not a missing key. It must be reported as such.
        let source = workDir.appendingPathComponent("brief.txt")
        try Data("Contact jane@example.test about the matter.".utf8).write(to: source)

        let anonymize = try callText(tool: "anonymize_document", arguments: [
            "input": source.path,
            "outputDir": workDir.path,
            "passphrase": "the pass phrase"
        ])
        XCTAssertFalse(anonymize.isError, anonymize.text)

        let summary = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(anonymize.text.utf8)) as? [String: Any]
        )
        let mapping = try XCTUnwrap(summary["mappingFile"] as? String)
        let redacted = try XCTUnwrap(summary["redactedFile"] as? String)

        // Act: restore with no passphrase, so the server picks Keychain protection.
        let restore = try callText(tool: "restore_document", arguments: [
            "editedRedacted": redacted,
            "mapping": mapping,
            "output": workDir.appendingPathComponent("restored.txt").path
        ])

        // Assert
        XCTAssertTrue(restore.isError, "restoring a passphrase sidecar without one must fail")
        XCTAssertTrue(
            restore.text.lowercased().contains("decrypt"),
            "the real cause must reach the user, got: \(restore.text)"
        )
        XCTAssertFalse(
            restore.text.contains("Legacy shared key"),
            "a decryption failure must not be retried against the legacy account; "
                + "that retry used to replace the real error. Got: \(restore.text)"
        )
    }

    func testTheLegacyRetryReportsBothFailuresWhenItAlsoFails() throws {
        // Arrange: a sidecar whose per-document Keychain key has been deleted,
        // and no legacy shared key either. Both attempts fail, and the message
        // must name both rather than only the second.
        let source = workDir.appendingPathComponent("brief.txt")
        try Data("Contact jane@example.test about the matter.".utf8).write(to: source)

        let anonymize = try callText(tool: "anonymize_document", arguments: [
            "input": source.path,
            "outputDir": workDir.path
        ])
        try XCTSkipIf(anonymize.isError, "Keychain unavailable: \(anonymize.text)")

        let summary = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(anonymize.text.utf8)) as? [String: Any]
        )
        let mappingPath = try XCTUnwrap(summary["mappingFile"] as? String)
        let redacted = try XCTUnwrap(summary["redactedFile"] as? String)
        let mappingURL = URL(fileURLWithPath: mappingPath)

        // Delete the per-document key so the first attempt reports errSecItemNotFound.
        let account = MCPServer.keychainAccount(
            forMappingBaseName: mappingURL.deletingPathExtension().lastPathComponent
        )
        try? MappingStore.deleteKeychainKey(account: account)
        try? MappingStore.deleteKeychainKey(account: MCPServer.defaultKeychainAccount)

        // Act
        let restore = try callText(tool: "restore_document", arguments: [
            "editedRedacted": redacted,
            "mapping": mappingPath,
            "output": workDir.appendingPathComponent("restored.txt").path
        ])

        // Assert
        XCTAssertTrue(restore.isError)
        XCTAssertTrue(
            restore.text.contains("Per-document key") && restore.text.contains("Legacy shared key"),
            "both attempts should be reported, got: \(restore.text)"
        )
    }
}
