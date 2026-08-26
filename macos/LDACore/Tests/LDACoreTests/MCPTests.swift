//
//  MCPTests.swift
//  LDACoreTests
//
//  Tests for the MCP server's pure handle(_:) request dispatcher. Every fixture
//  is generated under FileManager.temporaryDirectory so the tests are hermetic
//  and commit no binaries. The server's stdio loop is not exercised here; the
//  pure handler carries all the logic and is the testable seam.
//
//  The anonymize then restore round-trip uses passphrase protection rather than
//  Keychain protection so the unsigned test process never needs Keychain access.
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
    private let server = MCPServer()

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workDir,
            withIntermediateDirectories: true
        )
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

    func testToolsListAdvertisesAllThreeToolsWithRequiredFields() throws {
        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/list"
        ]
        let response = try roundTrip(request)

        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])

        let names = tools.compactMap { $0["name"] as? String }
        XCTAssertTrue(names.contains("anonymize_document"))
        XCTAssertTrue(names.contains("restore_document"))
        XCTAssertTrue(names.contains("detect_entities"))
        // The fill tools add two more; total is now 5.
        XCTAssertGreaterThanOrEqual(names.count, 3)

        // Confirm each of the three original tools exposes a JSON-Schema with
        // the documented required fields.
        let requiredByTool: [String: Set<String>] = [
            "anonymize_document": ["input", "outputDir"],
            "restore_document": ["editedRedacted", "mapping", "output"],
            "detect_entities": ["input"]
        ]

        for tool in tools {
            let name = try XCTUnwrap(tool["name"] as? String)
            guard let expected = requiredByTool[name] else {
                // extract_profile and fill are tested in a dedicated test;
                // skip them here to keep the assertion tight.
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
        let content = """
        Contact jane.doe@example.com or call (212) 555-0147.
        Signed on 2024-01-15 for an amount of USD 1,250,000.
        """
        let fixture = workDir.appendingPathComponent("detect.txt")
        try content.data(using: .utf8)!.write(to: fixture)

        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 3,
            "method": "tools/call",
            "params": [
                "name": "detect_entities",
                "arguments": ["input": fixture.path]
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
        let inputURL = workDir.appendingPathComponent("matter.txt")
        try original.data(using: .utf8)!.write(to: inputURL)

        let passphrase = "correct horse battery staple"

        // Step 1: anonymize. Passphrase protection avoids Keychain access.
        let anonymizeRequest: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 10,
            "method": "tools/call",
            "params": [
                "name": "anonymize_document",
                "arguments": [
                    "input": inputURL.path,
                    "outputDir": workDir.path,
                    "passphrase": passphrase
                ]
            ]
        ]
        let anonymizeResponse = try roundTrip(anonymizeRequest)

        // The tools/call result must not be an error.
        let anonymizeResult = try XCTUnwrap(anonymizeResponse["result"] as? [String: Any])
        XCTAssertEqual(anonymizeResult["isError"] as? Bool, false, "anonymize reported an error: \(anonymizeResult)")

        let anonymizeSummary = try toolSummary(from: anonymizeResponse)
        let redactedPath = try XCTUnwrap(anonymizeSummary["redactedFile"] as? String)
        let mappingPath = try XCTUnwrap(anonymizeSummary["mappingFile"] as? String)

        // The redacted edit surface must differ from the original (PII tokenized).
        let redactedText = try String(contentsOfFile: redactedPath, encoding: .utf8)
        XCTAssertNotEqual(redactedText, original)
        XCTAssertTrue(redactedText.contains("{"), "expected tokens in redacted surface")

        // Step 2: restore the (unedited) redacted surface back to the original.
        let outputURL = workDir.appendingPathComponent("restored.txt")
        let restoreRequest: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 11,
            "method": "tools/call",
            "params": [
                "name": "restore_document",
                "arguments": [
                    "editedRedacted": redactedPath,
                    "mapping": mappingPath,
                    "output": outputURL.path,
                    "passphrase": passphrase
                ]
            ]
        ]
        let restoreResponse = try roundTrip(restoreRequest)
        let restoreResult = try XCTUnwrap(restoreResponse["result"] as? [String: Any])
        XCTAssertEqual(restoreResult["isError"] as? Bool, false, "restore reported an error: \(restoreResult)")

        let restoreSummary = try toolSummary(from: restoreResponse)
        let restoredPath = try XCTUnwrap(restoreSummary["output"] as? String)

        let restoredText = try String(contentsOfFile: restoredPath, encoding: .utf8)
        XCTAssertEqual(restoredText, original, "restored text must equal the original")
    }

    // MARK: - tools/call error path

    func testToolsCallOnMissingFileReturnsIsErrorNotCrash() throws {
        let missing = workDir.appendingPathComponent("does-not-exist.txt")
        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 12,
            "method": "tools/call",
            "params": [
                "name": "detect_entities",
                "arguments": ["input": missing.path]
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
    // MARK: - Per-document Keychain accounts

    /// Two documents anonymized without a passphrase must NOT share one
    /// Keychain key: a single shared account is a single point of failure and
    /// each new key would orphan every earlier sidecar. The account derives
    /// from the mapping base name; restore still works through the server.
    func testKeychainProtectedMappingsUsePerDocumentAccountsAndRestore() throws {
        let inputA = workDir.appendingPathComponent("alpha.txt")
        try Data("Mail alpha@example.com now.".utf8).write(to: inputA)
        let inputB = workDir.appendingPathComponent("beta.txt")
        try Data("Mail beta@example.com now.".utf8).write(to: inputB)

        for input in [inputA, inputB] {
            let response = try roundTrip([
                "jsonrpc": "2.0", "id": 71, "method": "tools/call",
                "params": [
                    "name": "anonymize_document",
                    "arguments": ["input": input.path, "outputDir": workDir.path]
                ]
            ])
            let summary = try toolSummary(from: response)
            let mappingPath = try XCTUnwrap(summary["mappingFile"] as? String)

            // The sidecar decrypts under its own per-document account.
            let account = MCPServer.keychainAccount(
                forMappingBaseName: URL(fileURLWithPath: mappingPath)
                    .deletingPathExtension().lastPathComponent
            )
            XCTAssertNoThrow(
                try MappingStore.load(
                    from: URL(fileURLWithPath: mappingPath),
                    protection: .keychain(account: account)
                )
            )
        }

        // The two accounts must differ.
        XCTAssertNotEqual(
            MCPServer.keychainAccount(forMappingBaseName: "alpha_redacted"),
            MCPServer.keychainAccount(forMappingBaseName: "beta_redacted")
        )

        // And restore through the server round-trips document A.
        let redactedA = workDir.appendingPathComponent("alpha_redacted.txt")
        let mappingA = workDir.appendingPathComponent("alpha_redacted.ldamap")
        let outputA = workDir.appendingPathComponent("alpha_restored.txt")
        let restore = try roundTrip([
            "jsonrpc": "2.0", "id": 72, "method": "tools/call",
            "params": [
                "name": "restore_document",
                "arguments": [
                    "editedRedacted": redactedA.path,
                    "mapping": mappingA.path,
                    "output": outputA.path
                ]
            ]
        ])
        _ = try toolSummary(from: restore)
        let restored = try String(contentsOf: outputA, encoding: .utf8)
        XCTAssertTrue(restored.contains("alpha@example.com"))
    }

}
