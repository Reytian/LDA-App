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
        server = MCPServer(environment: VaultTestSupport.serverEnvironment(vaultDir: vaultDir))
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
        let entry = try VaultTestSupport.vault(root: vaultDir)
            .stage(fileURL: url, stagedAtISO8601: "2026-08-30T00:00:00Z")
        return (entry.handle, url)
    }

    /// Every regular file currently under the vault root, as (relative path,
    /// raw bytes) pairs. This is the attacker's view of the store.
    private func rawVaultFiles() throws -> [(relativePath: String, bytes: Data)] {
        guard let subpaths = try? FileManager.default.subpathsOfDirectory(atPath: vaultDir.path) else {
            return []
        }
        return subpaths.compactMap { relativePath in
            let url = vaultDir.appendingPathComponent(relativePath)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  let bytes = FileManager.default.contents(atPath: url.path) else {
                return nil
            }
            return (relativePath, bytes)
        }
    }

    /// Assert that no decrypted scratch file is left under the vault root.
    /// Called after tool calls: the scratch lifetime is exactly one call.
    private func assertNoScratchPlaintextRemains(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let scratch = vaultDir.appendingPathComponent(DocumentVault.scratchDirectoryName)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: scratch.path)) ?? []
        XCTAssertTrue(
            leftovers.isEmpty,
            "decrypted scratch files survived a tool call: \(leftovers)",
            file: file,
            line: line
        )
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
            decoding: try VaultTestSupport.vault(root: vaultDir)
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

        // Fresh server: everything zero. The fresh vault encrypts everything
        // it will ever store, so the phase 5 claim is true from the start,
        // and the key protection names the injected passphrase mode honestly.
        var attest = try summary(of: try call(tool: "attest", arguments: [:]))
        XCTAssertEqual(attest["vaultEncryptionAtRest"] as? Bool, true, "phase 5 shipped; attest must say so")
        XCTAssertEqual(attest["vaultKeyProtection"] as? String, "passphrase")
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

    /// attest must be honest, not hopeful: over a vault still carrying the
    /// pre-encryption plaintext registry (unmigrated because no tool has
    /// opened the registry yet), it must report vaultEncryptionAtRest false.
    func testAttestReportsFalseOverAnUnmigratedPlaintextVault() throws {
        try FileManager.default.createDirectory(at: vaultDir, withIntermediateDirectories: true)
        try Data("{\"entries\":[],\"version\":1}".utf8).write(
            to: vaultDir.appendingPathComponent(DocumentVault.registryFileName)
        )

        var attest = try summary(of: try call(tool: "attest", arguments: [:]))
        XCTAssertEqual(
            attest["vaultEncryptionAtRest"] as? Bool,
            false,
            "an unmigrated plaintext registry means the guarantee does not hold yet"
        )

        // Any registry-opening tool migrates the store; attest then flips.
        try call(tool: "list_pending", arguments: [:])
        attest = try summary(of: try call(tool: "attest", arguments: [:]))
        XCTAssertEqual(attest["vaultEncryptionAtRest"] as? Bool, true)
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
            decoding: try VaultTestSupport.vault(root: vaultDir)
                .readDocumentBytes(handle: restoredHandle),
            as: UTF8.self
        )
        XCTAssertTrue(restoredText.contains(email))

        // And the wire never carried the shared value or any path.
        assertWireNeverContained([email, vaultDir.path, "/Users/"])
    }

    // MARK: - Encryption at rest, proven on the file system

    /// The "cat returns ciphertext" proof: after a full
    /// stage-anonymize-read-restore-export round trip, no file under the
    /// vault root except the outbox contains the planted PII or the original
    /// filename as raw bytes. This is the structural guarantee the deny-list
    /// hook only approximates.
    func testAfterAFullRoundTripNoVaultFileOutsideTheOutboxCarriesPlaintext() throws {
        let email = "li.si.8842@example.com"
        let phone = "(212) 555-0177"
        let fileBase = "LiSi-v-WangWu-settlement-draft"
        let contents = "Contact \(email) or call \(phone) about the settlement."
        let staged = try stage(named: "\(fileBase).txt", contents: contents)

        let anonymized = try summary(of: try call(tool: "anonymize", arguments: [
            "handle": staged.handle, "passphrase": passphrase
        ]))
        let redactedHandle = try XCTUnwrap(anonymized["redactedHandle"] as? String)
        let read = try summary(of: try call(tool: "read_redacted", arguments: [
            "handle": redactedHandle
        ]))
        let redactedText = try XCTUnwrap(read["text"] as? String)
        let restored = try summary(of: try call(tool: "restore", arguments: [
            "redactedHandle": redactedHandle,
            "editedText": redactedText,
            "passphrase": passphrase
        ]))
        let restoredHandle = try XCTUnwrap(restored["restoredHandle"] as? String)
        try call(tool: "export", arguments: ["handle": restoredHandle])

        let outboxPrefix = DocumentVault.outboxDirectoryName + "/"
        var scannedOutsideOutbox = 0
        var outboxCarriesTheRestoredValue = false
        for (relativePath, bytes) in try rawVaultFiles() {
            let text = String(decoding: bytes, as: UTF8.self)
            if relativePath.hasPrefix(outboxPrefix) {
                // The outbox is the deliberate human-facing exit; the export
                // must be usable plaintext there.
                outboxCarriesTheRestoredValue = outboxCarriesTheRestoredValue
                    || text.contains(email)
                continue
            }
            scannedOutsideOutbox += 1
            for planted in [email, phone, fileBase] {
                XCTAssertFalse(
                    text.contains(planted),
                    "\(relativePath) holds plaintext: \(planted)"
                )
            }
        }
        // Registry, staged original, redacted artifact, edited redacted
        // artifact, restored artifact, and the mapping sidecar were all on
        // disk; a scan that saw fewer files than that proved nothing.
        XCTAssertGreaterThanOrEqual(scannedOutsideOutbox, 5, "the scan must cover the store")
        XCTAssertTrue(
            outboxCarriesTheRestoredValue,
            "the exported outbox copy must be decrypted, restored plaintext"
        )
    }

    /// The scratch lifetime rule: decrypted working copies live inside the
    /// vault for exactly one tool call and are gone when the call returns,
    /// on the plural (session) path too.
    func testDecryptedScratchFilesAreGoneAfterEveryToolCall() throws {
        let first = try stage(named: "matter.txt", contents: "Mail jane@example.com now.")
        let second = try stage(named: "annex.txt", contents: "Reply to jane@example.com.")

        try call(tool: "detect_entities", arguments: ["handle": first.handle])
        assertNoScratchPlaintextRemains()

        let anonymized = try summary(of: try call(tool: "anonymize", arguments: [
            "handle": first.handle, "passphrase": passphrase
        ]))
        assertNoScratchPlaintextRemains()
        let redactedHandle = try XCTUnwrap(anonymized["redactedHandle"] as? String)

        try call(tool: "anonymize_session", arguments: [
            "handles": [first.handle, second.handle], "passphrase": passphrase
        ])
        assertNoScratchPlaintextRemains()

        try call(tool: "read_redacted", arguments: ["handle": redactedHandle])
        assertNoScratchPlaintextRemains()

        try call(tool: "restore", arguments: [
            "redactedHandle": redactedHandle, "passphrase": passphrase
        ])
        assertNoScratchPlaintextRemains()

        // A FAILING call must clean up too: restore with the wrong protection
        // mode decrypts the redacted artifact to scratch and then fails at
        // the sidecar.
        let failing = try call(tool: "restore", arguments: [
            "redactedHandle": redactedHandle
        ])
        XCTAssertTrue(failing.isError)
        assertNoScratchPlaintextRemains()
    }

    // MARK: - The review step and the docx round trip

    /// The review fields (ids, detectionId, excludedCount, detectionChanged),
    /// the restore format field, and the editedHandle path ride the same wire
    /// as everything else, so the same scan covers them: a party-shaped docx
    /// filename, planted values in the body and the header, exclusions by id
    /// and by type, an edited .docx staged back by the human under another
    /// party-shaped name, an export, and every new refusal.
    ///
    /// Excluded values are visible in the redacted text BY THE CALLER'S CHOICE
    /// and read_redacted returns that text, so the fixture excludes an amount
    /// and the URL type, neither of which is on the forbidden list, while the
    /// email, phone, dates, and filenames must never cross.
    func testReviewStepAndDocxRoundTripNeverLeakNamesPathsOrPlantedValues() throws {
        let email = "wang.wu.3319@example.com"
        let phone = "13987654321"
        let date = "2024-05-20"
        let headerDate = "2023-11-30"
        let fileBase = "WangWu-v-ZhaoLiu-share-transfer"
        let original = workDir.appendingPathComponent("\(fileBase).docx")
        try DocxFixtureSupport.write(
            paragraphs: [[
                .plain("Contact "), .bold(email), .plain(" or "), .plain(phone),
                .italic(" before \(date) for USD 1,250,000; see https://example.com/deal-room.")
            ]],
            header: [[.plain("Dated \(headerDate)")]],
            to: original
        )
        let vault = VaultTestSupport.vault(root: vaultDir)
        let handle = try vault.stage(fileURL: original, stagedAtISO8601: "2026-09-02T00:00:00Z").handle

        // Review: ids and a detectionId come back; the amount is left visible.
        let detected = try summary(of: try call(tool: "detect_entities", arguments: ["handle": handle]))
        let detectionId = try XCTUnwrap(detected["detectionId"] as? String)
        let entities = try XCTUnwrap(detected["entities"] as? [[String: Any]])
        let amountId = try XCTUnwrap(
            entities.first { ($0["type"] as? String) == "AMOUNT" }?["id"] as? String,
            "fixture: the amount must be detected: \(entities)"
        )

        let anonymized = try summary(of: try call(tool: "anonymize", arguments: [
            "handle": handle,
            "passphrase": passphrase,
            "excludeEntityIds": [amountId],
            "detectionId": detectionId,
            "excludeTypes": ["URL"]
        ]))
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(anonymized["excludedCount"] as? Int), 1)
        XCTAssertEqual(anonymized["detectionChanged"] as? Bool, false)
        let redactedHandle = try XCTUnwrap(anonymized["redactedHandle"] as? String)
        try call(tool: "read_redacted", arguments: ["handle": redactedHandle])

        // Restore the stored .docx, then an edited copy the human staged back.
        let stored = try summary(of: try call(tool: "restore", arguments: [
            "redactedHandle": redactedHandle, "passphrase": passphrase
        ]))
        XCTAssertEqual(stored["format"] as? String, "docx")
        let storedRestoredHandle = try XCTUnwrap(stored["restoredHandle"] as? String)

        let redactedCopy = workDir.appendingPathComponent("\(fileBase)-redacted.docx")
        try vault.readDocumentBytes(handle: redactedHandle).write(to: redactedCopy)
        let edited = workDir.appendingPathComponent("\(fileBase)-edited.docx")
        try DocxFixtureSupport.editingBody(
            of: redactedCopy, replacing: " before ", with: " no later than ", to: edited
        )
        let editedHandle = try vault.stage(fileURL: edited, stagedAtISO8601: "2026-09-02T00:00:00Z").handle
        let viaHandle = try summary(of: try call(tool: "restore", arguments: [
            "redactedHandle": redactedHandle, "editedHandle": editedHandle, "passphrase": passphrase
        ]))
        XCTAssertEqual(viaHandle["format"] as? String, "docx")
        let editedRestoredHandle = try XCTUnwrap(viaHandle["restoredHandle"] as? String)
        try call(tool: "export", arguments: ["handle": editedRestoredHandle])
        try call(tool: "list_pending", arguments: [:])

        // The new refusals are part of the wire too.
        XCTAssertTrue(try call(tool: "anonymize", arguments: [
            "handle": handle, "passphrase": passphrase,
            "excludeEntityIds": ["ffffffffffff"], "detectionId": detectionId
        ]).isError)
        XCTAssertTrue(try call(tool: "anonymize", arguments: [
            "handle": handle, "passphrase": passphrase, "excludeEntityIds": [amountId]
        ]).isError)
        XCTAssertTrue(try call(tool: "anonymize", arguments: [
            "handle": handle, "passphrase": passphrase, "excludeTypes": ["SOCIAL"]
        ]).isError)
        XCTAssertTrue(try call(tool: "restore", arguments: [
            "redactedHandle": redactedHandle, "editedHandle": storedRestoredHandle, "passphrase": passphrase
        ]).isError)
        XCTAssertTrue(try call(tool: "restore", arguments: [
            "redactedHandle": redactedHandle, "editedText": "x", "editedHandle": editedHandle, "passphrase": passphrase
        ]).isError)

        assertWireNeverContained([
            fileBase,
            original.path,
            original.lastPathComponent,
            edited.lastPathComponent,
            vaultDir.path,
            workDir.path,
            "/Users/",
            email,
            phone,
            date,
            headerDate,
            // Vault scratch plaintext names carry the host PID; none may ride out.
            "pt_"
        ])
        assertNoScratchPlaintextRemains()

        // The scan covered the new fields: they were on the wire. A tool
        // summary rides inside a JSON text block, so its keys appear with
        // escaped quotes.
        let wire = wireText()
        for field in ["\\\"detectionId\\\"", "\\\"id\\\"", "\\\"excludedCount\\\"", "\\\"detectionChanged\\\"", "\\\"format\\\""] {
            XCTAssertTrue(wire.contains(field), "the boundary scan must cover \(field)")
        }

        // And the round trip worked: the restored bytes carry the values back.
        let restoredCopy = workDir.appendingPathComponent("restored-check.docx")
        try vault.readDocumentBytes(handle: editedRestoredHandle).write(to: restoredCopy)
        let restoredText = try DocxFixtureSupport.bodyText(of: restoredCopy)
        XCTAssertTrue(restoredText.contains(email))
        XCTAssertTrue(restoredText.contains(phone))
        XCTAssertTrue(restoredText.contains("no later than"))
        XCTAssertFalse(restoredText.contains("{"))
    }

    /// Security audit F-001: an unrelated staged original passed as
    /// editedHandle must be refused, and its text must never ride out as a
    /// "suspect placeholder" (the forensics return verbatim substrings of the
    /// scanned text, and "(Phone 13987654321)" is exactly the shape they
    /// flag). Nothing may be written: no restored artifact, nothing in the
    /// outbox, so export can never launder the original.
    func testAnUnrelatedOriginalPassedAsEditedHandleLeaksNothingAndWritesNothing() throws {
        let matter = try stage(named: "matter.txt", contents: "Mail jane@example.com now.")
        let anonymized = try summary(of: try call(tool: "anonymize", arguments: [
            "handle": matter.handle, "passphrase": passphrase
        ]))
        let redactedHandle = try XCTUnwrap(anonymized["redactedHandle"] as? String)

        let plantedPhone = "13987654321"
        let fileBase = "OtherParty-loan-agreement"
        let unrelated = try stage(
            named: "\(fileBase).txt",
            contents: "Reference (Phone \(plantedPhone)) for the other matter."
        )

        let refused = try call(tool: "restore", arguments: [
            "redactedHandle": redactedHandle,
            "editedHandle": unrelated.handle,
            "passphrase": passphrase
        ])
        XCTAssertTrue(refused.isError, refused.text)
        XCTAssertTrue(refused.text.hasPrefix("no_placeholders_found"), refused.text)

        let listed = try summary(of: try call(tool: "list_pending", arguments: [:]))
        let kinds = try XCTUnwrap(listed["documents"] as? [[String: Any]]).compactMap { $0["kind"] as? String }
        XCTAssertFalse(kinds.contains("restored"), "no restored artifact may exist: \(kinds)")
        let outbox = vaultDir.appendingPathComponent(DocumentVault.outboxDirectoryName, isDirectory: true)
        XCTAssertTrue(
            ((try? FileManager.default.contentsOfDirectory(atPath: outbox.path)) ?? []).isEmpty,
            "nothing may reach the outbox"
        )

        assertWireNeverContained([
            plantedPhone,
            "Phone",
            fileBase,
            unrelated.sourceURL.path,
            vaultDir.path,
            "/Users/",
            "pt_"
        ])
        assertNoScratchPlaintextRemains()
    }
}
