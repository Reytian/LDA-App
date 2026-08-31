//
//  MCPSessionSeamTests.swift
//  LDACoreTests
//
//  The MCP half of the session seam pass. SessionSeamTests covers the engine,
//  SessionSeamWarningTests covers the CLI and the GUI, and this file covers the
//  third consumer: anonymize_session's response dictionary.
//
//  An unresolved seam means one document of the session restores a redacted
//  site to a DIFFERENT party's real name while the redacted files and the
//  mapping sidecar look perfectly ordinary. An agent driving LDA over MCP has
//  no other channel to learn that, so a response without the field hands back
//  a session that looks clean and is not.
//
//  The fixture is the same realistic shape the other two suites use: a matter
//  reused from an earlier engagement holds 甲公司 as a party's pseudonym, and
//  the new document uses 甲公司 as ordinary contract boilerplate. Nothing in
//  the session emits that replacement, so no remint can move it and the engine
//  has to report instead of repair.
//
//  Two things are asserted that the CLI and GUI suites do not have to care
//  about, because this response crosses a boundary those two do not:
//
//   - The warning lines must name the caller's own handle. The name the engine
//     puts in a line comes from SessionDocument.name, which on this path is the
//     lastPathComponent of a vault scratch file: opaque, but it carries the
//     host PID and tells the agent nothing it can act on.
//   - No part of the original filename may appear. Under this project's threat
//     model a PRC legal filename is itself PII (folders are named after the
//     parties), so the fixtures below are staged under a party-shaped name and
//     the whole response is searched for it.
//
//  Deterministic-only sessions (no GGUF model required); hermetic temp-rooted
//  vault and client store with passphrase protection, so no Keychain access.
//
//  House rules: all comments and strings in English. Fixture strings and
//  generated pseudonyms may be Chinese. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDAMCP
@testable import LDACore

final class MCPSessionSeamTests: XCTestCase {

    private var server: MCPServer!
    private var workDir: URL!
    private var vaultDir: URL!
    private var clientRoot: URL!

    /// One passphrase covers both things the tool protects with the argument:
    /// the client mapping it seeds from and the session sidecar it writes.
    private let passphrase = "mcp-session-seam-passphrase"
    private let clientLabel = "Earlier Matter"
    private static let createdAt = "2026-08-31T00:00:00Z"

    /// A filename shaped like real PRC legal work: it names the party. Nothing
    /// derived from this may reach the response.
    private static let partyShapedName = "北京鼎盛科技-合同-甲方.txt"

    /// Boilerplate that spells the carried-in pseudonym, plus one email so the
    /// deterministic detector has something real to redact. Company detection
    /// is LLM-only, so 甲公司 stays ordinary text here, which is the whole
    /// point: it is never a substitution site and restore replaces it anyway.
    private static let collidingText =
        "本合同由甲公司与丙方签署。联系 john@acme.com。"

    /// The same document without the colliding boilerplate. Everything else
    /// about the run is identical, so a difference in the warning can only
    /// come from the seam.
    private static let cleanText =
        "本合同由丁方与丙方签署。联系 john@acme.com。"

    override func setUpWithError() throws {
        try super.setUpWithError()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPSessionSeamTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        vaultDir = workDir.appendingPathComponent("vault", isDirectory: true)
        clientRoot = workDir.appendingPathComponent("clients", isDirectory: true)
        server = MCPServer(environment: VaultTestSupport.serverEnvironment(vaultDir: vaultDir))
        MCPServer.clientStoreRootForTesting = clientRoot
    }

    override func tearDownWithError() throws {
        MCPServer.clientStoreSeam.clear()
        XCTAssertFalse(
            MCPServer.clientStoreSeam.isInstalled,
            "a seam left installed leaks into every later test in this process"
        )
        if let workDir, FileManager.default.fileExists(atPath: workDir.path) {
            try? FileManager.default.removeItem(at: workDir)
        }
        try super.tearDownWithError()
    }

