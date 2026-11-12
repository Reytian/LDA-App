//
//  MCPConfiguredModelTests.swift
//  LDACoreTests
//
//  Review 2026-11-11, F3. Over MCP the assistant decided whether a model ran:
//  anonymize, anonymize_session and detect_entities took modelPath from the
//  request only, so a request without it ran patterns only, the artifact was
//  stored with excludedEntityCount 0, and read_redacted returned its body
//  (names, companies and addresses in clear) with localApproval false. Only
//  prepare_documents read the model the server was launched with.
//
//  Now a request without modelPath uses the launch-configured LDA_MODEL_PATH,
//  the vault entry records how the artifact was detected, and an artifact
//  made without a model while one is configured needs the local approval step
//  before read_redacted returns it.
//
//  The model load is the test seam (LDAService.makeExtractorForTesting), so
//  no model file is needed; the seam records which path it was asked for.
//  Hermetic temp-rooted vaults, passphrase-protected sidecars: nothing here
//  touches the Keychain.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDAMCP
@testable import LDACore

final class MCPConfiguredModelTests: XCTestCase {

    private static let body = "Jordan Ellis signed for Northwind Traders. Write to jordan.ellis@example.com."
    private static let entities = #"""
    {"entities":[{"value":"Jordan Ellis","type":"PERSON"},{"value":"Northwind Traders","type":"COMPANY"}],"redacted_text":""}
    """#

    private struct FixedCompleter: TextCompleter {
        let output: String
        func complete(prompt: String, maxTokens: Int?, stop: [String]) throws -> String { output }
    }

    /// The paths the seam was asked to load, in order.
    private final class LoadLog: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String] = []
        func record(_ path: String) { lock.withLock { paths.append(path) } }
        var all: [String] { lock.withLock { paths } }
    }

    private var workDir: URL!
    private var vaultDir: URL!
    private var loads: LoadLog!

    override func setUpWithError() throws {
        try super.setUpWithError()
        assertNoTestSeamsInstalled()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPConfiguredModelTests-\(UUID().uuidString)", isDirectory: true)
        vaultDir = workDir.appendingPathComponent("vault", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let log = LoadLog()
        loads = log
        // A path means the model was asked for; the empty path is the
        // pattern-only run, which loads nothing.
        LDAService.makeExtractorForTesting = { path in
            guard !path.isEmpty else { return nil }
            log.record(path)
            return LLMExtractor(completer: FixedCompleter(output: Self.entities))
        }
    }

    override func tearDownWithError() throws {
        LDAService.makeExtractorForTesting = nil
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
        try super.tearDownWithError()
    }

    private var configuredModel: String { workDir.appendingPathComponent("configured-model.gguf").path }

    private func server(configured: Bool, approve: @escaping (String, Int) -> Bool = { _, _ in false }) -> MCPServer {
        var extra: [String: String] = [:]
        if configured { extra["LDA_MODEL_PATH"] = configuredModel }
        return MCPServer(
            environment: VaultTestSupport.serverEnvironment(vaultDir: vaultDir, extra: extra),
            approvePartialDisclosure: approve
        )
    }

    private var vault: DocumentVault { VaultTestSupport.vault(root: vaultDir) }

    private func stage() throws -> String {
        let url = workDir.appendingPathComponent("matter-\(UUID().uuidString).txt")
        try Data(Self.body.utf8).write(to: url)
        return try vault.stage(fileURL: url, stagedAtISO8601: "2026-11-11T00:00:00Z").handle
    }

    private func call(_ server: MCPServer, _ tool: String, _ arguments: [String: Any]) throws -> (isError: Bool, text: String, json: [String: Any]) {
        let payload = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": tool, "arguments": arguments]
        ])
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(server.handle(payload))) as? [String: Any])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let text = try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
        return ((result["isError"] as? Bool) ?? false, text, json)
    }

    // MARK: - The configured model runs when the request names none

    func testAnonymizeWithoutModelPathUsesTheConfiguredModel() throws {
        let server = server(configured: true)
        let response = try call(server, "anonymize", ["handle": try stage(), "passphrase": "configured-model"])
        XCTAssertFalse(response.isError, response.text)
        XCTAssertEqual(loads.all, [configuredModel], "the launch-configured model must run")
        XCTAssertEqual(response.json["detectionMode"] as? String, "local_model")
        let perType = response.json["perTypeCounts"] as? [String: Int] ?? [:]
        XCTAssertEqual(perType["PERSON"], 1, response.text)

        let redacted = try XCTUnwrap(response.json["redactedHandle"] as? String)
        XCTAssertEqual(try vault.entry(handle: redacted).detection, "local_model")
        let read = try call(server, "read_redacted", ["handle": redacted])
        XCTAssertFalse(read.isError, read.text)
        let text = try XCTUnwrap(read.json["text"] as? String)
        XCTAssertFalse(text.contains("Jordan"), text)
        XCTAssertFalse(text.contains("Northwind"), text)
        XCTAssertEqual(read.json["localApproval"] as? Bool, false, "a model-detected, fully redacted artifact needs no approval")
    }

    func testDetectEntitiesWithoutModelPathUsesTheConfiguredModel() throws {
        let response = try call(server(configured: true), "detect_entities", ["handle": try stage()])
        XCTAssertFalse(response.isError, response.text)
        XCTAssertEqual(loads.all, [configuredModel])
        XCTAssertEqual(response.json["detectionMode"] as? String, "local_model")
        let types = (response.json["entities"] as? [[String: Any]] ?? []).compactMap { $0["type"] as? String }
        XCTAssertTrue(types.contains("PERSON"), response.text)
    }

    func testAnonymizeSessionWithoutModelPathUsesTheConfiguredModel() throws {
        let server = server(configured: true)
        let response = try call(server, "anonymize_session", [
            "handles": [try stage(), try stage()], "passphrase": "configured-model"
        ])
        XCTAssertFalse(response.isError, response.text)
        XCTAssertEqual(loads.all, [configuredModel], "one load for the whole session")
        XCTAssertEqual(response.json["detectionMode"] as? String, "local_model")
        let documents = response.json["documents"] as? [[String: Any]] ?? []
        XCTAssertEqual(documents.count, 2)
        for document in documents {
            let redacted = try XCTUnwrap(document["redactedHandle"] as? String)
            XCTAssertEqual(try vault.entry(handle: redacted).detection, "local_model")
        }
    }

    func testWithNoConfiguredModelTheRunIsPatternsOnlyAndSaysSo() throws {
        let response = try call(server(configured: false), "anonymize", ["handle": try stage(), "passphrase": "configured-model"])
        XCTAssertFalse(response.isError, response.text)
        XCTAssertTrue(loads.all.isEmpty)
        XCTAssertEqual(response.json["detectionMode"] as? String, "patterns_only")
        let redacted = try XCTUnwrap(response.json["redactedHandle"] as? String)
        XCTAssertEqual(try vault.entry(handle: redacted).detection, "patterns_only")
    }

    // MARK: - read_redacted of an artifact made without the configured model

    func testAPatternsOnlyArtifactNeedsLocalApprovalOnceAModelIsConfigured() throws {
        // Made by a server launched without a model: names were never looked for.
        let made = try call(server(configured: false), "anonymize", ["handle": try stage(), "passphrase": "configured-model"])
        let redacted = try XCTUnwrap(made.json["redactedHandle"] as? String, made.text)

        var shownCounts: [Int] = []
        let refusing = server(configured: true) { _, count in shownCounts.append(count); return false }
        let refused = try call(refusing, "read_redacted", ["handle": redacted])
        XCTAssertTrue(refused.isError, refused.text)
        XCTAssertTrue(refused.text.contains("local_approval_required"), refused.text)
        XCTAssertFalse(refused.text.contains("Jordan Ellis"))
        XCTAssertEqual(shownCounts, [MCPLocalApproval.detectedWithoutModel])

        let approving = server(configured: true) { _, _ in true }
        let approved = try call(approving, "read_redacted", ["handle": redacted])
        XCTAssertFalse(approved.isError, approved.text)
        XCTAssertEqual(approved.json["localApproval"] as? Bool, true)
    }

    func testWithoutAConfiguredModelAPatternsOnlyArtifactReadsAsBefore() throws {
        let server = server(configured: false)
        let made = try call(server, "anonymize", ["handle": try stage(), "passphrase": "configured-model"])
        let redacted = try XCTUnwrap(made.json["redactedHandle"] as? String, made.text)
        let read = try call(server, "read_redacted", ["handle": redacted])
        XCTAssertFalse(read.isError, read.text)
        XCTAssertEqual(read.json["localApproval"] as? Bool, false)
    }

    func testListPendingSaysHowEachArtifactWasDetected() throws {
        let server = server(configured: true)
        let made = try call(server, "anonymize", ["handle": try stage(), "passphrase": "configured-model"])
        let redacted = try XCTUnwrap(made.json["redactedHandle"] as? String, made.text)
        let listed = try call(server, "list_pending", [:])
        let item = try XCTUnwrap((listed.json["documents"] as? [[String: Any]])?.first { ($0["handle"] as? String) == redacted })
        XCTAssertEqual(item["detectionMode"] as? String, "local_model")
    }

    func testOldEntriesWithoutTheFieldStillDecode() throws {
        let old = #"{"handle":"red_0","kind":"redacted","format":"txt","byteCount":1,"stagedAtISO8601":"2026-01-01T00:00:00Z","relativePath":"a/b"}"#
        let entry = try JSONDecoder().decode(VaultEntry.self, from: Data(old.utf8))
        XCTAssertNil(entry.detection)
    }
}
