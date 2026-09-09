import XCTest
@testable import LDACore
@testable import LDAMCP

final class MCPPrepareTests: XCTestCase {
    private var root: URL!
    private var vault: DocumentVault!
    private var server: MCPServer!
    private let workspace = UUID()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        vault = VaultTestSupport.vault(root: root.appendingPathComponent("vault"))
        server = MCPServer(environment: VaultTestSupport.serverEnvironment(vaultDir: root.appendingPathComponent("vault")), approvePartialDisclosure: { _, _ in false })
        server.prepareMappingPassphraseForTesting = "fictional-test-key"
        server.chooseWorkspaceForTesting = { [workspace] _ in workspace }
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func call(_ arguments: [String: Any] = [:]) throws -> (Bool, String, [String: Any]) {
        let request: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "prepare_documents", "arguments": arguments]]
        let data = try XCTUnwrap(server.handle(JSONSerialization.data(withJSONObject: request)))
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let blocks = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(blocks.first?["text"] as? String)
        let decoded = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
        return (result["isError"] as? Bool == true, text, decoded)
    }

    func testLocalAdditionalPIIIsRedactedAndAuditedWithoutLeakingValues() throws {
        let source = root.appendingPathComponent("Private filename.txt")
        let original = "Quasar is fictional. Email local@example.com."
        try Data(original.utf8).write(to: source)
        server.selectDocumentsForTesting = { .init(urls: [source], review: true) }
        server.reviewDocumentForTesting = { text, spans in
            XCTAssertEqual(text, original)
            XCTAssertTrue(spans.contains { $0.type == .email })
            return [CustomPattern(text: "Quasar")]
        }
        let response = try call(["workspaceName": "Private Matter"])
        XCTAssertFalse(response.0, response.1)
        for privateValue in ["Quasar", "local@example.com", "Private filename", "Private Matter", root.path] {
            XCTAssertFalse(response.1.contains(privateValue))
        }
        let documents = try XCTUnwrap(response.2["documents"] as? [[String: Any]])
        let handle = try XCTUnwrap(documents.first?["redactedHandle"] as? String)
        let read = try server.callReadRedacted(["handle": handle])
        let safe = try XCTUnwrap(read["text"] as? String)
        XCTAssertFalse(safe.contains("Quasar"))
        XCTAssertFalse(safe.contains("local@example.com"))
        XCTAssertEqual(try vault.entry(handle: handle).workspaceID, workspace)
        let journal = try MCPAuditJournal(vault: vault).verify()
        XCTAssertEqual(journal.records.count, 2)
        XCTAssertEqual(journal.records.last?.event.operation, "prepare_documents")
        XCTAssertEqual(journal.records.last?.event.documents.count, 2)
        let sourceHandle = try XCTUnwrap(documents.first?["sourceHandle"] as? String)
        let anotherServer = MCPServer(environment: VaultTestSupport.serverEnvironment(vaultDir: root.appendingPathComponent("vault")), approvePartialDisclosure: { _, _ in false })
        let repeated = try anotherServer.callAnonymizeHandle(["handle": sourceHandle, "passphrase": "fictional-test-key"])
        let repeatHandle = try XCTUnwrap(repeated["redactedHandle"] as? String)
        let repeatText = try XCTUnwrap(anotherServer.callReadRedacted(["handle": repeatHandle])["text"] as? String)
        XCTAssertFalse(repeatText.contains("Quasar"), "Stored manual protection must survive another MCP process")
        XCTAssertThrowsError(try anotherServer.callAnonymizeSessionHandles(["handles": [sourceHandle], "passphrase": "fictional-test-key"]))
    }

    func testReviewIsOptionalAndCancellationCreatesNoRedactedArtifact() throws {
        let source = root.appendingPathComponent("fixture.txt")
        try Data("Contact demo@example.com".utf8).write(to: source)
        server.selectDocumentsForTesting = { .init(urls: [source], review: false) }
        server.reviewDocumentForTesting = { _, _ in XCTFail("Optional review was not requested"); return [] }
        XCTAssertFalse(try call().0)
        let before = try vault.list().count
        server.selectDocumentsForTesting = { .init(urls: [source], review: true) }
        server.reviewDocumentForTesting = { _, _ in
            XCTAssertEqual(try self.vault.list().count, before, "Unconfirmed sources must not be published")
            throw MCPVaultToolError.localPreparationCancelled
        }
        XCTAssertTrue(try call().0)
        XCTAssertEqual(try vault.list().count, before)
    }

    func testReviewedFindingSurvivesAnOmissionInTheFinalDetector() throws {
        let source = root.appendingPathComponent("fictional.txt")
        try Data("Orion approved this.".utf8).write(to: source)
        server.selectDocumentsForTesting = { .init(urls: [source], review: true) }
        server.localReviewDetectionForTesting = { _ in
            [Span(start: 0, end: 5, type: .person, text: "Orion", source: .manual, confidence: 1, priority: 100)]
        }
        server.reviewDocumentForTesting = { _, spans in XCTAssertEqual(spans.first?.text, "Orion"); return [] }
        let response = try call()
        XCTAssertFalse(response.0, response.1)
        let docs = try XCTUnwrap(response.2["documents"] as? [[String: Any]])
        let handle = try XCTUnwrap(docs.first?["redactedHandle"] as? String)
        let safe = try XCTUnwrap(server.callReadRedacted(["handle": handle])["text"] as? String)
        XCTAssertFalse(safe.contains("Orion"))
    }

    func testClientCannotInjectPathsTermsOrApproval() throws {
        server.selectDocumentsForTesting = { XCTFail("Arguments must be rejected before local selection"); return .init(urls: [], review: false) }
        for args: [String: Any] in [["path": "/private"], ["terms": ["name"]], ["review": false], ["approved": true], ["workspaceName": 42], ["workspaceName": "bad\nname"]] {
            XCTAssertTrue(try call(args).0)
        }
    }

    func testWorkspaceHintIsBoundedAndDoesNotReplaceLocalConfirmation() throws {
        let request = MCPWorkspaceRequest(handle: "doc_aaaaaaaaaaaa", currentWorkspaceID: nil, workspaceHint: "Cedar & Partners")
        XCTAssertEqual(MCPWorkspaceRequest(url: request.url)?.workspaceHint, "Cedar & Partners")
        let invalid = MCPWorkspaceRequest(handle: request.handle, currentWorkspaceID: nil, workspaceHint: String(repeating: "x", count: 257))
        XCTAssertNil(MCPWorkspaceRequest(url: invalid.url))
    }
}
