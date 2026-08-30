//
//  MCPVaultToolTests.swift
//  LDACoreTests
//
//  The handle-first MCP tool surface: list_pending, anonymize,
//  anonymize_session, read_redacted, detect_entities, restore, export, attest.
//  Tools accept and return opaque vault handles; the boundary tests proper
//  (wire-byte hygiene across a full round trip) live in MCPBoundaryTests.
//
//  Every server instance is pointed at a per-test vault via LDA_VAULT_DIR in
//  its injected environment, so no test touches the real Application Support
//  vault. The vault itself is encrypted at rest; VaultTestSupport injects one
//  shared passphrase (initializer parameter for direct vault access,
//  LDA_VAULT_PASSPHRASE for servers) so the vault master key never touches
//  the Keychain. Anonymize calls use passphrase protection for the mapping
//  sidecars too (except the one test that is ABOUT per-document Keychain
//  accounts, which cleans up its own unique accounts).
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDAMCP
@testable import LDACore

final class MCPVaultToolTests: XCTestCase {

    private var workDir: URL!
    private var vaultDir: URL!
    private var server: MCPServer!
    private var createdAccounts: [String] = []

    private let passphrase = "correct horse battery staple"

    override func setUpWithError() throws {
        try super.setUpWithError()
        assertNoTestSeamsInstalled()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPVaultToolTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        vaultDir = workDir.appendingPathComponent("vault", isDirectory: true)
        server = MCPServer(environment: VaultTestSupport.serverEnvironment(vaultDir: vaultDir))
        createdAccounts = []
    }

    override func tearDownWithError() throws {
        // Delete only the per-test keys this suite created; their accounts
        // derive from random handles, so nothing shared is ever touched.
        for account in createdAccounts {
            try? MappingStore.deleteKeychainKey(account: account)
        }
        if let workDir, FileManager.default.fileExists(atPath: workDir.path) {
            try? FileManager.default.removeItem(at: workDir)
        }
        try super.tearDownWithError()
    }

    // MARK: - JSON helpers

    private func encode(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    private func decode(_ data: Data) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dict = object as? [String: Any] else {
            throw XCTSkip("Response was not a JSON object")
        }
        return dict
    }

    @discardableResult
    private func roundTrip(_ request: [String: Any], via server: MCPServer? = nil) throws -> [String: Any] {
        let requestData = try encode(request)
        guard let responseData = (server ?? self.server).handle(requestData) else {
            XCTFail("Expected a response for request \(request)")
            return [:]
        }
        return try decode(responseData)
    }

    /// tools/call helper returning (isError, summary-or-message-text).
    private func call(
        tool: String,
        arguments: [String: Any],
        via server: MCPServer? = nil
    ) throws -> (isError: Bool, text: String) {
        let response = try roundTrip([
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": tool, "arguments": arguments]
        ], via: server)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        return (
            isError: (result["isError"] as? Bool) ?? false,
            text: (content.first?["text"] as? String) ?? ""
        )
    }

    /// tools/call helper that asserts success and parses the JSON summary.
    private func callSummary(
        tool: String,
        arguments: [String: Any],
        via server: MCPServer? = nil
    ) throws -> [String: Any] {
        let response = try call(tool: tool, arguments: arguments, via: server)
        XCTAssertFalse(response.isError, "\(tool) failed: \(response.text)")
        let object = try JSONSerialization.jsonObject(with: Data(response.text.utf8))
        return try XCTUnwrap(object as? [String: Any])
    }

    // MARK: - Fixtures

    /// Stage a text document straight through the vault (the human intake
    /// path) and return its handle.
    @discardableResult
    private func stageText(
        _ contents: String,
        named name: String = "matter.txt"
    ) throws -> String {
        let url = workDir.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        let entry = try VaultTestSupport.vault(root: vaultDir)
            .stage(fileURL: url, stagedAtISO8601: "2026-08-30T00:00:00Z")
        return entry.handle
    }

    // MARK: - tools/list

