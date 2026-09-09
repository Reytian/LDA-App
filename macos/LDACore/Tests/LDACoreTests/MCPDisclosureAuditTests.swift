import XCTest
@testable import LDACore
@testable import LDAMCP

final class MCPDisclosureAuditTests: XCTestCase {
    private var root: URL!
    private var vault: DocumentVault!
    private var server: MCPServer!
    private let mappingPassword = "synthetic-mapping-password"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        vault = VaultTestSupport.vault(root: root.appendingPathComponent("vault"))
        server = makeServer { _, _ in false }
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }
    private func makeServer(_ approve: @escaping (String, Int) -> Bool) -> MCPServer {
        MCPServer(environment: VaultTestSupport.serverEnvironment(vaultDir: root.appendingPathComponent("vault")),
                  approvePartialDisclosure: approve)
    }
    private func call(_ tool: String, _ arguments: [String: Any] = [:]) throws -> (Bool, String, [String: Any]) {
        let request: [String: Any] = ["jsonrpc": "2.0", "id": "private-request-label", "method": "tools/call", "params": ["name": tool, "arguments": arguments]]
        let response = try XCTUnwrap(server.handle(JSONSerialization.data(withJSONObject: request)))
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: response) as? [String: Any])
        let result = try XCTUnwrap(envelope["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        let body = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
        return (result["isError"] as? Bool == true, text, body)
    }
    private func staged() throws -> String {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("private-client-filename.txt")
        try Data("Contact private@example.com for $24,500.".utf8).write(to: file)
        return try vault.stage(fileURL: file, stagedAtISO8601: "2026-09-08T00:00:00Z").handle
    }
    private func anonymize(_ original: String, partial: Bool) throws -> String {
        var args: [String: Any] = ["handle": original, "passphrase": mappingPassword]
        if partial { args["excludeTypes"] = ["EMAIL"] }
        let result = try call("anonymize", args)
        XCTAssertFalse(result.0, result.1)
        return try XCTUnwrap(result.2["redactedHandle"] as? String)
    }
    private var journal: MCPAuditJournal { MCPAuditJournal(vault: vault) }

    func testUnapprovedPartialResponseReturnsNoContentEvenWithApprovalArguments() throws {
        let handle = try anonymize(staged(), partial: true)
        let response = try call("read_redacted", ["handle": handle, "approved": true, "localApproval": true])
        XCTAssertTrue(response.0)
        XCTAssertTrue(response.1.contains("local_approval_required"))
        XCTAssertFalse(response.1.contains("private@example.com"))
        let events = try journal.verify().records
        XCTAssertEqual(events.last?.event.outcome, .refused)
        XCTAssertEqual(events.last?.event.localApproval, false)
    }

    func testApprovalIsFreshForEveryExactResponse() throws {
        let handle = try anonymize(staged(), partial: true)
        var reviewed: [String] = []
        server = makeServer { text, count in
            XCTAssertEqual(count, 1)
            reviewed.append(text)
            return reviewed.count == 1
        }
        let first = try call("read_redacted", ["handle": handle])
        XCTAssertFalse(first.0)
        XCTAssertEqual(first.2["text"] as? String, reviewed.first)
        XCTAssertTrue(first.1.contains("private@example.com"))
        let second = try call("read_redacted", ["handle": handle])
        XCTAssertTrue(second.0)
        XCTAssertFalse(second.1.contains("private@example.com"))
        XCTAssertEqual(reviewed.count, 2)
        XCTAssertEqual(try journal.verify().records.filter { $0.event.localApproval }.count, 1)
    }

    func testFullyRedactedResponseNeedsNoConsent() throws {
        let handle = try anonymize(staged(), partial: false)
        server = makeServer { _, _ in XCTFail("Fully redacted response asked for consent"); return false }
        let response = try call("read_redacted", ["handle": handle])
        XCTAssertFalse(response.0)
        XCTAssertFalse(response.1.contains("private@example.com"))
    }

    func testLegacyUnknownExclusionStatusRequiresLocalReview() throws {
        let handle = try anonymize(staged(), partial: true)
        try vault.withRegistryTransaction {
            let registry = try vault.loadRegistryLocked()
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(registry)) as? [String: Any])
            var entries = try XCTUnwrap(object["entries"] as? [[String: Any]])
            let index = try XCTUnwrap(entries.firstIndex { $0["handle"] as? String == handle })
            entries[index].removeValue(forKey: "excludedEntityCount")
            object["entries"] = entries
            try vault.saveRegistryLocked(JSONDecoder().decode(DocumentVault.Registry.self, from: JSONSerialization.data(withJSONObject: object)))
        }
        var requested = false
        server = makeServer { _, count in requested = true; XCTAssertEqual(count, -1); return false }
        let response = try call("read_redacted", ["handle": handle])
        XCTAssertTrue(requested)
        XCTAssertTrue(response.0)
        XCTAssertFalse(response.1.contains("private@example.com"))
    }

    func testFailureToPersistResponseSuppressesApprovedText() throws {
        let handle = try anonymize(staged(), partial: true)
        server = makeServer { _, _ in
            let checkpoint = self.root.appendingPathComponent("vault/mcp-audit-checkpoint.sealed")
            try! Data("damaged".utf8).write(to: checkpoint)
            return true
        }
        let response = try call("read_redacted", ["handle": handle])
        XCTAssertTrue(response.0)
        XCTAssertTrue(response.1.contains("audit_unavailable"))
        XCTAssertFalse(response.1.contains("private@example.com"))
        XCTAssertEqual(server.metrics.snapshot().redactedBytesReturned, 0)
        XCTAssertEqual(server.metrics.snapshot().partiallyRedactedBytesReturned, 0)
    }

    func testAuditSurvivesRestartAndContainsNoCallerValuesOrPasswords() throws {
        let handle = try anonymize(staged(), partial: false)
        server = makeServer { _, _ in false }
        _ = try call("read_redacted", ["handle": handle])
        _ = try call("unknown-private-tool", ["value": "private-path-name"])
        let report = try journal.verify()
        XCTAssertEqual(report.records.count, 6)
        XCTAssertEqual(Set(report.records.map { $0.event.sessionID }).count, 2)
        let exported = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        for secret in [mappingPassword, "private@example.com", "private-client-filename", "private-request-label", "unknown-private-tool", "private-path-name"] {
            XCTAssertFalse(exported.contains(secret), secret)
        }
        XCTAssertEqual(report.records.last?.event.operation, "unknown")
    }

    func testDamagedJournalPreventsAnonymizeMutation() throws {
        let original = try staged()
        _ = try call("attest")
        let before = try vault.list().count
        try Data("damaged".utf8).write(to: root.appendingPathComponent("vault/mcp-audit-checkpoint.sealed"))
        let response = try call("anonymize", ["handle": original, "passphrase": mappingPassword])
        XCTAssertTrue(response.0)
        XCTAssertTrue(response.1.contains("audit_unavailable"))
        XCTAssertEqual(try vault.list().count, before)
    }

    func testMatterSelectionIsLocalAndInheritedAcrossRoundTrip() throws {
        let original = try staged()
        let matterID = UUID()
        server.chooseWorkspaceForTesting = { entry in
            XCTAssertEqual(entry.handle, original)
            return matterID
        }
        let chosen = try call("choose_workspace", ["handle": original])
        XCTAssertFalse(chosen.0)
        XCTAssertEqual(chosen.2["workspaceID"] as? String, matterID.uuidString.lowercased())
        let redacted = try anonymize(original, partial: false)
        let restored = try call("restore", ["redactedHandle": redacted, "passphrase": mappingPassword])
        XCTAssertFalse(restored.0)
        let restoredHandle = try XCTUnwrap(restored.2["restoredHandle"] as? String)
        for handle in [original, redacted, restoredHandle] { XCTAssertEqual(try vault.entry(handle: handle).workspaceID, matterID) }
        XCTAssertEqual(try journal.verify().records.last?.event.documents.first?.workspaceID, matterID)
        let listing = try call("list_pending")
        XCTAssertTrue(listing.1.contains(matterID.uuidString.lowercased()))
    }

    func testMCPArgumentsCannotSelectOrOverrideMatter() throws {
        let original = try staged()
        server.chooseWorkspaceForTesting = { _ in XCTFail("Invalid request opened picker"); return UUID() }
        let response = try call("choose_workspace", ["handle": original, "workspaceID": UUID().uuidString])
        XCTAssertTrue(response.0)
        XCTAssertNil(try vault.entry(handle: original).workspaceID)
    }

    func testCancelledSelectionPreservesMatter() throws {
        let original = try staged()
        let matterID = UUID()
        _ = try vault.assignWorkspace(handle: original, workspaceID: matterID)
        server.chooseWorkspaceForTesting = { _ in throw MCPVaultToolError.workspaceSelectionCancelled }
        XCTAssertTrue(try call("choose_workspace", ["handle": original]).0)
        XCTAssertEqual(try vault.entry(handle: original).workspaceID, matterID)
    }
}
