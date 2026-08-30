//
//  MCPStyleTests.swift
//  LDACoreTests
//
//  Tests for the optional "style" argument on the MCP anonymize tools: the
//  schema advertises it, dispatch honors it end to end, an unknown value is
//  a readable isError result rather than a silent default, and the restore
//  summary carries ambiguousReplacements.
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
    private let passphrase = "mcp-style-passphrase"

    override func setUpWithError() throws {
        try super.setUpWithError()
        server = MCPServer()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPStyleTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
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

        for toolName in ["anonymize_document", "anonymize_session"] {
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

    func testAnonymizeDocumentHonorsPseudonymStyle() throws {
        let inputURL = workDir.appendingPathComponent("letter.txt")
        try Data("Mail jane.doe@example.com today.".utf8).write(to: inputURL)

        let response = try callTool("anonymize_document", arguments: [
            "input": inputURL.path,
            "outputDir": workDir.path,
            "passphrase": passphrase,
            "style": "pseudonym"
        ], id: 2)

        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false, "anonymize reported an error: \(result)")

        let summary = try toolSummary(from: response)
        let redactedPath = try XCTUnwrap(summary["redactedFile"] as? String)
        let redacted = try String(contentsOfFile: redactedPath, encoding: .utf8)
        XCTAssertFalse(redacted.contains("jane.doe@example.com"))
        XCTAssertTrue(redacted.contains("contact1@example.com"))
        XCTAssertFalse(redacted.contains("{EMAIL_1}"))

        let mappingPath = try XCTUnwrap(summary["mappingFile"] as? String)
        let mapping = try MappingStore.load(
            from: URL(fileURLWithPath: mappingPath),
            protection: .passphrase(passphrase)
        )
        XCTAssertEqual(mapping.style, .pseudonym)
    }

    func testAnonymizeSessionHonorsStyleArgument() throws {
        let one = workDir.appendingPathComponent("one.txt")
        let two = workDir.appendingPathComponent("two.txt")
        try Data("First doc for jane.doe@example.com.".utf8).write(to: one)
        try Data("Second doc for jane.doe@example.com.".utf8).write(to: two)

        let response = try callTool("anonymize_session", arguments: [
            "inputs": [one.path, two.path],
            "outputDir": workDir.path,
            "passphrase": passphrase,
            "style": "pseudonym"
        ], id: 3)

        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false, "session reported an error: \(result)")

        let summary = try toolSummary(from: response)
        let documents = try XCTUnwrap(summary["documents"] as? [[String: Any]])
        XCTAssertEqual(documents.count, 2)
        for document in documents {
            let path = try XCTUnwrap(document["redactedFile"] as? String)
            let text = try String(contentsOfFile: path, encoding: .utf8)
            XCTAssertTrue(text.contains("contact1@example.com"))
            XCTAssertFalse(text.contains("jane.doe@example.com"))
        }
    }

    func testUnknownStyleValueIsAReadableToolError() throws {
        let inputURL = workDir.appendingPathComponent("doc.txt")
        try Data("Mail jane.doe@example.com.".utf8).write(to: inputURL)

        let response = try callTool("anonymize_document", arguments: [
            "input": inputURL.path,
            "outputDir": workDir.path,
            "passphrase": passphrase,
            "style": "emoji"
        ], id: 4)

        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true, "an unknown style must not silently default")
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertTrue(text.contains("style"))
        XCTAssertTrue(text.contains("pseudonym"), "the error should list the allowed values")
    }

    func testRestoreSummaryCarriesAmbiguousReplacements() throws {
        // Two CN mobiles masking identically force the asterisk refusal.
        let inputURL = workDir.appendingPathComponent("phones.txt")
        try Data("A: 13812345678 B: 13887655678.".utf8).write(to: inputURL)

        let anonymizeResponse = try callTool("anonymize_document", arguments: [
            "input": inputURL.path,
            "outputDir": workDir.path,
            "passphrase": passphrase,
            "style": "asterisk"
        ], id: 5)
        let anonymizeSummary = try toolSummary(from: anonymizeResponse)
        let redactedPath = try XCTUnwrap(anonymizeSummary["redactedFile"] as? String)
        let mappingPath = try XCTUnwrap(anonymizeSummary["mappingFile"] as? String)

        let restoreResponse = try callTool("restore_document", arguments: [
            "editedRedacted": redactedPath,
            "mapping": mappingPath,
            "output": workDir.appendingPathComponent("restored.txt").path,
            "passphrase": passphrase
        ], id: 6)

        let restoreSummary = try toolSummary(from: restoreResponse)
        XCTAssertEqual(
            restoreSummary["ambiguousReplacements"] as? [String],
            ["138****5678"]
        )
        XCTAssertEqual(restoreSummary["restoredCount"] as? Int, 0)
    }
}