    func testToolsListAdvertisesOnlyTheHandleSurfaceByDefault() throws {
        let response = try roundTrip(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
        let names = tools.compactMap { $0["name"] as? String }

        XCTAssertEqual(names, MCPServer.vaultToolNames, "the default surface is exactly the handle-first tools")
        for legacy in MCPServer.legacyGatedToolNames.union(MCPServer.removedToolNames) {
            XCTAssertFalse(names.contains(legacy), "\(legacy) must not be advertised by default")
        }

        // Every advertised tool has an object schema whose required fields are
        // described in properties.
        for tool in tools {
            let schema = try XCTUnwrap(tool["inputSchema"] as? [String: Any])
            XCTAssertEqual(schema["type"] as? String, "object")
            let required = (schema["required"] as? [String]) ?? []
            let properties = (schema["properties"] as? [String: Any]) ?? [:]
            for field in required {
                XCTAssertNotNil(properties[field], "\(tool["name"] ?? "?") missing property \(field)")
            }
        }
    }

    func testToolsListIncludesLegacyToolsOnlyWhenTheGateIsOpen() throws {
        let gated = MCPServer(environment: VaultTestSupport.serverEnvironment(
            vaultDir: vaultDir,
            extra: [MCPServer.legacyPathToolsEnvironmentKey: "1"]
        ))
        let response = try roundTrip(
            ["jsonrpc": "2.0", "id": 3, "method": "tools/list"],
            via: gated
        )
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
        let names = Set(tools.compactMap { $0["name"] as? String })

        XCTAssertTrue(MCPServer.legacyGatedToolNames.isSubset(of: names))
        XCTAssertTrue(names.isSuperset(of: MCPServer.vaultToolNames))
        for removed in MCPServer.removedToolNames {
            XCTAssertFalse(names.contains(removed), "\(removed) is gone even with the gate open")
        }
    }

    // MARK: - list_pending

    func testListPendingReturnsHandlesAndNeutralMetadataOnly() throws {
        let handle = try stageText(
            "Mail jane@example.com now.",
            named: "ZhangSan-v-LiSi-divorce.txt"
        )

        let summary = try callSummary(tool: "list_pending", arguments: [:])
        let documents = try XCTUnwrap(summary["documents"] as? [[String: Any]])
        XCTAssertEqual(documents.count, 1)
        let item = try XCTUnwrap(documents.first)

        XCTAssertEqual(item["handle"] as? String, handle)
        XCTAssertEqual(item["kind"] as? String, "original")
        XCTAssertEqual(item["format"] as? String, "txt")
        XCTAssertEqual(item["stagedAt"] as? String, "2026-08-30T00:00:00Z")
        XCTAssertNotNil(item["byteCount"])
        XCTAssertNil(item["originalFilename"], "list_pending must not return filenames")
        XCTAssertNil(item["relativePath"], "list_pending must not return paths")
    }

    // MARK: - anonymize

    func testAnonymizeReturnsARedactedHandleAndAggregateCountsOnly() throws {
        let handle = try stageText("""
        Contact jane.doe@example.com or call (212) 555-0147.
        Signed on 2024-01-15 for an amount of USD 1,250,000.
        """)

        let summary = try callSummary(tool: "anonymize", arguments: [
            "handle": handle,
            "passphrase": passphrase
        ])

        let redactedHandle = try XCTUnwrap(summary["redactedHandle"] as? String)
        XCTAssertTrue(
            redactedHandle.range(of: "^red_[0-9a-f]{12,}$", options: .regularExpression) != nil,
            "got \(redactedHandle)"
        )
        let entityCount = try XCTUnwrap(summary["entityCount"] as? Int)
        XCTAssertGreaterThanOrEqual(entityCount, 3)

        let types = Set(try XCTUnwrap(summary["entityTypes"] as? [String]))
        XCTAssertTrue(types.contains("EMAIL"))

        let perType = try XCTUnwrap(summary["perTypeCounts"] as? [String: Int])
        XCTAssertEqual(perType.values.reduce(0, +), entityCount)
        XCTAssertEqual(perType["EMAIL"], 1)

        XCTAssertNotNil(summary["imageRedactionCount"])
        XCTAssertNotNil(summary["unboxedTokenCount"])

        // No path-shaped keys of the old response survive.
        XCTAssertNil(summary["redactedFile"])
        XCTAssertNil(summary["mappingFile"])
        XCTAssertNil(summary["visualPdf"])

        // The redacted artifact and its sidecar are both inside the vault.
        let redactedEntry = try VaultTestSupport.vault(root: vaultDir).entry(handle: redactedHandle)
        XCTAssertEqual(redactedEntry.kind, .redacted)
        XCTAssertEqual(redactedEntry.sourceHandle, handle)
        XCTAssertNotNil(redactedEntry.mappingRelativePath)
    }

    func testAnonymizeRefusesANonOriginalHandle() throws {
        let handle = try stageText("Mail jane@example.com now.")
        let summary = try callSummary(tool: "anonymize", arguments: [
            "handle": handle, "passphrase": passphrase
        ])
        let redactedHandle = try XCTUnwrap(summary["redactedHandle"] as? String)

        let second = try call(tool: "anonymize", arguments: [
            "handle": redactedHandle, "passphrase": passphrase
        ])
        XCTAssertTrue(second.isError)
        XCTAssertTrue(second.text.contains("not_an_original"), second.text)
        XCTAssertTrue(second.text.contains(redactedHandle), "the message names the handle")
    }

    func testAnonymizeOnAnUnknownHandleNamesTheHandleOnly() throws {
        let response = try call(tool: "anonymize", arguments: [
            "handle": "doc_000000000000", "passphrase": passphrase
        ])
        XCTAssertTrue(response.isError)
        XCTAssertTrue(response.text.contains("unknown_handle"), response.text)
        XCTAssertTrue(response.text.contains("doc_000000000000"))
    }

    // MARK: - read_redacted

    func testReadRedactedReturnsTokenizedTextForRedactedArtifactsOnly() throws {
        let original = "Mail jane@example.com about the retainer."
        let handle = try stageText(original)
        let summary = try callSummary(tool: "anonymize", arguments: [
            "handle": handle, "passphrase": passphrase
        ])
        let redactedHandle = try XCTUnwrap(summary["redactedHandle"] as? String)

        // The redacted text comes back, tokenized.
        let read = try callSummary(tool: "read_redacted", arguments: ["handle": redactedHandle])
        let text = try XCTUnwrap(read["text"] as? String)
        XCTAssertTrue(text.contains("{EMAIL_1}"), "expected a token, got: \(text)")
        XCTAssertFalse(text.contains("jane@example.com"), "the PII value must be gone")

        // An original is refused.
        let onOriginal = try call(tool: "read_redacted", arguments: ["handle": handle])
        XCTAssertTrue(onOriginal.isError)
        XCTAssertTrue(onOriginal.text.contains("not_redacted"), onOriginal.text)

        // A restored artifact is refused too: it holds real PII again.
        let restored = try callSummary(tool: "restore", arguments: [
            "redactedHandle": redactedHandle, "passphrase": passphrase
        ])
        let restoredHandle = try XCTUnwrap(restored["restoredHandle"] as? String)
        let onRestored = try call(tool: "read_redacted", arguments: ["handle": restoredHandle])
        XCTAssertTrue(onRestored.isError)
        XCTAssertTrue(onRestored.text.contains("not_redacted"), onRestored.text)
    }

    // MARK: - detect_entities

    /// The context boundary regression, adapted to handles: the response
    /// carries types and offsets ONLY, never the detected surface text.
    func testDetectEntitiesNeverReturnsSurfaceText() throws {
        let email = "jane.doe@example.com"
        let phone = "(212) 555-0147"
        let account = "6225880100000000123"
        let handle = try stageText("""
        Contact \(email) or call \(phone).
        Wire the retainer to account \(account) by 2024-03-01.
        """)

        let response = try roundTrip([
            "jsonrpc": "2.0", "id": 4, "method": "tools/call",
            "params": ["name": "detect_entities", "arguments": ["handle": handle]]
        ])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false, "\(result)")
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        let summary = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        )

