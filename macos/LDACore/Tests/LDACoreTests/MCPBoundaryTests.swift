//
//  MCPBoundaryTests.swift
//  LDACoreTests
//
//  The context boundary itself, tested on the wire: every byte the MCP server
//  returns enters the model context of the agent host and leaves the machine,
//  so these tests drive full round trips and grep the RAW RESPONSE BYTES for
//  everything that must never cross:
//
//   - the original filename (legal files are named after the parties),
//   - any staged or vault path component (paths are PII too),
//   - every planted PII value,
//   - "/Users/" as a catch-all for any home-directory path leak.
//
//  Also here: the attest counters (plaintext bytes stay zero across the whole
//  trip; redacted bytes grow only on read_redacted) and the session tool's
//  shared-mapping guarantee, verified through handles only.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDAMCP
@testable import LDACore

final class MCPBoundaryTests: XCTestCase {

    private var workDir: URL!
    private var vaultDir: URL!
    private var server: MCPServer!
    /// Raw wire bytes of every response this test produced, in order.
    private var wireLog: [Data] = []

    private let passphrase = "boundary-test-passphrase"

    override func setUpWithError() throws {
        try super.setUpWithError()
        assertNoTestSeamsInstalled()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPBoundaryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        vaultDir = workDir.appendingPathComponent("vault", isDirectory: true)
        server = MCPServer(environment: [DocumentVault.environmentKey: vaultDir.path])
        wireLog = []
    }

