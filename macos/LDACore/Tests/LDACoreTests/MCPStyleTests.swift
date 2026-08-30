//
//  MCPStyleTests.swift
//  LDACoreTests
//
//  Tests for the optional "style" argument on the handle-first MCP anonymize
//  tools: the schema advertises it, dispatch honors it end to end through the
//  vault, an unknown value is a readable isError result rather than a silent
//  default, and the restore summary carries ambiguousReplacements.
//
//  House rules: all comments and strings in English. Fixture strings and
//  generated pseudonyms may be Chinese. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDAMCP
@testable import LDACore

final class MCPStyleTests: XCTestCase {
    private var server: MCPServer!
    private var workDir: URL!
    private var vaultDir: URL!
    private let passphrase = "mcp-style-passphrase"

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPStyleTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        vaultDir = workDir.appendingPathComponent("vault", isDirectory: true)
        server = MCPServer(environment: [DocumentVault.environmentKey: vaultDir.path])
    }

    override func tearDownWithError() throws {
        if let workDir, FileManager.default.fileExists(atPath: workDir.path) {
            try? FileManager.default.removeItem(at: workDir)
        }
        try super.tearDownWithError()
    }

    // MARK: - Helpers (MCPTests conventions)

    private func roundTrip(_ request: [String: Any]) throws -> [String: Any] {
        let requestData = try JSONSerialization.data(withJSONObject: request)
        guard let responseData = server.handle(requestData) else {
            XCTFail("Expected a response for request \(request)")
            return [:]
        }
        let object = try JSONSerialization.jsonObject(with: responseData)
        guard let dict = object as? [String: Any] else {
            throw XCTSkip("Response was not a JSON object")
        }
        return dict
    }

    private func toolSummary(from response: [String: Any]) throws -> [String: Any] {
        guard
            let result = response["result"] as? [String: Any],
            let content = result["content"] as? [[String: Any]],
            let first = content.first,
            let text = first["text"] as? String
        else {
            throw XCTSkip("tools/call result had no text content: \(response)")
        }
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8))
        guard let dict = object as? [String: Any] else {
            throw XCTSkip("tool summary text was not a JSON object: \(text)")
        }
        return dict
    }

    private func callTool(
        _ name: String,
        arguments: [String: Any],
        id: Int
    ) throws -> [String: Any] {
        try roundTrip([
            "jsonrpc": "2.0",
            "id": id,
            "method": "tools/call",
            "params": ["name": name, "arguments": arguments]
        ])
    }

    /// Stage a text fixture into this test's vault and return its handle.
    private func stage(_ contents: String, named name: String) throws -> String {
        let url = workDir.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return try DocumentVault(rootDirectory: vaultDir)
            .stage(fileURL: url, stagedAtISO8601: "2026-08-30T00:00:00Z")
            .handle
    }

    /// Read the redacted text back through the read_redacted tool.
    private func readRedacted(handle: String, id: Int) throws -> String {
        let response = try callTool("read_redacted", arguments: ["handle": handle], id: id)
        let summary = try toolSummary(from: response)
        return try XCTUnwrap(summary["text"] as? String)
    }

    // MARK: - Schema

    func testAnonymizeToolSchemasAdvertiseStyleEnum() throws {
        let response = try roundTrip([
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/list",
            "params": [:]
        ])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])

        for toolName in ["anonymize", "anonymize_session"] {
            let tool = try XCTUnwrap(
                tools.first { ($0["name"] as? String) == toolName },
                "\(toolName) must be advertised"
            )
            let schema = try XCTUnwrap(tool["inputSchema"] as? [String: Any])
            let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
            let style = try XCTUnwrap(
                properties["style"] as? [String: Any],
                "\(toolName) must advertise the style argument"
            )
            XCTAssertEqual(style["enum"] as? [String], ["token", "pseudonym", "asterisk"])
            // Additive change: style must remain optional.
            let required = try XCTUnwrap(schema["required"] as? [String])
            XCTAssertFalse(required.contains("style"))
        }
    }

    // MARK: - Dispatch

    func testAnonymizeHonorsPseudonymStyle() throws {
        let handle = try stage("Mail jane.doe@example.com today.", named: "letter.txt")

        let response = try callTool("anonymize", arguments: [
            "handle": handle,
            "passphrase": passphrase,
            "style": "pseudonym"
        ], id: 2)

        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false, "anonymize reported an error: \(result)")

        let summary = try toolSummary(from: response)
        let redactedHandle = try XCTUnwrap(summary["redactedHandle"] as? String)
        let redacted = try readRedacted(handle: redactedHandle, id: 3)
        XCTAssertFalse(redacted.contains("jane.doe@example.com"))
        XCTAssertTrue(redacted.contains("contact1@example.com"))
        XCTAssertFalse(redacted.contains("{EMAIL_1}"))

        // The sidecar inside the vault records the style, so restore picks the
        // literal scan without being told. The test owns the vault dir, so
        // reaching into it is fine here; MCP clients never see this path.
        let mappingURL = try DocumentVault(rootDirectory: vaultDir)
            .mappingFileURL(forHandle: redactedHandle)
        let mapping = try MappingStore.load(
            from: mappingURL,
            protection: .passphrase(passphrase)
        )
        XCTAssertEqual(mapping.style, .pseudonym)
    }

    func testAnonymizeSessionHonorsStyleArgument() throws {
        let one = try stage("First doc for jane.doe@example.com.", named: "one.txt")
        let two = try stage("Second doc for jane.doe@example.com.", named: "two.txt")

        let response = try callTool("anonymize_session", arguments: [
            "handles": [one, two],
            "passphrase": passphrase,
            "style": "pseudonym"
        ], id: 4)

        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false, "session reported an error: \(result)")

        let summary = try toolSummary(from: response)
        let documents = try XCTUnwrap(summary["documents"] as? [[String: Any]])
        XCTAssertEqual(documents.count, 2)
        for (index, document) in documents.enumerated() {
            let redactedHandle = try XCTUnwrap(document["redactedHandle"] as? String)
            let text = try readRedacted(handle: redactedHandle, id: 5 + index)
            XCTAssertTrue(text.contains("contact1@example.com"))
            XCTAssertFalse(text.contains("jane.doe@example.com"))
        }
    }

    func testUnknownStyleValueIsAReadableToolError() throws {
        let handle = try stage("Mail jane.doe@example.com.", named: "doc.txt")

        let response = try callTool("anonymize", arguments: [
            "handle": handle,
            "passphrase": passphrase,
            "style": "emoji"
        ], id: 7)

        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true, "an unknown style must not silently default")
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertTrue(text.contains("style"))
        XCTAssertTrue(text.contains("pseudonym"), "the error should list the allowed values")
    }

    func testRestoreSummaryCarriesAmbiguousReplacements() throws {
        // Two CN mobiles masking identically force the asterisk refusal.
        let handle = try stage("A: 13812345678 B: 13887655678.", named: "phones.txt")

        let anonymizeResponse = try callTool("anonymize", arguments: [
            "handle": handle,
            "passphrase": passphrase,
            "style": "asterisk"
        ], id: 8)
        let anonymizeSummary = try toolSummary(from: anonymizeResponse)
        let redactedHandle = try XCTUnwrap(anonymizeSummary["redactedHandle"] as? String)

        let restoreResponse = try callTool("restore", arguments: [
            "redactedHandle": redactedHandle,
            "passphrase": passphrase
        ], id: 9)

        let restoreSummary = try toolSummary(from: restoreResponse)
        XCTAssertEqual(
            restoreSummary["ambiguousReplacements"] as? [String],
            ["138****5678"]
        )
        XCTAssertEqual(restoreSummary["restoredCount"] as? Int, 0)
    }
}
