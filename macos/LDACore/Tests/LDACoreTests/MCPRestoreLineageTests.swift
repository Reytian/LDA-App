//
//  MCPRestoreLineageTests.swift
//  LDACoreTests
//
//  restore's editedHandle must only ever restore a document that belongs to
//  the redacted artifact's own round trip. Two ways that lineage can break,
//  both found by the security audit of this surface:
//
//   - a staged ORIGINAL with no relation to the mapping: the placeholder
//     forensics return verbatim substrings of whatever text they scan, so an
//     unrelated document's real text could ride out as a "suspect
//     placeholder", and the output would commit as a restored artifact that
//     export accepts, laundering an original into the outbox although export
//     refuses originals by design;
//   - a REDACTED artifact of another matter: it restores silently with the
//     wrong mapping (no orphans, no suspects) and exports under the other
//     document's name.
//
//  So an original is accepted only when at least one placeholder of the
//  mapping was actually restored in it, its suspect placeholders are reported
//  as a count only (the human's edits are text the agent has never seen), and
//  a redacted artifact is accepted only when it carries this very mapping.
//
//  Deterministic detection only, hermetic temp-rooted vaults, passphrase
//  protection: nothing here touches the Keychain.
//
//  House rules: all comments and strings in English. No em-dash and no
//  en-dash-as-separator anywhere.
//

import XCTest
@testable import LDAMCP
@testable import LDACore

final class MCPRestoreLineageTests: XCTestCase {

    private var workDir: URL!
    private var vaultDir: URL!
    private var server: MCPServer!

    private let passphrase = "mcp-lineage-passphrase"
    private static let stagedAt = "2026-09-02T00:00:00Z"
    private static let email = "jane.doe@example.com"
    private static let phone = "13912345678"