    override func tearDownWithError() throws {
        if let workDir, FileManager.default.fileExists(atPath: workDir.path) {
            try? FileManager.default.removeItem(at: workDir)
        }
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    /// Send one tools/call, LOGGING the raw response bytes, and return the
    /// decoded (isError, text).
    @discardableResult
    private func call(tool: String, arguments: [String: Any]) throws -> (isError: Bool, text: String) {
        let request: [String: Any] = [
            "jsonrpc": "2.0", "id": wireLog.count + 1, "method": "tools/call",
            "params": ["name": tool, "arguments": arguments]
        ]
        let payload = try JSONSerialization.data(withJSONObject: request)
        let responseData = try XCTUnwrap(server.handle(payload))
        wireLog.append(responseData)
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

    private func summary(of response: (isError: Bool, text: String)) throws -> [String: Any] {
        XCTAssertFalse(response.isError, response.text)
        let object = try JSONSerialization.jsonObject(with: Data(response.text.utf8))
        return try XCTUnwrap(object as? [String: Any])
    }

    /// The whole conversation so far, as text, for boundary grepping.
    private func wireText() -> String {
        wireLog.map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n")
    }

    /// Assert that none of the forbidden substrings ever crossed the wire.
    private func assertWireNeverContained(_ forbidden: [String]) {
        let text = wireText()
        for value in forbidden {
            XCTAssertFalse(
                text.contains(value),
                "the wire carried forbidden content: \(value)"
            )
        }
    }

    @discardableResult
    private func stage(named name: String, contents: String) throws -> (handle: String, sourceURL: URL) {
        let url = workDir.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        let entry = try DocumentVault(rootDirectory: vaultDir)
            .stage(fileURL: url, stagedAtISO8601: "2026-08-30T00:00:00Z")
        return (entry.handle, url)
    }

    // MARK: - The round-trip boundary regression

    func testFullRoundTripNeverLeaksNamesPathsOrPlantedValues() throws {
        // Plant distinctive values and a party-identifying filename.
        let email = "zhang.san.6741@example.com"
        let phone = "(212) 555-0188"
        let account = "6225880100000000123"
        let fileBase = "ZhangSan-v-LiSi-divorce-agreement"
        let contents = """
        Contact \(email) or call \(phone).
        Wire the retainer to account \(account) by 2024-03-01.
        """
        let staged = try stage(named: "\(fileBase).txt", contents: contents)

        // Drive the whole surface: list, detect, anonymize, read, restore
        // (with edited text), export, attest.
        let listed = try summary(of: try call(tool: "list_pending", arguments: [:]))
        XCTAssertEqual((listed["documents"] as? [[String: Any]])?.count, 1)

        try call(tool: "detect_entities", arguments: ["handle": staged.handle])

        let anonymized = try summary(of: try call(tool: "anonymize", arguments: [
            "handle": staged.handle, "passphrase": passphrase
        ]))
        let redactedHandle = try XCTUnwrap(anonymized["redactedHandle"] as? String)

        let read = try summary(of: try call(tool: "read_redacted", arguments: [
            "handle": redactedHandle
        ]))
        let redactedText = try XCTUnwrap(read["text"] as? String)
        XCTAssertFalse(redactedText.contains(email))

        let edited = redactedText.replacingOccurrences(of: "retainer", with: "settlement")
        let restored = try summary(of: try call(tool: "restore", arguments: [
            "redactedHandle": redactedHandle,
            "editedText": edited,
            "passphrase": passphrase
        ]))
        let restoredHandle = try XCTUnwrap(restored["restoredHandle"] as? String)

        try call(tool: "export", arguments: ["handle": restoredHandle])
        try call(tool: "attest", arguments: [:])

        // A few failing calls too: error strings are part of the wire.
        try call(tool: "read_redacted", arguments: ["handle": staged.handle])
        try call(tool: "anonymize", arguments: ["handle": "doc_000000000000"])

        // The boundary: nothing party-identifying ever crossed.
        assertWireNeverContained([
            fileBase,
            staged.sourceURL.path,
            staged.sourceURL.lastPathComponent,
            vaultDir.path,
            workDir.path,
            "/Users/",
            email,
            phone,
            account
        ])

        // The restored bytes ARE back in the vault (with the edit applied),
        // proving the round trip worked without the wire carrying the values.
        let restoredText = String(
            decoding: try DocumentVault(rootDirectory: vaultDir)
                .readDocumentBytes(handle: restoredHandle),
            as: UTF8.self
        )
        XCTAssertTrue(restoredText.contains(email))
        XCTAssertTrue(restoredText.contains(account))
        XCTAssertTrue(restoredText.contains("settlement"))
    }

    /// Leak channel 5 (error hygiene): failing calls must not echo filesystem
    /// paths either, including the model-path policy refusal.
    func testFailingCallsCarryNoPathBytes() throws {
        let staged = try stage(named: "matter.txt", contents: "Mail jane@example.com now.")
        let plantedModel = "/Library/Caches/planted.gguf"

        let unknown = try call(tool: "read_redacted", arguments: ["handle": "red_ffffffffffff"])
        XCTAssertTrue(unknown.isError)

        let wrongKind = try call(tool: "restore", arguments: ["redactedHandle": staged.handle])
        XCTAssertTrue(wrongKind.isError)

        let badModel = try call(tool: "detect_entities", arguments: [
            "handle": staged.handle, "modelPath": plantedModel
        ])
        XCTAssertTrue(badModel.isError)
        XCTAssertTrue(
            badModel.text.contains("allowed directories for GGUF models"),
            "the refusal names the policy, got: \(badModel.text)"
        )
        XCTAssertTrue(badModel.text.contains("modelPath"), badModel.text)

        let missingHandle = try call(tool: "anonymize", arguments: [:])
        XCTAssertTrue(missingHandle.isError)

        let exportOriginal = try call(tool: "export", arguments: ["handle": staged.handle])
        XCTAssertTrue(exportOriginal.isError)

        assertWireNeverContained([
            "/Users/",
            vaultDir.path,
            workDir.path,
            plantedModel,
            "/Library/Caches"
        ])
    }

    // MARK: - Attest counters

    func testAttestCountersStayHonestAcrossTheRoundTrip() throws {
        // Pin the headless default so the keyACLMode assertion cannot be
        // perturbed by a policy another suite toggled.
        let previousPolicy = KeychainAccessPolicy.requireUserPresence
        KeychainAccessPolicy.requireUserPresence = false
        defer { KeychainAccessPolicy.requireUserPresence = previousPolicy }

        let staged = try stage(named: "matter.txt", contents: "Mail jane@example.com now.")

        // Fresh server: everything zero.
        var attest = try summary(of: try call(tool: "attest", arguments: [:]))
        XCTAssertEqual(attest["vaultEncryptionAtRest"] as? Bool, false, "phase 5 has not shipped; attest must say so")
        XCTAssertEqual(attest["keyACLMode"] as? String, "silent")
        XCTAssertEqual(attest["plaintextBytesReturnedThisSession"] as? Int, 0)
        XCTAssertEqual(attest["redactedBytesReturnedThisSession"] as? Int, 0)

        // Anonymize and restore do not move either byte counter.
        let anonymized = try summary(of: try call(tool: "anonymize", arguments: [
            "handle": staged.handle, "passphrase": passphrase
        ]))
        let redactedHandle = try XCTUnwrap(anonymized["redactedHandle"] as? String)
        try call(tool: "restore", arguments: [
            "redactedHandle": redactedHandle, "passphrase": passphrase
        ])

        attest = try summary(of: try call(tool: "attest", arguments: [:]))
        XCTAssertEqual(attest["plaintextBytesReturnedThisSession"] as? Int, 0)
        XCTAssertEqual(attest["redactedBytesReturnedThisSession"] as? Int, 0)

        // read_redacted is the ONLY mover, and only of the redacted counter.
        let read = try summary(of: try call(tool: "read_redacted", arguments: [
            "handle": redactedHandle
        ]))
        let text = try XCTUnwrap(read["text"] as? String)

        attest = try summary(of: try call(tool: "attest", arguments: [:]))
        XCTAssertEqual(attest["plaintextBytesReturnedThisSession"] as? Int, 0)
        XCTAssertEqual(
            attest["redactedBytesReturnedThisSession"] as? Int,
            Data(text.utf8).count
        )

        // Tool call counts name only real tools, including attest itself.
        let counts = try XCTUnwrap(attest["toolCallCounts"] as? [String: Int])
        XCTAssertEqual(counts["anonymize"], 1)
        XCTAssertEqual(counts["restore"], 1)
        XCTAssertEqual(counts["read_redacted"], 1)
        XCTAssertEqual(counts["attest"], 3)
        for name in counts.keys {
            XCTAssertTrue(
                MCPServer.vaultToolNames.contains(name)
                    || MCPServer.legacyGatedToolNames.contains(name),
                "attest echoed an unknown tool name: \(name)"
            )
        }
    }

    // MARK: - Session sharing through handles

    func testAnonymizeSessionSharesPlaceholdersAndRestoresThroughAnyMember() throws {
        let email = "shared.party@example.com"
        let first = try stage(
            named: "complaint.txt",
            contents: "Filed by \(email) on 2024-01-15."
        )
        let second = try stage(
            named: "annex.txt",
            contents: "Reply to \(email) with the annex."
        )

        let session = try summary(of: try call(tool: "anonymize_session", arguments: [
            "handles": [first.handle, second.handle],
            "passphrase": passphrase
        ]))
        let documents = try XCTUnwrap(session["documents"] as? [[String: Any]])
        XCTAssertEqual(documents.count, 2)
        let redactedFirst = try XCTUnwrap(documents[0]["redactedHandle"] as? String)
        let redactedSecond = try XCTUnwrap(documents[1]["redactedHandle"] as? String)
        XCTAssertNotEqual(redactedFirst, redactedSecond)

        // The same value carries the same placeholder in both artifacts.
        let firstText = try XCTUnwrap(
            try summary(of: try call(tool: "read_redacted", arguments: [
                "handle": redactedFirst
            ]))["text"] as? String
        )
        let secondText = try XCTUnwrap(
            try summary(of: try call(tool: "read_redacted", arguments: [
                "handle": redactedSecond
            ]))["text"] as? String
        )
        XCTAssertTrue(firstText.contains("{EMAIL_1}"), firstText)
        XCTAssertTrue(secondText.contains("{EMAIL_1}"), secondText)
        XCTAssertFalse(firstText.contains(email))
        XCTAssertFalse(secondText.contains(email))

        // Restoring through the SECOND member's handle uses the shared sidecar.
        let restored = try summary(of: try call(tool: "restore", arguments: [
            "redactedHandle": redactedSecond,
            "editedText": secondText,
            "passphrase": passphrase
        ]))
        let restoredHandle = try XCTUnwrap(restored["restoredHandle"] as? String)
        let restoredText = String(
            decoding: try DocumentVault(rootDirectory: vaultDir)
                .readDocumentBytes(handle: restoredHandle),
            as: UTF8.self
        )
        XCTAssertTrue(restoredText.contains(email))

        // And the wire never carried the shared value or any path.
        assertWireNeverContained([email, vaultDir.path, "/Users/"])
    }
}