        let entities = try XCTUnwrap(summary["entities"] as? [[String: Any]])
        XCTAssertFalse(entities.isEmpty, "fixture should produce detections")
        for entity in entities {
            XCTAssertNil(entity["text"], "entity payload must not carry surface text: \(entity)")
            XCTAssertNotNil(entity["type"])
            XCTAssertNotNil(entity["start"])
            XCTAssertNotNil(entity["end"])
        }

        // Belt and braces: the raw wire bytes must not contain any detected value.
        let wire = try encode(response)
        let wireText = try XCTUnwrap(String(data: wire, encoding: .utf8))
        for value in [email, phone, account] {
            XCTAssertFalse(wireText.contains(value), "wire bytes leaked \(value)")
        }
    }

    // MARK: - restore

    func testRestoreWithEditedTextKeepsTheRestoredArtifactInTheVault() throws {
        let email = "jane@example.com"
        let handle = try stageText("Mail \(email) about the retainer.")
        let summary = try callSummary(tool: "anonymize", arguments: [
            "handle": handle, "passphrase": passphrase
        ])
        let redactedHandle = try XCTUnwrap(summary["redactedHandle"] as? String)
        let read = try callSummary(tool: "read_redacted", arguments: ["handle": redactedHandle])
        let redactedText = try XCTUnwrap(read["text"] as? String)

        // Simulate the AI editing around the token.
        let edited = redactedText.replacingOccurrences(of: "retainer", with: "invoice")
        let restored = try callSummary(tool: "restore", arguments: [
            "redactedHandle": redactedHandle,
            "editedText": edited,
            "passphrase": passphrase
        ])

        let restoredHandle = try XCTUnwrap(restored["restoredHandle"] as? String)
        XCTAssertTrue(restoredHandle.hasPrefix("res_"), restoredHandle)
        XCTAssertEqual(restored["restoredCount"] as? Int, 1)
        XCTAssertEqual((restored["orphanTokens"] as? [String])?.isEmpty, true)

        // The edited text was persisted as its own redacted artifact.
        let editedHandle = try XCTUnwrap(restored["editedRedactedHandle"] as? String)
        XCTAssertTrue(editedHandle.hasPrefix("red_"))

        // The restored PII lives in the vault, not in the response.
        XCTAssertNil(restored["text"])
        let vault = VaultTestSupport.vault(root: vaultDir)
        let restoredBytes = try vault.readDocumentBytes(handle: restoredHandle)
        let restoredText = String(decoding: restoredBytes, as: UTF8.self)
        XCTAssertTrue(restoredText.contains(email))
        XCTAssertTrue(restoredText.contains("invoice"))
    }

    func testRestoreWithoutEditedTextRestoresTheStoredArtifact() throws {
        let handle = try stageText("Mail jane@example.com now.")
        let summary = try callSummary(tool: "anonymize", arguments: [
            "handle": handle, "passphrase": passphrase
        ])
        let redactedHandle = try XCTUnwrap(summary["redactedHandle"] as? String)

        let restored = try callSummary(tool: "restore", arguments: [
            "redactedHandle": redactedHandle, "passphrase": passphrase
        ])
        let restoredHandle = try XCTUnwrap(restored["restoredHandle"] as? String)

        let bytes = try VaultTestSupport.vault(root: vaultDir)
            .readDocumentBytes(handle: restoredHandle)
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), "Mail jane@example.com now.")
    }

    func testRestoreRefusesANonRedactedHandle() throws {
        let handle = try stageText("Mail jane@example.com now.")
        let response = try call(tool: "restore", arguments: [
            "redactedHandle": handle, "passphrase": passphrase
        ])
        XCTAssertTrue(response.isError)
        XCTAssertTrue(response.text.contains("not_redacted"), response.text)
    }

    // MARK: - export

    func testExportCopiesRedactedArtifactsToTheOutboxAndReturnsNoPath() throws {
        let handle = try stageText("Mail jane@example.com now.", named: "client-matter.txt")
        let summary = try callSummary(tool: "anonymize", arguments: [
            "handle": handle, "passphrase": passphrase
        ])
        let redactedHandle = try XCTUnwrap(summary["redactedHandle"] as? String)

        let exported = try callSummary(tool: "export", arguments: ["handle": redactedHandle])
        XCTAssertEqual(exported["ok"] as? Bool, true)
        XCTAssertEqual(exported.count, 1, "the export response carries ok and nothing else")

        let outbox = VaultTestSupport.vault(root: vaultDir).outboxDirectory
        let names = try FileManager.default.contentsOfDirectory(atPath: outbox.path)
        XCTAssertEqual(names, ["client-matter_redacted.txt"])
    }

    func testExportRefusesAnOriginal() throws {
        let handle = try stageText("Mail jane@example.com now.")
        let response = try call(tool: "export", arguments: ["handle": handle])
        XCTAssertTrue(response.isError)
        XCTAssertTrue(response.text.contains("not_exportable"), response.text)
    }

    // MARK: - Legacy gating

    func testLegacyToolsAreRefusedByDefaultWithTheDocumentedMessage() throws {
        for name in MCPServer.legacyGatedToolNames {
            let response = try call(tool: name, arguments: [:])
            XCTAssertTrue(response.isError, "\(name) must be gated")
            XCTAssertTrue(
                response.text.contains(MCPServer.legacyPathToolsEnvironmentKey),
                "\(name): the refusal must document the opt-in, got: \(response.text)"
            )
            XCTAssertTrue(
                response.text.contains("disabled pending a handle-based redesign"),
                "\(name): got: \(response.text)"
            )
        }
    }

    func testLegacyToolsWorkAsBeforeWithTheGateOpen() throws {
        let gated = MCPServer(environment: VaultTestSupport.serverEnvironment(
            vaultDir: vaultDir,
            extra: [MCPServer.legacyPathToolsEnvironmentKey: "1"]
        ))

        // fill with no arguments now reaches the tool itself, whose own
        // missing-argument error proves the dispatch went through.
        let fill = try call(tool: "fill", arguments: [:], via: gated)
        XCTAssertTrue(fill.isError)
        XCTAssertTrue(
            fill.text.contains("Missing or empty required argument"),
            "expected the fill tool's own validation, got: \(fill.text)"
        )
        XCTAssertFalse(fill.text.contains(MCPServer.legacyPathToolsEnvironmentKey))
    }

    func testRemovedCoreToolsReturnAMigrationMessage() throws {
        for (name, replacement) in [
            ("anonymize_document", "anonymize"),
            ("restore_document", "restore")
        ] {
            let response = try call(tool: name, arguments: [:])
            XCTAssertTrue(response.isError)
            XCTAssertTrue(response.text.contains("was removed"), response.text)
            XCTAssertTrue(response.text.contains("lda vault stage"), response.text)
            XCTAssertTrue(response.text.contains(replacement), response.text)
        }
    }

    // MARK: - Per-document Keychain accounts

    /// Without a passphrase the sidecar key derives from the redacted
    /// artifact's opaque handle: per-document (no shared single point of
    /// failure) and name-free (a Keychain account must not embed a client
    /// name; handles are random hex).
    func testKeychainProtectedMappingsUsePerHandleAccountsAndRestore() throws {
        let handle = try stageText("Mail alpha@example.com now.")
        let summary = try callSummary(tool: "anonymize", arguments: ["handle": handle])
        let redactedHandle = try XCTUnwrap(summary["redactedHandle"] as? String)

        let account = MCPServer.keychainAccount(forMappingBaseName: redactedHandle)
        createdAccounts.append(account)
        XCTAssertTrue(account.contains(redactedHandle))

        // The sidecar decrypts under exactly that account.
        let vault = VaultTestSupport.vault(root: vaultDir)
        let mappingURL = try vault.mappingFileURL(forHandle: redactedHandle)
        XCTAssertNoThrow(
            try MappingStore.load(from: mappingURL, protection: .keychain(account: account))
        )

        // And a passphrase-free restore through the server round-trips.
        let restored = try callSummary(tool: "restore", arguments: [
            "redactedHandle": redactedHandle
        ])
        let restoredHandle = try XCTUnwrap(restored["restoredHandle"] as? String)
        let bytes = try vault.readDocumentBytes(handle: restoredHandle)
        XCTAssertTrue(String(decoding: bytes, as: UTF8.self).contains("alpha@example.com"))
    }

    /// A wrong protection mode (Keychain lookup for a passphrase sidecar) must
    /// surface as its own boundary-safe failure, with no legacy-account retry
    /// masking the cause.
    func testRestoreWithTheWrongProtectionFailsWithoutALegacyRetry() throws {
        let handle = try stageText("Mail jane@example.com now.")
        let summary = try callSummary(tool: "anonymize", arguments: [
            "handle": handle, "passphrase": passphrase
        ])
        let redactedHandle = try XCTUnwrap(summary["redactedHandle"] as? String)

        // No passphrase: the server derives the per-handle Keychain account,
        // which has no key because anonymize used a passphrase.
        let account = MCPServer.keychainAccount(forMappingBaseName: redactedHandle)
        createdAccounts.append(account)
        let response = try call(tool: "restore", arguments: [
            "redactedHandle": redactedHandle
        ])

        XCTAssertTrue(response.isError)
        XCTAssertFalse(response.text.contains("Legacy"), "no legacy retry on the handle surface")
        XCTAssertTrue(
            response.text.contains("keychain_error") || response.text.contains("decryption_failed"),
            "the real cause reaches the caller, got: \(response.text)"
        )
    }
}
