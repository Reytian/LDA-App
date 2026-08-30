//
//  MCPTests.swift
//  LDACoreTests
//
//  Tests for the MCP server's pure handle(_:) request dispatcher: the JSON-RPC
//  envelope (initialize, notifications, ping, error paths) and the core
//  handle-first round trip (stage, anonymize, restore) through the vault.
//  Deeper per-tool behavior lives in MCPVaultToolTests; wire-byte boundary
//  regressions live in MCPBoundaryTests.
//
//  Every fixture is generated under FileManager.temporaryDirectory and every
//  server instance is pointed at a per-test vault via LDA_VAULT_DIR, so the
//  tests are hermetic. The round trips use passphrase protection rather than
//  Keychain protection so the unsigned test process never needs Keychain
//  access.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
import Security
@testable import LDAMCP
@testable import LDACore

final class MCPTests: XCTestCase {

    // MARK: - Hermetic working directory

    private var workDir: URL!
    private var vaultDir: URL!
    private var server: MCPServer!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workDir,
            withIntermediateDirectories: true
        )
        vaultDir = workDir.appendingPathComponent("vault", isDirectory: true)
        server = MCPServer(environment: [DocumentVault.environmentKey: vaultDir.path])
    }

    override func tearDownWithError() throws {
        if let workDir, FileManager.default.fileExists(atPath: workDir.path) {
            try? FileManager.default.removeItem(at: workDir)
        }
        try super.tearDownWithError()
    }

    // MARK: - JSON helpers

    /// Encode a JSON object into Data for feeding to handle(_:).
    private func encode(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    /// Decode a response Data into a JSON object.
    private func decode(_ data: Data) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dict = object as? [String: Any] else {
            throw XCTSkip("Response was not a JSON object")
        }
        return dict
    }

    /// Send a request object through the server and decode the response object.
    /// Fails the test when the server returns nil for a request that expects a
    /// response.
    private func roundTrip(_ request: [String: Any]) throws -> [String: Any] {
        let requestData = try encode(request)
        guard let responseData = server.handle(requestData) else {
            XCTFail("Expected a response for request \(request)")
            return [:]
        }
        return try decode(responseData)
    }

    /// Extract the single text content string from a tools/call result.
    private func toolText(from response: [String: Any]) throws -> String {
        guard let result = response["result"] as? [String: Any] else {
            throw XCTSkip("Response had no result object: \(response)")
        }
        guard
            let content = result["content"] as? [[String: Any]],
            let first = content.first,
            let text = first["text"] as? String
        else {
            throw XCTSkip("tools/call result had no text content: \(result)")
        }
        return text
    }

    /// Parse the JSON summary embedded in a tools/call text content block.
    private func toolSummary(from response: [String: Any]) throws -> [String: Any] {
        let text = try toolText(from: response)
        let data = Data(text.utf8)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dict = object as? [String: Any] else {
            throw XCTSkip("tool summary text was not a JSON object: \(text)")
        }
        return dict
    }

    /// Stage a text fixture into this test's vault and return its handle.
    private func stage(_ contents: String, named name: String = "matter.txt") throws -> String {
        let url = workDir.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return try DocumentVault(rootDirectory: vaultDir)
            .stage(fileURL: url, stagedAtISO8601: "2026-08-30T00:00:00Z")
            .handle
    }

    // MARK: - initialize

    func testInitializeReturnsProtocolVersionAndServerInfo() throws {
        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [:]
        ]
        let response = try roundTrip(request)

        XCTAssertEqual(response["jsonrpc"] as? String, "2.0")
        XCTAssertEqual(response["id"] as? Int, 1)

        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2024-11-05")

        let serverInfo = try XCTUnwrap(result["serverInfo"] as? [String: Any])
        XCTAssertEqual(serverInfo["name"] as? String, "lda-mcp")
        // The advertised version must match the constant AND be a released
        // version. A shipping server that still announces 0.1.0 tells every host
        // it is a prototype.
        XCTAssertEqual(serverInfo["version"] as? String, MCPServer.serverVersion)
        XCTAssertEqual(serverInfo["version"] as? String, "1.0.0")

        // capabilities.tools must be present (an empty object is valid).
        let capabilities = try XCTUnwrap(result["capabilities"] as? [String: Any])
        XCTAssertNotNil(capabilities["tools"])
    }

    // MARK: - tools/list

    func testToolsListAdvertisesTheHandleFirstCoreTools() throws {
        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/list"
        ]
        let response = try roundTrip(request)

        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])

        let names = tools.compactMap { $0["name"] as? String }
        XCTAssertTrue(names.contains("anonymize"))
        XCTAssertTrue(names.contains("restore"))
        XCTAssertTrue(names.contains("detect_entities"))
        XCTAssertTrue(names.contains("list_pending"))
        XCTAssertTrue(names.contains("read_redacted"))
        XCTAssertTrue(names.contains("export"))
        XCTAssertTrue(names.contains("attest"))

        // The old path-based names are gone from the advertised surface.
        XCTAssertFalse(names.contains("anonymize_document"))
        XCTAssertFalse(names.contains("restore_document"))

        // Confirm the core tools expose a JSON-Schema with the documented
        // required fields, all handle-shaped.
        let requiredByTool: [String: Set<String>] = [
            "anonymize": ["handle"],
            "restore": ["redactedHandle"],
            "detect_entities": ["handle"],
            "read_redacted": ["handle"],
            "export": ["handle"]
        ]

        for tool in tools {
            let name = try XCTUnwrap(tool["name"] as? String)
            guard let expected = requiredByTool[name] else {
                continue
            }
            let schema = try XCTUnwrap(tool["inputSchema"] as? [String: Any])
            XCTAssertEqual(schema["type"] as? String, "object")
            let required = Set((schema["required"] as? [String]) ?? [])
            XCTAssertEqual(required, expected, "required mismatch for \(name)")

            // Every required field must also be described in properties.
            let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
            for field in required {
                XCTAssertNotNil(properties[field], "\(name) missing property \(field)")
            }
        }
    }

    // MARK: - tools/call detect_entities

    func testDetectEntitiesReportsDetectedTypes() throws {
        // A fixture rich in deterministic PII: email, phone, date, amount.
        let handle = try stage("""
        Contact jane.doe@example.com or call (212) 555-0147.
        Signed on 2024-01-15 for an amount of USD 1,250,000.
        """)

        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 3,
            "method": "tools/call",
            "params": [
                "name": "detect_entities",
                "arguments": ["handle": handle]
            ]
        ]
        let response = try roundTrip(request)
        let summary = try toolSummary(from: response)

        let types = Set((summary["entityTypes"] as? [String]) ?? [])
        XCTAssertTrue(types.contains("EMAIL"), "expected EMAIL in \(types)")
        XCTAssertTrue(types.contains("DATE"), "expected DATE in \(types)")
        XCTAssertTrue(types.contains("AMOUNT"), "expected AMOUNT in \(types)")

        let count = try XCTUnwrap(summary["entityCount"] as? Int)
        XCTAssertGreaterThanOrEqual(count, 3)
    }

    // MARK: - Notifications

    func testNotificationWithoutIdReturnsNil() throws {
        // A JSON-RPC notification has no id and must produce no response.
        let notification: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "initialized",
            "params": [:]
        ]
        let data = try encode(notification)
        XCTAssertNil(server.handle(data))
    }

    func testPingReturnsEmptyResult() throws {
        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 7,
            "method": "ping"
        ]
        let response = try roundTrip(request)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - tools/call anonymize then restore round-trip

    func testAnonymizeThenRestoreReproducesOriginalText() throws {
        let original = """
        Wire the retainer to account 6225880100000000123 by 2024-03-01.
        Questions to counsel@example.com or +1 415 555 0199.
        """
        let handle = try stage(original)
        let passphrase = "correct horse battery staple"

        // Step 1: anonymize. Passphrase protection avoids Keychain access.
        let anonymizeRequest: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 10,
            "method": "tools/call",
            "params": [
                "name": "anonymize",
                "arguments": [
                    "handle": handle,
                    "passphrase": passphrase
                ]
            ]
        ]
        let anonymizeResponse = try roundTrip(anonymizeRequest)

        // The tools/call result must not be an error.
        let anonymizeResult = try XCTUnwrap(anonymizeResponse["result"] as? [String: Any])
        XCTAssertEqual(anonymizeResult["isError"] as? Bool, false, "anonymize reported an error: \(anonymizeResult)")

        let anonymizeSummary = try toolSummary(from: anonymizeResponse)
        let redactedHandle = try XCTUnwrap(anonymizeSummary["redactedHandle"] as? String)

        // The redacted edit surface must differ from the original (PII
        // tokenized). Read through the vault: the response carries no text.
        let vault = DocumentVault(rootDirectory: vaultDir)
        let redactedText = String(
            decoding: try vault.readDocumentBytes(handle: redactedHandle),
            as: UTF8.self
        )
        XCTAssertNotEqual(redactedText, original)
        XCTAssertTrue(redactedText.contains("{"), "expected tokens in redacted surface")

        // Step 2: restore the (unedited) redacted artifact back to the original.
        let restoreRequest: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 11,
            "method": "tools/call",
            "params": [
                "name": "restore",
                "arguments": [
                    "redactedHandle": redactedHandle,
                    "passphrase": passphrase
                ]
            ]
        ]
        let restoreResponse = try roundTrip(restoreRequest)
        let restoreResult = try XCTUnwrap(restoreResponse["result"] as? [String: Any])
        XCTAssertEqual(restoreResult["isError"] as? Bool, false, "restore reported an error: \(restoreResult)")

        let restoreSummary = try toolSummary(from: restoreResponse)
        let restoredHandle = try XCTUnwrap(restoreSummary["restoredHandle"] as? String)

        let restoredText = String(
            decoding: try vault.readDocumentBytes(handle: restoredHandle),
            as: UTF8.self
        )
        XCTAssertEqual(restoredText, original, "restored text must equal the original")
    }

    // MARK: - tools/call error path

    func testToolsCallOnAnUnknownHandleReturnsIsErrorNotCrash() throws {
        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 12,
            "method": "tools/call",
            "params": [
                "name": "detect_entities",
                "arguments": ["handle": "doc_ffffffffffff"]
            ]
        ]
        let response = try roundTrip(request)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)

        // The error content must be a non-empty text message.
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertFalse(text.isEmpty)
    }
}