    override func setUpWithError() throws {
        try super.setUpWithError()
        assertNoTestSeamsInstalled()
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPRestoreLineageTests-\(UUID().uuidString)", isDirectory: true)
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

    private func summary(tool: String, arguments: [String: Any]) throws -> [String: Any] {
        let response = try call(tool: tool, arguments: arguments)
        XCTAssertFalse(response.isError, "\(tool) failed: \(response.text)")
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(response.text.utf8)) as? [String: Any]
        )
    }

    // MARK: - Fixtures

    private var vault: DocumentVault { VaultTestSupport.vault(root: vaultDir) }

    private func stageText(_ contents: String, named name: String) throws -> String {
        let url = workDir.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return try vault.stage(fileURL: url, stagedAtISO8601: Self.stagedAt).handle
    }

    private func anonymize(_ handle: String) throws -> String {
        try XCTUnwrap(
            try summary(tool: "anonymize", arguments: ["handle": handle, "passphrase": passphrase])["redactedHandle"] as? String
        )
    }

    private func readRedacted(_ handle: String) throws -> String {
        try XCTUnwrap(try summary(tool: "read_redacted", arguments: ["handle": handle])["text"] as? String)
    }

    private func restore(_ redactedHandle: String, editedHandle: String) throws -> (isError: Bool, text: String) {
        try call(tool: "restore", arguments: [
            "redactedHandle": redactedHandle,
            "editedHandle": editedHandle,
            "passphrase": passphrase
        ])
    }

    private func listedKinds() throws -> [String] {
        let documents = try XCTUnwrap(try summary(tool: "list_pending", arguments: [:])["documents"] as? [[String: Any]])
        return documents.compactMap { $0["kind"] as? String }.sorted()
    }

    private func objectDirectoryNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(
            at: vaultDir.appendingPathComponent(DocumentVault.objectsDirectoryName, isDirectory: true),
            includingPropertiesForKeys: nil
        ).map(\.lastPathComponent).sorted()
    }

    private func assertOutboxIsEmpty(file: StaticString = #filePath, line: UInt = #line) {
        let outbox = vaultDir.appendingPathComponent(DocumentVault.outboxDirectoryName, isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: outbox.path)) ?? []
        XCTAssertTrue(names.isEmpty, "the outbox must stay empty: \(names)", file: file, line: line)
    }

    // MARK: - Originals must prove their lineage

    func testAnOriginalWithNoPlaceholderOfTheMappingIsRefusedAndNothingIsWritten() throws {
        let matter = try stageText("Mail \(Self.email) now.", named: "matter.txt")
        let redactedHandle = try anonymize(matter)
        let unrelated = try stageText(
            "Reference (Phone 13987654321) for the other matter.",
            named: "other.txt"
        )
        let objectsBefore = try objectDirectoryNames()

        let refused = try restore(redactedHandle, editedHandle: unrelated)

        XCTAssertTrue(refused.isError, "an unrelated original is not an edit surface: \(refused.text)")
        XCTAssertTrue(refused.text.hasPrefix("no_placeholders_found"), refused.text)
        XCTAssertTrue(refused.text.contains(unrelated) && refused.text.contains(redactedHandle), refused.text)
        XCTAssertFalse(refused.text.contains("13987654321"), "the unrelated text must not ride out: \(refused.text)")
        XCTAssertFalse(refused.text.contains("Phone"), refused.text)
        XCTAssertEqual(try listedKinds(), ["original", "original", "redacted"], "no restored artifact was registered")
        XCTAssertEqual(try objectDirectoryNames(), objectsBefore, "no artifact directory was left behind")
        assertOutboxIsEmpty()
    }

    func testAnOriginalWhoseEveryPlaceholderWasMangledIsRefusedWithACountOnly() throws {
        let matter = try stageText("Mail \(Self.email) now.", named: "matter.txt")
        let redactedHandle = try anonymize(matter)
        // The human exported the redacted text and broke its only placeholder.
        let mangled = try readRedacted(redactedHandle).replacingOccurrences(of: "{EMAIL_1}", with: "[EMAIL_1]")
        XCTAssertTrue(mangled.contains("[EMAIL_1]"), "fixture: the placeholder must be present to mangle")
        let edited = try stageText(mangled, named: "matter-edited.txt")
        let objectsBefore = try objectDirectoryNames()

        let refused = try restore(redactedHandle, editedHandle: edited)

        XCTAssertTrue(refused.isError, "nothing could be restored, so nothing may be written: \(refused.text)")
        XCTAssertTrue(refused.text.hasPrefix("no_placeholders_found"), refused.text)
        XCTAssertTrue(refused.text.contains("suspectPlaceholderCount=1"), "the count helps the human fix the file: \(refused.text)")
        XCTAssertFalse(refused.text.contains("[EMAIL_1]"), "suspect strings never cross for an original: \(refused.text)")
        XCTAssertEqual(try objectDirectoryNames(), objectsBefore)
        assertOutboxIsEmpty()
    }

    func testAHumanEditedOriginalReportsSuspectPlaceholdersAsACountOnly() throws {
        let matter = try stageText("Mail \(Self.email) or call \(Self.phone).", named: "matter.txt")
        let redactedHandle = try anonymize(matter)
        // One placeholder intact, one mangled by the human's editor.
        let edited = try readRedacted(redactedHandle).replacingOccurrences(of: "{PHONE_1}", with: "[PHONE_1]")
        XCTAssertTrue(edited.contains("{EMAIL_1}") && edited.contains("[PHONE_1]"), "fixture: \(edited)")
        let editedHandle = try stageText(edited, named: "matter-edited.txt")

        let response = try restore(redactedHandle, editedHandle: editedHandle)
        XCTAssertFalse(response.isError, response.text)
        let restored = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.text.utf8)) as? [String: Any])

        XCTAssertEqual(restored["format"] as? String, "txt")
        XCTAssertEqual(restored["restoredCount"] as? Int, 1, "\(restored)")
        XCTAssertEqual(restored["suspectPlaceholderCount"] as? Int, 1, "\(restored)")
        XCTAssertNil(restored["suspectPlaceholders"], "a human-staged original reports suspects as a count only: \(restored)")
        XCTAssertFalse(response.text.contains("[PHONE_1]"), "the mangled text itself never crosses: \(response.text)")
        XCTAssertEqual((restored["orphanTokens"] as? [String])?.isEmpty, true)
    }

    // MARK: - Redacted artifacts must carry this mapping

    func testARedactedArtifactOfAnotherMatterIsRefusedAsAnEditSurface() throws {
        let redactedA = try anonymize(try stageText("Mail \(Self.email) now.", named: "a.txt"))
        let redactedB = try anonymize(try stageText("Call \(Self.phone) now.", named: "b.txt"))
        let objectsBefore = try objectDirectoryNames()

        let refused = try restore(redactedA, editedHandle: redactedB)

        XCTAssertTrue(refused.isError, "another matter's artifact carries another mapping: \(refused.text)")
        XCTAssertTrue(refused.text.hasPrefix("mapping_mismatch"), refused.text)
        XCTAssertTrue(refused.text.contains(redactedB), "the message names the handle")
        XCTAssertTrue(refused.text.contains("redactedHandle"), "the fix is named: \(refused.text)")
        XCTAssertEqual(try objectDirectoryNames(), objectsBefore)
        assertOutboxIsEmpty()
    }

    func testRedactedArtifactsThatCarryTheMappingAreAcceptedAsEditSurfaces() throws {
        // (a) The artifact restore wrote for edited text carries the parent's sidecar.
        let redacted = try anonymize(try stageText("Mail \(Self.email) now.", named: "a.txt"))
        let viaText = try summary(tool: "restore", arguments: [
            "redactedHandle": redacted, "editedText": "Mail {EMAIL_1} today.", "passphrase": passphrase
        ])
        let editedRedacted = try XCTUnwrap(viaText["editedRedactedHandle"] as? String)
        let viaHandle = try summary(tool: "restore", arguments: [
            "redactedHandle": redacted, "editedHandle": editedRedacted, "passphrase": passphrase
        ])
        XCTAssertEqual(viaHandle["format"] as? String, "txt")
        XCTAssertEqual(viaHandle["restoredCount"] as? Int, 1)
        XCTAssertEqual(viaHandle["suspectPlaceholderCount"] as? Int, 0)
        XCTAssertNotNil(
            viaHandle["suspectPlaceholders"] as? [String],
            "a redacted artifact's text is already known to the caller, so the strings may be disclosed"
        )

        // (b) Session members share one sidecar and restore through each other.
        let one = try stageText("Filed by \(Self.email).", named: "one.txt")
        let two = try stageText("Reply to \(Self.email).", named: "two.txt")
        let session = try summary(tool: "anonymize_session", arguments: ["handles": [one, two], "passphrase": passphrase])
        let documents = try XCTUnwrap(session["documents"] as? [[String: Any]])
        let first = try XCTUnwrap(documents[0]["redactedHandle"] as? String)
        let second = try XCTUnwrap(documents[1]["redactedHandle"] as? String)
        let member = try summary(tool: "restore", arguments: [
            "redactedHandle": first, "editedHandle": second, "passphrase": passphrase
        ])
        XCTAssertEqual(member["format"] as? String, "md")
        XCTAssertEqual(member["restoredCount"] as? Int, 1)
    }
}
