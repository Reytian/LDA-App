//
//  MCPReviewExclusionTests.swift
//  LDACoreTests
//
//  The review step on the handle-first MCP surface: detect_entities hands back
//  an id per entity and a detectionId for the set, and anonymize accepts
//  excludeEntityIds (with the detectionId they came with) and excludeTypes so
//  an agent can say "redact everything except these" without ever seeing a
//  name. Ids derive from the handle, the type, and the offsets, all of which
//  the tool already discloses, so they add no information to the wire, and
//  they cannot be carried from one document to another.
//
//  Every test drives the server over JSON-RPC, exactly as an agent host would,
//  and recomputes the expected ids with CryptoKit so the wire contract is
//  pinned independently of the implementation. Deterministic detection only
//  (no GGUF model), hermetic temp-rooted vaults, passphrase-protected
//  sidecars: nothing here touches the Keychain.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import CryptoKit
import XCTest
@testable import LDAMCP
@testable import LDACore

final class MCPReviewExclusionTests: XCTestCase {

    private var workDir: URL!
    private var vaultDir: URL!
    private var server: MCPServer!

    private let passphrase = "mcp-review-passphrase"
    private static let stagedAt = "2026-09-02T00:00:00Z"
    private static let firstEmail = "alpha.party@example.com"
    private static let secondEmail = "beta.party@example.com"
    private static let bodyDate = "2024-01-15"
    private static let headerDate = "2023-12-31"
    private static let twoEmailsText = "Reach \(firstEmail) or \(secondEmail) by \(bodyDate)."

    override func setUpWithError() throws {
        try super.setUpWithError()
        assertNoTestSeamsInstalled()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPReviewExclusionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        vaultDir = workDir.appendingPathComponent("vault", isDirectory: true)
        server = MCPServer(environment: VaultTestSupport.serverEnvironment(vaultDir: vaultDir))
    }

    override func tearDownWithError() throws {
        if let workDir, FileManager.default.fileExists(atPath: workDir.path) {
            try? FileManager.default.removeItem(at: workDir)
        }
        try super.tearDownWithError()
    }

    // MARK: - JSON-RPC helpers