    // MARK: - Helpers (MCPStyleTests conventions)

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
        return try VaultTestSupport.vault(root: vaultDir)
            .stage(fileURL: url, stagedAtISO8601: Self.createdAt)
            .handle
    }

    /// The earlier matter's stored identities: 甲公司 already stands for a
    /// company that appears nowhere in this session.
    private func seedCarriedInMatter() throws {
        let mapping = Mapping(
            entries: [
                "甲公司": MappingEntry(
                    token: "甲公司",
                    value: "北京鼎盛科技有限公司",
                    type: .company,
                    surfaceText: "北京鼎盛科技有限公司",
                    aliases: []
                )
            ],
            createdAtISO8601: Self.createdAt,
            sourceFile: "earlier matter",
            style: .pseudonym
        )
        try ClientMappingStore(rootDirectory: clientRoot)
            .save(mapping, label: clientLabel, protection: .passphrase(passphrase))
    }

    /// Drive anonymize_session over the seeded matter in pseudonym style, which
    /// is the only style with literal seams, and hand back its summary.
    private func runSession(
        texts: [(String, String)],
        id: Int = 1
    ) throws -> (summary: [String: Any], handles: [String]) {
        try seedCarriedInMatter()
        let handles = try texts.map { try stage($0.1, named: $0.0) }

        let response = try callTool("anonymize_session", arguments: [
            "handles": handles,
            "passphrase": passphrase,
            "client": clientLabel,
            "style": "pseudonym"
        ], id: id)

        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false, "session reported an error: \(result)")
        return (try toolSummary(from: response), handles)
    }

    // MARK: - The response carries the engine's verdict

    func testSessionResponseReportsTheSeamItCouldNotRepair() throws {
        let run = try runSession(texts: [(Self.partyShapedName, Self.collidingText)])

        let seams = try XCTUnwrap(
            run.summary["unresolvedSeams"] as? [String],
            "the response must carry the field: \(run.summary)"
        )
        XCTAssertEqual(seams.count, 1)
        let line = try XCTUnwrap(seams.first)
        XCTAssertTrue(line.contains("甲公司"), "the line must name the replacement: \(line)")
    }

    /// The negative control. An empty list is exactly what a DROPPED field also
    /// looks like, so the test above proves nothing on its own.
    func testACleanSessionReportsAnEmptySeamList() throws {
        let run = try runSession(texts: [(Self.partyShapedName, Self.cleanText)])

        let seams = try XCTUnwrap(
            run.summary["unresolvedSeams"] as? [String],
            "the field must be present even when the session is clean: \(run.summary)"
        )
        XCTAssertTrue(seams.isEmpty)
    }

    /// The session is still written. The warning is a correctness warning about
    /// artifacts that exist, not a failure that suppressed them.
    func testTheWarnedSessionStillProducesItsDocuments() throws {
        let run = try runSession(texts: [(Self.partyShapedName, Self.collidingText)])

        let seams = try XCTUnwrap(run.summary["unresolvedSeams"] as? [String])
        XCTAssertFalse(seams.isEmpty, "fixture: the seam must be reported")
        let documents = try XCTUnwrap(run.summary["documents"] as? [[String: Any]])
        XCTAssertEqual(documents.count, 1)
        XCTAssertNotNil(documents[0]["redactedHandle"] as? String)
    }

    // MARK: - The boundary: handles in, handles out

    func testTheSeamLineNamesTheCallersHandle() throws {
        let run = try runSession(texts: [(Self.partyShapedName, Self.collidingText)])

        let seams = try XCTUnwrap(run.summary["unresolvedSeams"] as? [String])
        let line = try XCTUnwrap(seams.first, "fixture: the seam must be reported")
        XCTAssertTrue(
            line.hasPrefix("\(run.handles[0]):"),
            "the line must name the handle the caller passed: \(line)"
        )
    }

    /// The vault scratch name is opaque, but it is not the caller's vocabulary
    /// and it carries the host PID. This response says it deals in handles and
    /// aggregate counts only, so no scratch filename may ride out on it.
    func testTheSeamLineDoesNotCarryTheVaultScratchName() throws {
        let run = try runSession(texts: [(Self.partyShapedName, Self.collidingText)])

        let seams = try XCTUnwrap(run.summary["unresolvedSeams"] as? [String])
        let line = try XCTUnwrap(seams.first, "fixture: the seam must be reported")
        // DocumentVaultEncryption names scratch plaintext pt_<pid>_<hex>.<ext>.
        XCTAssertFalse(
            line.contains("pt_"),
            "a vault scratch filename reached the response: \(line)"
        )
    }

    /// A PRC legal filename names the parties, so it is PII in its own right.
    /// The response is the one channel that must never carry it.
    func testNoPartOfTheOriginalFilenameReachesTheResponse() throws {
        let run = try runSession(texts: [(Self.partyShapedName, Self.collidingText)])

        let seams = try XCTUnwrap(run.summary["unresolvedSeams"] as? [String])
        XCTAssertFalse(seams.isEmpty, "fixture: the seam must be reported")

        let encoded = try XCTUnwrap(
            String(
                data: try JSONSerialization.data(
                    withJSONObject: run.summary,
                    options: [.sortedKeys]
                ),
                encoding: .utf8
            )
        )
        for fragment in ["北京鼎盛科技-合同-甲方", "合同-甲方", ".txt"] {
            XCTAssertFalse(
                encoded.contains(fragment),
                "the original filename fragment \(fragment) reached the response: \(encoded)"
            )
        }
    }

    /// Which document has the seam has to survive the rename. With two staged
    /// documents the line must name the SECOND handle, not just any handle, so
    /// an implementation that maps every line onto handles[0] fails here.
    func testTheSeamLineNamesTheDocumentThatActuallyHasIt() throws {
        let run = try runSession(texts: [
            ("清白-文件.txt", Self.cleanText),
            (Self.partyShapedName, Self.collidingText)
        ])

        let seams = try XCTUnwrap(run.summary["unresolvedSeams"] as? [String])
        let line = try XCTUnwrap(seams.first, "fixture: the seam must be reported")
        XCTAssertTrue(
            line.hasPrefix("\(run.handles[1]):"),
            "the line must name the second document's handle: \(line)"
        )
        XCTAssertFalse(
            line.hasPrefix("\(run.handles[0]):"),
            "the clean document must not be blamed: \(line)"
        )
    }
}