    private func roundTrip(_ request: [String: Any]) throws -> [String: Any] {
        let payload = try JSONSerialization.data(withJSONObject: request)
        let responseData = try XCTUnwrap(server.handle(payload), "expected a response for \(request)")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: responseData) as? [String: Any])
    }

    /// tools/call returning (isError, text of the first content block).
    private func call(tool: String, arguments: [String: Any]) throws -> (isError: Bool, text: String) {
        let response = try roundTrip([
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": tool, "arguments": arguments]
        ])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        return (
            isError: (result["isError"] as? Bool) ?? false,
            text: (content.first?["text"] as? String) ?? ""
        )
    }

    /// tools/call asserting success and decoding the JSON summary.
    private func summary(tool: String, arguments: [String: Any]) throws -> [String: Any] {
        let response = try call(tool: tool, arguments: arguments)
        XCTAssertFalse(response.isError, "\(tool) failed: \(response.text)")
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(response.text.utf8)) as? [String: Any]
        )
    }

    private func toolSchema(named name: String) throws -> [String: Any] {
        let response = try roundTrip(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
        let tool = try XCTUnwrap(tools.first { ($0["name"] as? String) == name }, "\(name) must be advertised")
        return try XCTUnwrap(tool["inputSchema"] as? [String: Any])
    }

    // MARK: - Fixtures

    private var vault: DocumentVault { VaultTestSupport.vault(root: vaultDir) }

    private func stage(_ url: URL) throws -> String {
        try vault.stage(fileURL: url, stagedAtISO8601: Self.stagedAt).handle
    }

    private func stageText(_ contents: String, named name: String = "matter.txt") throws -> String {
        let url = workDir.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return try stage(url)
    }

    private func stageDocxWithHeaderDate() throws -> String {
        let url = workDir.appendingPathComponent("agreement.docx")
        try DocxFixtureSupport.write(
            paragraphs: [[
                .plain("Contact "),
                .bold(Self.firstEmail),
                .plain(" before \(Self.bodyDate).")
            ]],
            header: [[.plain("Dated \(Self.headerDate)")]],
            to: url
        )
        return try stage(url)
    }

    private func readRedacted(_ handle: String) throws -> String {
        try XCTUnwrap(try summary(tool: "read_redacted", arguments: ["handle": handle])["text"] as? String)
    }

    /// Decrypt a vault artifact to a scratch file the test owns (MCP clients never do this).
    private func plaintextCopy(of handle: String, extension ext: String) throws -> URL {
        let url = workDir.appendingPathComponent("copy-\(UUID().uuidString).\(ext)")
        try vault.readDocumentBytes(handle: handle).write(to: url)
        return url
    }

    private func listedHandleCount() throws -> Int {
        try XCTUnwrap(try summary(tool: "list_pending", arguments: [:])["documents"] as? [[String: Any]]).count
    }

    private func objectDirectoryNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(
            at: vaultDir.appendingPathComponent(DocumentVault.objectsDirectoryName, isDirectory: true),
            includingPropertiesForKeys: nil
        ).map(\.lastPathComponent).sorted()
    }

    private func detection(for handle: String) throws -> (detectionId: String, entities: [[String: Any]]) {
        let result = try summary(tool: "detect_entities", arguments: ["handle": handle])
        return (
            try XCTUnwrap(result["detectionId"] as? String, "detect_entities must return a detectionId: \(result)"),
            try XCTUnwrap(result["entities"] as? [[String: Any]])
        )
    }

    /// The id of the entity covering `surface` in `text`, as detect_entities reported it.
    private func entityId(
        covering surface: String,
        in text: String,
        from entities: [[String: Any]]
    ) throws -> String {
        let range = (text as NSString).range(of: surface)
        XCTAssertNotEqual(range.location, NSNotFound, "fixture: \(surface) must be in the text")
        let match = try XCTUnwrap(
            entities.first {
                ($0["start"] as? Int) == range.location
                    && ($0["end"] as? Int) == range.location + range.length
            },
            "no entity covers \(surface): \(entities)"
        )
        return try XCTUnwrap(match["id"] as? String, "entities must carry an id: \(match)")
    }

    // MARK: - The wire formula, recomputed independently

    private func hex(_ digest: SHA256Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private func expectedEntityId(handle: String, type: String, start: Int, end: Int) -> String {
        String(hex(SHA256.hash(data: Data("\(handle)|\(type)|\(start)|\(end)".utf8))).prefix(12))
    }

    private func expectedDetectionId(handle: String, modelPathPresent: Bool, ids: [String]) -> String {
        let material = "\(handle)|\(modelPathPresent ? 1 : 0)|" + ids.sorted().joined(separator: ",")
        return String(hex(SHA256.hash(data: Data(material.utf8))).prefix(16))
    }

    private func isLowercaseHex(_ value: String, length: Int) -> Bool {
        value.count == length && value.allSatisfy { "0123456789abcdef".contains($0) }
    }

    // MARK: - Schema

    func testAnonymizeToolsAdvertiseTheReviewArgumentsAsOptional() throws {
        let anonymize = try toolSchema(named: "anonymize")
        let properties = try XCTUnwrap(anonymize["properties"] as? [String: Any])
        for key in ["excludeEntityIds", "excludeTypes", "detectionId"] {
            let property = try XCTUnwrap(properties[key] as? [String: Any], "anonymize must advertise \(key)")
            XCTAssertFalse((property["description"] as? String ?? "").isEmpty, "\(key) needs a description")
        }
        XCTAssertEqual((properties["excludeEntityIds"] as? [String: Any])?["type"] as? String, "array")
        XCTAssertEqual((properties["excludeTypes"] as? [String: Any])?["type"] as? String, "array")
        XCTAssertEqual((properties["detectionId"] as? [String: Any])?["type"] as? String, "string")
        XCTAssertEqual(anonymize["required"] as? [String], ["handle"], "the review arguments stay optional")

        let session = try toolSchema(named: "anonymize_session")
        let sessionProperties = try XCTUnwrap(session["properties"] as? [String: Any])
        XCTAssertNotNil(sessionProperties["excludeTypes"], "anonymize_session must advertise excludeTypes")
        XCTAssertNil(sessionProperties["excludeEntityIds"], "per-entity ids are single-document by construction")
        XCTAssertNil(sessionProperties["detectionId"])
        XCTAssertEqual(session["required"] as? [String], ["handles"])
    }

    // MARK: - detect_entities ids

    func testDetectEntitiesReturnsStableIdsBoundToTheHandleTypeAndOffsets() throws {
        let handle = try stageText(Self.twoEmailsText)

        let first = try detection(for: handle)
        let second = try detection(for: handle)

        XCTAssertTrue(isLowercaseHex(first.detectionId, length: 16), first.detectionId)
        XCTAssertEqual(first.detectionId, second.detectionId, "the same handle yields the same detectionId")
        XCTAssertEqual(first.entities.count, 3, "fixture: two emails and a date")

        var ids: [String] = []
        for entity in first.entities {
            let id = try XCTUnwrap(entity["id"] as? String, "every entity carries an id: \(entity)")
            XCTAssertTrue(isLowercaseHex(id, length: 12), id)
            XCTAssertEqual(
                id,
                expectedEntityId(
                    handle: handle,
                    type: try XCTUnwrap(entity["type"] as? String),
                    start: try XCTUnwrap(entity["start"] as? Int),
                    end: try XCTUnwrap(entity["end"] as? Int)
                ),
                "the id is SHA-256 over handle|type|start|end, first 12 hex characters"
            )
            XCTAssertNil(entity["text"], "no surface text rides along with the id")
            ids.append(id)
        }
        XCTAssertEqual(Set(ids).count, ids.count, "ids are unique within one detection")
        XCTAssertEqual(
            first.detectionId,
            expectedDetectionId(handle: handle, modelPathPresent: false, ids: ids),
            "the detectionId is SHA-256 over handle|modelPathPresent|sorted ids, first 16 hex characters"
        )
        XCTAssertEqual(
            second.entities.compactMap { $0["id"] as? String },
            ids,
            "ids are stable across calls"
        )

        // Ids are bound to the handle: the same text staged under another
        // handle yields different ids, so an id cannot be carried across
        // documents to keep a different document's value visible.
        let twin = try stageText(Self.twoEmailsText, named: "twin.txt")
        let twinIds = try detection(for: twin).entities.compactMap { $0["id"] as? String }
        XCTAssertEqual(twinIds.count, ids.count)
        XCTAssertTrue(Set(twinIds).isDisjoint(with: Set(ids)), "ids must not be portable across handles")
    }

    // MARK: - Exclusion by id

    func testExcludingOneEntityByIdLeavesExactlyThatValueVisible() throws {
        let handle = try stageText(Self.twoEmailsText)
        let detected = try detection(for: handle)
        let target = try entityId(covering: Self.firstEmail, in: Self.twoEmailsText, from: detected.entities)

        let result = try summary(tool: "anonymize", arguments: [
            "handle": handle,
            "passphrase": passphrase,
            "excludeEntityIds": [target],
            "detectionId": detected.detectionId
        ])

        XCTAssertEqual(result["excludedCount"] as? Int, 1, "\(result)")
        XCTAssertEqual(result["detectionChanged"] as? Bool, false, "\(result)")
        XCTAssertEqual(result["entityCount"] as? Int, 2)
        XCTAssertEqual((result["perTypeCounts"] as? [String: Int])?["EMAIL"], 1)

        let redactedHandle = try XCTUnwrap(result["redactedHandle"] as? String)
        let redacted = try readRedacted(redactedHandle)
        XCTAssertTrue(redacted.contains(Self.firstEmail), "the excluded value stays visible: \(redacted)")
        XCTAssertFalse(redacted.contains(Self.secondEmail), "every other value is still redacted: \(redacted)")
        XCTAssertTrue(redacted.contains("{EMAIL_1}"), redacted)
        XCTAssertFalse(redacted.contains("{EMAIL_2}"), "the excluded span never minted a token: \(redacted)")
        XCTAssertTrue(redacted.contains("{DATE_1}"), redacted)
    }

    func testEntityIdsWithoutADetectionIdAreRefused() throws {
        let handle = try stageText(Self.twoEmailsText)
        let detected = try detection(for: handle)
        let target = try entityId(covering: Self.firstEmail, in: Self.twoEmailsText, from: detected.entities)

        let response = try call(tool: "anonymize", arguments: [
            "handle": handle,
            "passphrase": passphrase,
            "excludeEntityIds": [target]
        ])

        XCTAssertTrue(response.isError)
        XCTAssertTrue(response.text.hasPrefix("detection_id_required"), response.text)
        XCTAssertEqual(try listedHandleCount(), 1, "no artifact is written on a refused call")
    }

    func testAnUnknownEntityIdIsRefusedBeforeAnyArtifactIsWritten() throws {
        let handle = try stageText(Self.twoEmailsText)
        let detected = try detection(for: handle)
        let target = try entityId(covering: Self.firstEmail, in: Self.twoEmailsText, from: detected.entities)

        let response = try call(tool: "anonymize", arguments: [
            "handle": handle,
            "passphrase": passphrase,
            "excludeEntityIds": [target, "ffffffffffff"],
            "detectionId": detected.detectionId
        ])

        XCTAssertTrue(response.isError)
        XCTAssertTrue(response.text.hasPrefix("unknown_entity_id: count=1"), response.text)
        XCTAssertTrue(response.text.contains("detect_entities"), "the fix is named: \(response.text)")
        XCTAssertEqual(try listedHandleCount(), 1, "no redacted artifact was registered")
        XCTAssertEqual(try objectDirectoryNames(), [handle], "no artifact directory was left behind")
    }

    func testAnUnknownEntityTypeIsAReadableArgumentError() throws {
        let handle = try stageText(Self.twoEmailsText)

        let response = try call(tool: "anonymize", arguments: [
            "handle": handle,
            "passphrase": passphrase,
            "excludeTypes": ["DATE", "SOCIAL"]
        ])

        XCTAssertTrue(response.isError, "an unknown type must not be silently ignored")
        XCTAssertTrue(response.text.contains("excludeTypes"), response.text)
        XCTAssertTrue(response.text.contains("SOCIAL"), response.text)
        XCTAssertTrue(response.text.contains("PERSON"), "the error lists the allowed types: \(response.text)")
        XCTAssertEqual(try listedHandleCount(), 1)
    }

    /// An id from another document is never honored, even when that
    /// document has an entity at the same offsets: ids are bound to the
    /// handle, so a foreign id fails hard as unknown, and nothing is written.
    func testAForeignEntityIdIsRefusedEvenWhenItsOffsetsMatch() throws {
        let shorter = "Reach \(Self.firstEmail) or \(Self.secondEmail)."
        let longer = shorter + " Signed \(Self.bodyDate)."
        let shorterHandle = try stageText(shorter, named: "one.txt")
        let longerHandle = try stageText(longer, named: "two.txt")
        let detected = try detection(for: shorterHandle)
        let foreign = try entityId(covering: Self.firstEmail, in: shorter, from: detected.entities)

        let refused = try call(tool: "anonymize", arguments: [
            "handle": longerHandle,
            "passphrase": passphrase,
            "excludeEntityIds": [foreign],
            "detectionId": detected.detectionId
        ])

        XCTAssertTrue(refused.isError, "a foreign id must not keep a value visible: \(refused.text)")
        XCTAssertTrue(refused.text.hasPrefix("unknown_entity_id: count=1"), refused.text)
        XCTAssertEqual(try listedHandleCount(), 2, "nothing was written")
        XCTAssertEqual(try objectDirectoryNames(), [shorterHandle, longerHandle].sorted())
    }

    /// Over-redaction is the safe direction: when every excluded id is
    /// present but the supplied detectionId does not match this run's
    /// detection, anonymize proceeds and says so.
    func testAStaleDetectionIdWithEveryExcludedIdPresentProceedsAndSaysSo() throws {
        let handle = try stageText(Self.twoEmailsText)
        let detected = try detection(for: handle)
        let target = try entityId(covering: Self.firstEmail, in: Self.twoEmailsText, from: detected.entities)

        let changed = try summary(tool: "anonymize", arguments: [
            "handle": handle,
            "passphrase": passphrase,
            "excludeEntityIds": [target],
            "detectionId": "0000000000000000"
        ])
        XCTAssertEqual(changed["detectionChanged"] as? Bool, true, "\(changed)")
        XCTAssertEqual(changed["excludedCount"] as? Int, 1)
        let redacted = try readRedacted(try XCTUnwrap(changed["redactedHandle"] as? String))
        XCTAssertTrue(redacted.contains(Self.firstEmail), redacted)
        XCTAssertFalse(redacted.contains(Self.secondEmail), redacted)

        // Control: the detection the ids came from is not "changed".
        let unchanged = try summary(tool: "anonymize", arguments: [
            "handle": handle,
            "passphrase": passphrase,
            "excludeEntityIds": [target],
            "detectionId": detected.detectionId
        ])
        XCTAssertEqual(unchanged["detectionChanged"] as? Bool, false, "\(unchanged)")
    }

    // MARK: - Id argument hygiene

    /// Ids are validated at parse time, before the vault is opened: an id that
    /// is not exactly 12 lowercase hex characters is an argument error that
    /// never echoes the value, and a bad id on an unknown handle reports the
    /// id problem rather than touching the vault.
    func testMalformedEntityIdsAreRefusedBeforeTheVaultIsOpened() throws {
        let handle = try stageText(Self.twoEmailsText)
        let detected = try detection(for: handle)

        for bad in ["ZZZZZZZZZZZZ", "ABCDEF012345", "abcdef01234", "abcdef0123456", "abcdef01234g", "../secret"] {
            let refused = try call(tool: "anonymize", arguments: [
                "handle": handle,
                "passphrase": passphrase,
                "excludeEntityIds": [bad],
                "detectionId": detected.detectionId
            ])
            XCTAssertTrue(refused.isError, "\(bad) must be refused")
            XCTAssertTrue(refused.text.hasPrefix("invalid_entity_id"), "\(bad): \(refused.text)")
            XCTAssertFalse(refused.text.contains(bad), "the offending value is never echoed: \(refused.text)")
        }

        // The argument error wins over an unknown handle: parsing came first.
        let unknownHandle = try call(tool: "anonymize", arguments: [
            "handle": "doc_000000000000",
            "excludeEntityIds": ["not-an-id!!"],
            "detectionId": "0000000000000000"
        ])
        XCTAssertTrue(unknownHandle.isError)
        XCTAssertTrue(unknownHandle.text.hasPrefix("invalid_entity_id"), unknownHandle.text)
        XCTAssertEqual(try listedHandleCount(), 1)
    }

    func testMoreThanTenThousandEntityIdsAreRefused() throws {
        let handle = try stageText(Self.twoEmailsText)
        let detected = try detection(for: handle)
        let flood = (0 ..< 10_001).map { String(format: "%012x", $0) }

        let refused = try call(tool: "anonymize", arguments: [
            "handle": handle,
            "passphrase": passphrase,
            "excludeEntityIds": flood,
            "detectionId": detected.detectionId
        ])
        XCTAssertTrue(refused.isError)
        XCTAssertTrue(refused.text.hasPrefix("invalid_entity_id"), refused.text)
        XCTAssertTrue(refused.text.contains("10000"), "the cap is named: \(refused.text)")

        // Exactly the cap passes the argument check and fails later as
        // unknown ids, which proves the parser let the shape through.
        let atCap = try call(tool: "anonymize", arguments: [
            "handle": handle,
            "passphrase": passphrase,
            "excludeEntityIds": Array(flood.prefix(10_000)),
            "detectionId": detected.detectionId
        ])
        XCTAssertTrue(atCap.isError)
        XCTAssertTrue(atCap.text.hasPrefix("unknown_entity_id: count=10000"), atCap.text)
        XCTAssertEqual(try listedHandleCount(), 1, "nothing was written on either refusal")
    }

    // MARK: - Exclusion by type

    func testExcludedTypesVanishFromBodyAndHeaderPartsOfADocx() throws {
        let handle = try stageDocxWithHeaderDate()

        // Control: without exclusions the header date is tokenized.
        let control = try summary(tool: "anonymize", arguments: ["handle": handle, "passphrase": passphrase])
        let controlCopy = try plaintextCopy(of: try XCTUnwrap(control["redactedHandle"] as? String), extension: "docx")
        XCTAssertTrue(
            try DocxFixtureSupport.part("word/header1.xml", in: controlCopy).contains("{DATE_"),
            "fixture: the header date must be detectable"
        )
        XCTAssertEqual(control["excludedCount"] as? Int, 0)

        let result = try summary(tool: "anonymize", arguments: [
            "handle": handle,
            "passphrase": passphrase,
            "excludeTypes": ["DATE"]
        ])
        XCTAssertNil((result["perTypeCounts"] as? [String: Int])?["DATE"], "\(result)")
        XCTAssertFalse((result["entityTypes"] as? [String] ?? []).contains("DATE"))
        XCTAssertEqual(result["excludedCount"] as? Int, 1)
        XCTAssertEqual(result["detectionChanged"] as? Bool, false)

        let copy = try plaintextCopy(of: try XCTUnwrap(result["redactedHandle"] as? String), extension: "docx")
        let header = try DocxFixtureSupport.part("word/header1.xml", in: copy)
        XCTAssertTrue(header.contains(Self.headerDate), "the header date stays visible")
        XCTAssertFalse(header.contains("{DATE_"), "no DATE token in the header part")
        let body = try DocxFixtureSupport.part(docxMainPartPath, in: copy)
        XCTAssertTrue(body.contains(Self.bodyDate), "the body date stays visible")
        XCTAssertFalse(body.contains("{DATE_"), "no DATE token in the body")
        XCTAssertTrue(body.contains("{EMAIL_1}"), "the email is still redacted")
        XCTAssertFalse(body.contains(Self.firstEmail))
    }

    // MARK: - Sessions

    func testAnonymizeSessionHonorsExcludeTypesAndRefusesEntityIds() throws {
        let first = try stageText("Filed by \(Self.firstEmail) on \(Self.bodyDate).", named: "complaint.txt")
        let second = try stageText("Reply to \(Self.firstEmail) before \(Self.headerDate).", named: "annex.txt")

        let session = try summary(tool: "anonymize_session", arguments: [
            "handles": [first, second],
            "passphrase": passphrase,
            "excludeTypes": ["DATE"]
        ])
        let documents = try XCTUnwrap(session["documents"] as? [[String: Any]])
        XCTAssertEqual(documents.count, 2)
        XCTAssertNil((session["perTypeCounts"] as? [String: Int])?["DATE"], "\(session)")
        XCTAssertEqual(session["excludedCount"] as? Int, 2, "\(session)")
        for (index, document) in documents.enumerated() {
            let text = try readRedacted(try XCTUnwrap(document["redactedHandle"] as? String))
            XCTAssertFalse(text.contains("{DATE_"), text)
            XCTAssertTrue(text.contains("{EMAIL_1}"), text)
            XCTAssertTrue(text.contains(index == 0 ? Self.bodyDate : Self.headerDate), text)
        }

        let refused = try call(tool: "anonymize_session", arguments: [
            "handles": [first, second],
            "passphrase": passphrase,
            "excludeEntityIds": ["ffffffffffff"]
        ])
        XCTAssertTrue(refused.isError, "ids are single-document; the session tool must say so, not ignore them")
        XCTAssertTrue(refused.text.hasPrefix("entity_ids_not_supported"), refused.text)
    }
}
